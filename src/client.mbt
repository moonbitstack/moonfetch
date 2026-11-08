// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// How many idle HTTP/1.1 connections are kept per origin: urllib3's 10.
pub let idle : Int32 = 10

///|
let mozilla_roots : Ref[@x509.Roots?] = Ref(None)

///|
/// The Mozilla roots, read once and only when a client is made without its own TLS settings.
fn mozilla() -> @x509.Roots {
  match mozilla_roots.val {
    Some(roots) => roots
    None => {
      let roots = @roots.mozilla()
      mozilla_roots.val = Some(roots)
      roots
    }
  }
}

///|
/// An HTTP client that keeps its connections: idle HTTP/1.1 ones per origin, and one HTTP/2
/// connection per origin for every request to it. Close it when done with it.
struct Client {
  base : @moonurl.Url?
  headers : Array[(String, String)]
  timeout : Int32?
  redirects : Int32
  compression : Bool
  http3 : Bool
  h2c : Bool
  limits : Limits
  tls : @tls.Client
  pool : Pool
  jar : Jar?
  proxy : Proxy?
}

///|
/// A client.
///
/// `base_url` is the prefix relative URLs are joined to, as httpx joins them: its path is kept,
/// so `/users` under `https://a.example/api` is `https://a.example/api/users`. `headers` go on
/// every request. `timeout` bounds each request, redirects included; `None` waits for ever.
/// `redirects` caps how many are followed; 0 follows none. `http2` offers HTTP/2 by ALPN;
/// `h2c` speaks HTTP/2 with prior knowledge over `http`, where there is no ALPN to ask.
/// `compression` asks for gzip or deflate and decodes what comes back, as httpx and reqwest do;
/// a request that names its own `accept-encoding` gets the body as sent.
/// `http3` speaks HTTP/3 over QUIC where it can, and falls back to TCP for an origin that does
/// not answer on the datagram, as a browser's Alt-Svc does without the cache.
/// `limits` bounds what a buffered response may hold. `jar` keeps cookies across requests.
/// `proxy` sends the connection through an HTTP or SOCKS5 proxy.
/// `tls` judges servers' certificates, the Mozilla roots when not given; its ALPN list is set
/// by `http2`.
pub fn Client::new(
  base_url? : String,
  headers? : Array[(String, String)],
  timeout~ : Int32? = Some(timeout),
  redirects~ : Int32 = redirects,
  http2~ : Bool = true,
  compression~ : Bool = true,
  http3~ : Bool = false,
  idle~ : Int32 = idle,
  h2c~ : Bool = false,
  limits~ : Limits = limits,
  jar? : Jar,
  proxy? : Proxy,
  tls? : @tls.Client,
) -> Client raise Refused {
  let base = match base_url {
    Some(text) => {
      let url = parse(text)
      check(url, text)
      Some(url)
    }
    None => None
  }
  let alpn = if http2 { ["h2", "http/1.1"] } else { ["http/1.1"] }
  let tls = match tls {
    Some(config) => { ..config, alpn, }
    None => @tls.Client::new(mozilla(), alpn~)
  }
  {
    base,
    headers: headers.unwrap_or([]),
    timeout,
    redirects,
    compression,
    http3,
    h2c,
    limits,
    tls,
    pool: Pool::new(idle),
    jar,
    proxy,
  }
}

///|
/// Close every connection the client keeps.
pub fn Client::close(self : Client) -> Unit {
  self.pool.close()
}

///|
/// A fresh connection to the origin, through the proxy and over TLS as the client is set up.
async fn Client::open(self : Client, origin : Origin) -> @tcp.Conn {
  let tls = if origin.scheme == "https" { Some(self.tls) } else { None }
  match self.proxy {
    None => @tcp.dial(origin.host, port=origin.port, tls?)
    Some(proxy) =>
      match proxy.scheme {
        "http" | "https" => {
          // An `https` proxy is spoken to over TLS; the tunnel inside carries the origin's TLS.
          let outer = if proxy.scheme == "https" {
            Some({ ..self.tls, alpn: ["http/1.1"], })
          } else {
            None
          }
          let conn = @tcp.dial(proxy.host, port=proxy.port, tls?=outer)
          if origin.scheme == "https" {
            proxy.tunnel(conn, origin.host, origin.port)
            conn.upgrade(self.tls, origin.host)
          } else {
            conn
          }
        }
        _ => {
          let conn = @tcp.dial(proxy.host, port=proxy.port)
          proxy.socks5(conn, origin.host, origin.port)
          if origin.scheme == "https" {
            conn.upgrade(self.tls, origin.host)
          } else {
            conn
          }
        }
      }
  }
}

