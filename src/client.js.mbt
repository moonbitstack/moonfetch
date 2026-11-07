// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The client a browser or Node has: `fetch` there, no socket of this library's own, and the
// same shapes and rules as the client the other host has.

///|
/// What the host does with the cookies it keeps for the page or the process. A browser decides
/// that itself; `fetch` is told which of the three it may use (WHATWG Fetch §3.4).
#derive(Eq, Debug)
pub(all) enum Credentials {
  /// Send none, and store none.
  Omit
  /// Send and store the ones of this origin.
  SameOrigin
  /// Send and store the ones of any origin the page may reach.
  Include
}

///|
pub extend Credentials with Eq::{equal, not_equal}

///|
pub extend Credentials with Debug::{to_repr}

///|
fn Credentials::name(self : Credentials) -> String {
  match self {
    Omit => "omit"
    SameOrigin => "same-origin"
    Include => "include"
  }
}

///|
/// An HTTP client over the host's `fetch`.
///
/// `base_url` is the prefix relative URLs are joined to, as the client the other host has joins
/// them. `headers` go on every request. `timeout` bounds each request, redirects included;
/// `None` waits for ever. `redirects` caps how many are followed; 0 follows none. `credentials`
/// is what the host may do with its cookies. `limits` bounds a buffered response.
///
/// The host owns the connections, the cookie store, the proxy settings and the content codings,
/// so there is no pool, jar or proxy here: `close` has nothing to close.
pub struct Client {
  base : @moonurl.Url?
  headers : Array[(String, String)]
  timeout : Int32?
  redirects : Int32
  credentials : Credentials
  limits : Limits
}

///|
/// A client.
pub fn Client::new(
  base_url? : String,
  headers? : Array[(String, String)],
  timeout~ : Int32? = Some(timeout),
  redirects~ : Int32 = redirects,
  credentials~ : Credentials = SameOrigin,
  limits~ : Limits = limits,
) -> Client raise Refused {
  let base = match base_url {
    Some(text) => {
      let url = parse(text)
      check(url, text)
      Some(url)
    }
    None => None
  }
  {
    base,
    headers: headers.unwrap_or([]),
    timeout,
    redirects,
    credentials,
    limits,
  }
}

///|
/// Nothing to do: the connections are the host's. Kept so that one program reads the same on
/// either host.
pub fn Client::close(_self : Client) -> Unit {
  ()
}

///|
/// The headers a request goes out with. Those the host decides — `content-length`, `host`,
/// `accept-encoding`, and the ones a page may not set — are left to it.
fn prepared(
  body : Body,
  fields : Array[(String, String)],
) -> (Array[(String, String)], Payload) {
  let (payload, kind) = body.payload()
  let all = fields.copy()
  if kind is Some(k) && !has(all, "content-type") {
    all.push(("content-type", k))
  }
  if !has(all, "accept") {
    all.push(("accept", "*/*"))
  }
  (all, payload)
}

///|
/// One exchange on the host's `fetch`, with this request's timeout around it.
async fn Client::send(
  self : Client,
  verb : @method.Method,
  url : @moonurl.Url,
  fields : Array[(String, String)],
  body : Body,
  timeout : Int32?,
) -> Response {
  let (all, payload) = prepared(body, fields)
  let target = url.encode()
  let credentials = self.credentials.name()
  let run = () => {
    let answer = ask(target, verb, all, payload, "manual", credentials)
    // A browser hides a cross-origin redirect from the page; the only way to reach what is on
    // the other side is to let the host follow it. Nothing of the chain is visible then.
    let answer = if answer.hidden() {
      ask(target, verb, all, payload, "follow", credentials)
    } else {
      answer
    }
    (answer, unlabelled(answered(answer.headers())))
  }
  let ms = match timeout {
    Some(ms) => Some(ms)
    None => self.timeout
  }
  let (answer, headers) = match ms {
    None => run()
    Some(ms) =>
      match @async.with_timeout_opt(ms, run) {
        Some(reply) => reply
        None => raise Timeout(limit=ms)
      }
  }
  let bytes = read_body(
    @js_async.ReadableStream::from_js(answer.body()),
    self.limits.body,
  )
  {
    status: answer.status(),
    reason: answer.status_text(),
    // The host does not say which version answered: a browser never does, and Node does not
    // expose it either.
    version: "",
    headers,
    url: answer.url(),
    body: bytes,
  }
}

///|
/// Read a whole body, refusing to hold more than `cap` octets.
async fn read_body(stream : @js_async.ReadableStream, cap : Int32) -> Bytes {
  let out = Buffer()
  let mut got = 0
  while stream.read_some(max_len=chunk) is Some(piece) {
    got += piece.length()
    if got > cap {
      stream.close()
      raise Exceeded(limit=cap, got~)
    }
    out.write_bytes(piece)
  }
  out.to_bytes()
}

///|
/// Send, then follow what `next_hop` makes of the answer.
async fn Client::follow(
  self : Client,
  hop : Int32,
  limit : Int32,
  verb : @method.Method,
  url : @moonurl.Url,
  fields : Array[(String, String)],
  body : Body,
  timeout : Int32?,
) -> Response {
  let response = self.send(verb, url, fields, body, timeout)
  match
    next_hop(
      hop,
      limit,
      response.status,
      response.header("location"),
      verb,
      url,
      fields,
      body,
    ) {
    Stop => response
    Again(verb~, url~, fields~, body~) =>
      self.follow(hop + 1, limit, verb, url, fields, body, timeout)
  }
}

