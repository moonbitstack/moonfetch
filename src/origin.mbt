// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Where a request goes: scheme, host and port, the unit connections are kept by (RFC 6454).
///
/// An origin is a fact about the URL, not about the connection, so it is settled before either
/// host is asked for one: the browser host has no connection of its own to keep.
priv struct Origin {
  scheme : String
  host : String
  port : Int32
}

///|
fn Origin::of(url : @moonurl.Url) -> Origin {
  let scheme = url.scheme.unwrap_or("http")
  let port = match url.port {
    Some(p) => p
    None => if scheme == "https" { 443 } else { 80 }
  }
  { scheme, host: url.host.unwrap_or(""), port, }
}

///|
fn Origin::key(self : Origin) -> String {
  "\{self.scheme}://\{self.host}:\{self.port}"
}

///|
/// The host and port as a request names them: the port left out when it is the scheme's own.
fn Origin::authority(self : Origin) -> String {
  let host = if self.host.contains(":") { "[\{self.host}]" } else { self.host }
  match (self.scheme, self.port) {
    ("http", 80) | ("https", 443) => host
    _ => "\{host}:\{self.port}"
  }
}

///|
/// The absolute URL a request goes to: joined to `base`, with `query` added to any query the
/// URL already has.
fn located(
  base : @moonurl.Url?,
  text : StringView,
  query : Array[(String, String)]?,
) -> @moonurl.Url raise Refused {
  let given = parse(text)
  let url = match base {
    Some(base) if !given.is_absolute() => {
      let prefix = if base.path.has_suffix("/") {
        base.path
      } else {
        base.path + "/"
      }
      let rest = match given.path.strip_prefix("/") {
        Some(rest) => rest.to_owned()
        None => given.path
      }
      { ..base, path: prefix + rest, query: given.query, fragment: None, }
    }
    _ => given
  }
  check(url, text)
  guard query is Some(pairs) && pairs.length() > 0 else { return url }
  let extra = @moonurl.Query::new(pairs~).encode()
  let joined = match url.query {
    Some(q) if q != "" => q + "&" + extra
    _ => extra
  }
  { ..url, query: Some(joined), }
}

///|
fn parse(text : StringView) -> @moonurl.Url raise Refused {
  @moonurl.Url::decode(text) catch {
    _ => raise Url(text.to_owned())
  }
}

///|
fn check(url : @moonurl.Url, text : StringView) -> Unit raise Refused {
  guard url.scheme is Some("http" | "https") else {
    raise Url("\{text}: not http or https")
  }
  guard url.host is Some(host) && host != "" else {
    raise Url("\{text}: no host")
  }
}

///|
fn has(fields : Array[(String, String)], name : String) -> Bool {
  fields.iter().any(f => f.0.to_lower() == name)
}

///|
fn without(
  fields : Array[(String, String)],
  names : Array[String],
) -> Array[(String, String)] {
  fields.filter(f => !names.contains(f.0.to_lower()))
}

///|
/// The client's headers with the request's laid over them: a name given for the request
/// replaces the client's value for that name.
fn merge(
  base : Array[(String, String)],
  extra : Array[(String, String)],
) -> Array[(String, String)] {
  without(base, extra.map(f => f.0.to_lower())) + extra
}
