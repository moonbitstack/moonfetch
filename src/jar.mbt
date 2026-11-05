// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A cookie as it is kept: the RFC 6265bis state, not the wire form.
priv struct Stored {
  name : String
  value : String
  domain : String
  host_only : Bool
  path : String
  /// When it dies, in milliseconds since the epoch; `None` is a session cookie.
  expires : Int64?
  created : Int64
  secure : Bool
}

///|
/// How many cookies one domain may hold, and how many one jar keeps: the RFC's own advice
/// (§6.1), which is also what browsers settled on.
let per_domain : Int32 = 50

///|
let per_jar : Int32 = 3000

///|
/// A cookie store for a `Client` (RFC 6265bis).
///
/// One jar may be shared by several clients and by tasks: every change goes through a lock.
/// Persistence is not part of it — a jar lives as long as the process does.
pub struct Jar {
  priv lock : @async.Mutex
  priv store : Ref[Array[Stored]]
}

///|
/// An empty jar.
pub fn Jar::new() -> Jar {
  { lock: @async.Mutex(), store: Ref([]), }
}

///|
pub fn Jar::clear(self : Jar) -> Unit {
  self.store.val = []
}

///|
/// How many cookies the jar holds.
pub fn Jar::size(self : Jar) -> Int32 {
  self.store.val.length()
}

///|
fn ip_literal(host : String) -> Bool {
  if host.contains(":") {
    return true
  }
  let parts = host.split(".").to_array()
  if parts.length() != 4 {
    return false
  }
  for part in parts {
    guard part.length() > 0 && part.length() <= 3 else { return false }
    for c in part {
      guard c is ('0'..<='9') else { return false }
    }
  }
  true
}

///|
/// Whether a cookie set for `domain` may be sent to `host` (RFC 6265bis §5.1.3).
fn domain_match(host : String, domain : String) -> Bool {
  if host == domain {
    return true
  }
  guard !ip_literal(host) else { return false }
  host.has_suffix(".\{domain}")
}

///|
fn last_slash(path : StringView) -> Int32 {
  let mut at = -1
  for i in 0..<path.length() {
    if path[i] == '/' {
      at = i
    }
  }
  at
}

///|
/// The directory a request's path is in, which a cookie without `Path` covers (§5.1.4).
fn default_path(path : StringView) -> String {
  guard path.has_prefix("/") else { return "/" }
  let at = last_slash(path)
  if at <= 0 {
    return "/"
  }
  path[0:at].to_owned()
}

///|
/// Whether a cookie with `path` is sent on a request for `request` (§5.1.4).
fn path_match(request : StringView, path : StringView) -> Bool {
  if request == path {
    return true
  }
  guard request.has_prefix(path) else { return false }
  guard path.has_suffix("/") else {
    return request.length() > path.length() && request[path.length()] == '/'
  }
  true
}

///|
/// The domain a `Set-Cookie` names, lower-cased and without the leading dot, when it is one
/// the request may set.
fn cookie_domain(url : @moonurl.Url, named : String?) -> (String, Bool)? {
  let host = url.host.unwrap_or("").to_lower()
  guard host != "" else { return None }
  match named {
    None => Some((host, true))
    Some(text) => {
      let lower = text.to_lower()
      let domain = lower.strip_prefix(".").unwrap_or(lower).to_owned()
      guard domain != "" && !ip_literal(host) else { return None }
      guard domain_match(host, domain) else { return None }
      guard !is_public_suffix(domain) else { return None }
      Some((domain, false))
    }
  }
}

///|
/// Where the cookie sits in the jar, or `None`.
fn entry_at(
  kept : Array[Stored],
  name : String,
  domain : String,
  path : String,
) -> Int32? {
  for i, cookie in kept {
    if cookie.name == name && cookie.domain == domain && cookie.path == path {
      return Some(i)
    }
  }
  None
}