///|
/// Send a request and read the response whole.
///
/// `query` is added to the URL's own query; `headers` replace the client's of the same name;
/// `timeout` and `redirects` replace the client's for this request.
pub async fn Client::request(
  self : Client,
  verb : @method.Method,
  url : StringView,
  query? : Array[(String, String)],
  headers? : Array[(String, String)],
  body? : Body,
  timeout? : Int32,
  redirects? : Int32,
) -> Response {
  let target = located(self.base, url, query)
  let fields = merge(self.headers, headers.unwrap_or([]))
  let limit = redirects.unwrap_or(self.redirects)
  self.follow(0, limit, verb, target, fields, body.unwrap_or(Empty), timeout)
}

///|
pub async fn Client::get(
  self : Client,
  url : StringView,
  query? : Array[(String, String)],
  headers? : Array[(String, String)],
  timeout? : Int32,
  redirects? : Int32,
) -> Response {
  self.request(Get, url, query?, headers?, timeout?, redirects?)
}

///|
pub async fn Client::head(
  self : Client,
  url : StringView,
  query? : Array[(String, String)],
  headers? : Array[(String, String)],
  timeout? : Int32,
  redirects? : Int32,
) -> Response {
  self.request(Head, url, query?, headers?, timeout?, redirects?)
}

///|
pub async fn Client::delete(
  self : Client,
  url : StringView,
  query? : Array[(String, String)],
  headers? : Array[(String, String)],
  timeout? : Int32,
  redirects? : Int32,
) -> Response {
  self.request(Delete, url, query?, headers?, timeout?, redirects?)
}

///|
pub async fn Client::options(
  self : Client,
  url : StringView,
  query? : Array[(String, String)],
  headers? : Array[(String, String)],
  timeout? : Int32,
  redirects? : Int32,
) -> Response {
  self.request(Options, url, query?, headers?, timeout?, redirects?)
}

///|
pub async fn Client::post(
  self : Client,
  url : StringView,
  body? : Body,
  query? : Array[(String, String)],
  headers? : Array[(String, String)],
  timeout? : Int32,
  redirects? : Int32,
) -> Response {
  self.request(Post, url, body?, query?, headers?, timeout?, redirects?)
}

///|
pub async fn Client::put(
  self : Client,
  url : StringView,
  body? : Body,
  query? : Array[(String, String)],
  headers? : Array[(String, String)],
  timeout? : Int32,
  redirects? : Int32,
) -> Response {
  self.request(Put, url, body?, query?, headers?, timeout?, redirects?)
}

///|
pub async fn Client::patch(
  self : Client,
  url : StringView,
  body? : Body,
  query? : Array[(String, String)],
  headers? : Array[(String, String)],
  timeout? : Int32,
  redirects? : Int32,
) -> Response {
  self.request(Patch, url, body?, query?, headers?, timeout?, redirects?)
}

///|
/// One request on a client of its own. A host that keeps connections keeps them for this one
/// request too, and decides for how long.
pub async fn request(
  verb : @method.Method,
  url : StringView,
  query? : Array[(String, String)],
  headers? : Array[(String, String)],
  body? : Body,
  timeout? : Int32,
  redirects? : Int32,
) -> Response {
  let client = Client::new()
  client.request(verb, url, query?, headers?, body?, timeout?, redirects?)
}

///|
pub async fn get(
  url : StringView,
  query? : Array[(String, String)],
  headers? : Array[(String, String)],
  timeout? : Int32,
  redirects? : Int32,
) -> Response {
  request(Get, url, query?, headers?, timeout?, redirects?)
}

///|
pub async fn head(
  url : StringView,
  query? : Array[(String, String)],
  headers? : Array[(String, String)],
  timeout? : Int32,
  redirects? : Int32,
) -> Response {
  request(Head, url, query?, headers?, timeout?, redirects?)
}

///|
pub async fn delete(
  url : StringView,
  query? : Array[(String, String)],
  headers? : Array[(String, String)],
  timeout? : Int32,
  redirects? : Int32,
) -> Response {
  request(Delete, url, query?, headers?, timeout?, redirects?)
}

///|
pub async fn options(
  url : StringView,
  query? : Array[(String, String)],
  headers? : Array[(String, String)],
  timeout? : Int32,
  redirects? : Int32,
) -> Response {
  request(Options, url, query?, headers?, timeout?, redirects?)
}

///|
pub async fn post(
  url : StringView,
  body? : Body,
  query? : Array[(String, String)],
  headers? : Array[(String, String)],
  timeout? : Int32,
  redirects? : Int32,
) -> Response {
  request(Post, url, body?, query?, headers?, timeout?, redirects?)
}

///|
pub async fn put(
  url : StringView,
  body? : Body,
  query? : Array[(String, String)],
  headers? : Array[(String, String)],
  timeout? : Int32,
  redirects? : Int32,
) -> Response {
  request(Put, url, body?, query?, headers?, timeout?, redirects?)
}

///|
pub async fn patch(
  url : StringView,
  body? : Body,
  query? : Array[(String, String)],
  headers? : Array[(String, String)],
  timeout? : Int32,
  redirects? : Int32,
) -> Response {
  request(Patch, url, body?, query?, headers?, timeout?, redirects?)
}