///|
/// Whether a request to this origin should try QUIC first: HTTPS only, since an HTTP/3 connection
/// is always over TLS, and only while the origin has not turned the attempt down.
fn Client::wants_h3(self : Client, origin : Origin) -> Bool {
  self.http3 && origin.scheme == "https" && !self.pool.tried_h3(origin.key())
}

///|
/// An HTTP/3 connection to the origin, or `None` when the handshake did not finish in time or
/// was refused: the caller then takes the TCP path.
async fn Client::quic(self : Client, origin : Origin) -> H3? {
  let tls : @tls.Client = { ..self.tls, alpn: ["h3"], }
  let attempt : Result[H3?, Error] = Ok(
    @async.with_timeout_opt(quic_timeout, () => {
      H3::connect(origin.host, origin.port, tls)
    }),
  ) catch {
    _ => Ok(None)
  }
  match attempt {
    Ok(Some(h3)) => Some(h3)
    _ => None
  }
}

///|
/// Whether a fresh connection to this origin should speak HTTP/2.
fn Client::wants_h2(self : Client, origin : Origin, conn : @tcp.Conn) -> Bool {
  if origin.scheme == "http" {
    self.h2c
  } else {
    conn.alpn() is Some("h2")
  }
}

///|
async fn Client::link(self : Client, origin : Origin) -> Link {
  let key = origin.key()
  if self.wants_h3(origin) {
    match self.pool.live_h3(key) {
      Some(h3) => return H3(h3, reused=true)
      None => ()
    }
  }
  match self.pool.live(key) {
    Some(h2) => return H2(h2, reused=true)
    None => ()
  }
  if self.pool.take(key) is Some(conn) {
    return H1(conn, reused=true)
  }
  // A dial is shared: whoever gets here first connects, the rest take what it opened.
  self.pool.dial.acquire()
  defer self.pool.dial.release()
  if self.wants_h3(origin) {
    match self.pool.live_h3(key) {
      Some(h3) => return H3(h3, reused=true)
      None => ()
    }
  }
  match self.pool.live(key) {
    Some(h2) => return H2(h2, reused=true)
    None => ()
  }
  if self.pool.take(key) is Some(conn) {
    return H1(conn, reused=true)
  }
  if self.wants_h3(origin) {
    match self.quic(origin) {
      Some(h3) => {
        self.pool.keep_h3(key, h3)
        return H3(h3, reused=false)
      }
      None => self.pool.refuse_h3(key)
    }
  }
  let conn = self.open(origin)
  if self.wants_h2(origin, conn) {
    let h2 = H2::new(conn)
    self.pool.keep_h2(key, h2)
    return H2(h2, reused=false)
  }
  H1(conn, reused=false)
}

///|
/// Whether a failed exchange may be sent again: only when the connection had carried a request
/// before, its body can be replayed, and the method or the server says nothing was done.
fn retryable(reused : Bool, out : Outgoing, error : Error) -> Bool {
  guard reused else { return false }
  guard out.payload is Whole(_) else { return false }
  out.verb.is_idempotent() || (error is Reset(code~) && code == refused_stream)
}

///|
/// One exchange, on a kept connection when there is one.
async fn Client::exchange(
  self : Client,
  origin : Origin,
  out : Outgoing,
) -> Reply {
  let key = origin.key()
  match self.link(origin) {
    H2(h2, reused~) =>
      h2.exchange(out, self.limits.body) catch {
        e => {
          self.pool.forget(key, h2)
          guard retryable(reused, out, e) else { raise e }
          return self.exchange(origin, out)
        }
      }
    H3(h3, reused~) =>
      h3.exchange(out, self.limits.body) catch {
        e => {
          self.pool.forget_h3(key, h3)
          guard retryable(reused, out, e) else { raise e }
          return self.exchange(origin, out)
        }
      }
    H1(conn, reused~) => {
      let reply = h1(conn, out, self.limits.body) catch {
        e => {
          conn.close()
          guard retryable(reused, out, e) else { raise e }
          return self.exchange(origin, out)
        }
      }
      if reply.reusable {
        self.pool.checkin(key, conn)
      } else {
        conn.close()
      }
      reply
    }
  }
}