///|
/// Take the cookies out of a response (RFC 6265bis §5.3).
pub async fn Jar::store(
  self : Jar,
  url : @moonurl.Url,
  values : Array[String],
) -> Unit {
  guard values.length() > 0 else { return }
  let now = @async.now()
  let request_path = match url.path {
    "" => "/"
    path => path
  }
  self.lock.acquire()
  defer self.lock.release()
  let kept = self.store.val.copy()
  for value in values {
    let parsed = match @cookie.Cookie::decode(value) {
      Some(cookie) => cookie
      None => continue
    }
    guard parsed.name != "" else { continue }
    let (domain, host_only) = match cookie_domain(url, parsed.domain) {
      Some(pair) => pair
      None => continue
    }
    // A `__Host-` cookie is host-only, secure and rooted at `/`; `__Secure-` must be secure.
    guard !parsed.name.has_prefix("__Host-") ||
      (parsed.secure && host_only && parsed.path == Some("/")) else {
      continue
    }
    guard !parsed.name.has_prefix("__Secure-") || parsed.secure else {
      continue
    }
    let path = parsed.path.unwrap_or(default_path(request_path))
    let at = entry_at(kept, parsed.name, domain, path)
    let dead = match parsed.max_age {
      Some(age) =>
        if age <= 0 {
          Some(None)
        } else {
          Some(Some(now + age.to_int64() * 1000))
        }
      None =>
        match parsed.expires {
          Some(moment) =>
            match moment.epoch() {
              Some(epoch) => Some(Some(epoch * 1000))
              None => None
            }
          None => None
        }
    }
    // A `Max-Age` of zero or less deletes; an `Expires` already past deletes on the next sweep.
    match dead {
      Some(None) => {
        match at {
          Some(i) => ignore(kept.remove(i))
          None => ()
        }
        continue
      }
      _ => ()
    }
    let expires = match dead {
      Some(Some(at)) => Some(at)
      _ => None
    }
    let fresh = {
      name: parsed.name,
      value: parsed.value,
      domain,
      host_only,
      path,
      expires,
      created: match at {
        Some(i) => kept[i].created
        None => now
      },
      secure: parsed.secure,
    }
    match at {
      Some(i) => kept[i] = fresh
      None => kept.push(fresh)
    }
  }
  // Drop what has died, then the newest of a domain that is over its share.
  let live = kept.filter(c => {
    match c.expires {
      Some(at) => at > now
      None => true
    }
  })
  let trimmed : Array[Stored] = []
  for cookie in live {
    let mut same = 0
    for other in trimmed {
      if other.domain == cookie.domain {
        same += 1
      }
    }
    if same >= per_domain {
      continue
    }
    trimmed.push(cookie)
  }
  while trimmed.length() > per_jar {
    let mut oldest = 0
    for i in 1..<trimmed.length() {
      if trimmed[i].created < trimmed[oldest].created {
        oldest = i
      }
    }
    ignore(trimmed.remove(oldest))
  }
  self.store.val = trimmed
}

///|
/// The `Cookie` header for a request to `url`: the cookies that match, longest path first and
/// oldest first within a path (RFC 6265bis §5.4).
pub async fn Jar::cookies(self : Jar, url : @moonurl.Url) -> String {
  let host = url.host.unwrap_or("").to_lower()
  let path = match url.path {
    "" => "/"
    path => path
  }
  let secure = url.scheme is Some("https")
  let now = @async.now()
  self.lock.acquire()
  let held = self.store.val
  self.lock.release()
  let out = []
  for cookie in held {
    guard cookie.expires is None || cookie.expires.unwrap() > now else {
      continue
    }
    let fits = if cookie.host_only {
      host == cookie.domain
    } else {
      domain_match(host, cookie.domain)
    }
    if fits && path_match(path, cookie.path) && (!cookie.secure || secure) {
      out.push(cookie)
    }
  }
  out.sort_by((a, b) => {
    if a.path.length() != b.path.length() {
      b.path.length() - a.path.length()
    } else if a.created < b.created {
      -1
    } else if a.created > b.created {
      1
    } else {
      0
    }
  })
  let header = StringBuilder()
  let mut first = true
  for cookie in out {
    if !first {
      header.write_string("; ")
    }
    first = false
    header.write_string("\{cookie.name}=\{cookie.value}")
  }
  header.to_string()
}