///|
/// The headers a request goes out with, and the request body as the transport wants it.
async fn Client::pack(
  self : Client,
  verb : @method.Method,
  url : @moonurl.Url,
  fields : Array[(String, String)],
  body : Body,
  decode~ : Bool,
) -> (Outgoing, Bool) {
  let (all, payload) = prepared(body, fields)
  if self.jar is Some(jar) && !has(all, "cookie") {
    let kept = jar.cookies(url)
    if kept != "" {
      all.push(("cookie", kept))
    }
  }
  let decoding = decode && self.compression && !has(all, "accept-encoding")
  if decoding {
    all.push(("accept-encoding", "gzip, deflate"))
  }
  let out = going(verb, url, all, payload)
  // A cleartext request through an HTTP proxy is sent in absolute form (RFC 9112 §3.2.2).
  let out = match self.proxy {
    Some(proxy) if proxy.absolute() && out.scheme == "http" =>
      { ..out, target: url.encode(), }
    _ => out
  }
  (out, decoding)
}

///|
/// Keep what the response set, and read the body as the codings say.
async fn Client::settle(
  self : Client,
  url : @moonurl.Url,
  reply : Reply,
  decoding : Bool,
) -> Response {
  if self.jar is Some(jar) {
    jar.store(url, reply.headers.filter(h => h.0 == "set-cookie").map(h => h.1))
  }
  let (headers, body) = if decoding {
    decoded(reply.headers, reply.body)
  } else {
    (reply.headers, reply.body)
  }
  {
    status: reply.status,
    reason: reply.reason,
    version: reply.version,
    headers,
    url: url.encode(),
    body,
  }
}

///|
async fn Client::send(
  self : Client,
  verb : @method.Method,
  url : @moonurl.Url,
  fields : Array[(String, String)],
  body : Body,
) -> Response {
  let (out, decoding) = self.pack(verb, url, fields, body, decode=true)
  let reply = self.exchange(Origin::of(url), out)
  self.settle(url, reply, decoding)
}

///|
/// The body with its content codings undone, last applied first (RFC 9110 §8.4), and the
/// headers without the `content-encoding` and `content-length` that no longer describe it, as
/// reqwest leaves them. A coding not asked for is left in place. `deflate` is the zlib format
/// by the RFC, but some servers send bare DEFLATE, so both are read.
fn decoded(
  headers : Array[(String, String)],
  body : Bytes,
) -> (Array[(String, String)], Bytes) raise {
  guard headers.iter().find_first(h => h.0 == "content-encoding")
    is Some((_, value)) &&
    body.length() > 0 else {
    return (headers, body)
  }
  let codings = value
    .split(",")
    .map(c => c.trim(chars=" \t").to_owned().to_lower())
    .collect()
  let mut out = body
  for i = codings.length() - 1; i >= 0; i = i - 1 {
    out = match codings[i] {
      "gzip" | "x-gzip" => @gzip.gunzip(out[:])
      "deflate" => @zlib.unzlib(out[:]) catch { _ => @deflate.inflate(out[:]) }
      "identity" => out
      _ => return (headers, body)
    }
  }
  (without(headers, ["content-encoding", "content-length"]), out)
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
) -> Response {
  let response = self.send(verb, url, fields, body)
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
      self.follow(hop + 1, limit, verb, url, fields, body)
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
  let run = () => {
    self.follow(0, limit, verb, target, fields, body.unwrap_or(Empty))
  }
  match
    (match timeout {
      Some(ms) => Some(ms)
      None => self.timeout
    }) {
    None => run()
    Some(ms) =>
      match @async.with_timeout_opt(ms, run) {
        Some(response) => response
        None => raise Timeout(limit=ms)
      }
  }
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
/// One request on a client of its own, closed afterwards. A program that makes more than a few
/// requests keeps a `Client` instead.
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
  defer client.close()
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

///|
/// A fresh connection to the URL's origin, with the client's TLS and proxy rules applied and
/// nothing else on it. The caller owns it; it is not taken from the pool and is not kept. For
/// a protocol that starts as HTTP and then becomes something else — WebSocket, say.
pub async fn Client::connect(self : Client, url : StringView) -> @tcp.Conn {
  let target = parse(url)
  check(target, url)
  self.open(Origin::of(target))
}
