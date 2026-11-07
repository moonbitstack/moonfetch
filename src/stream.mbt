// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Where the body of a `Stream` comes from.
priv enum StreamBody {
  Hay1(@tcp.Conn, H1, String, Pool)
  Hay2(H2, Int32)
  Finished
}

///|
/// A response whose body is read a piece at a time, for a body too large to hold or one that
/// never ends: a server-sent event feed, a download that is written as it comes.
///
/// One task reads one stream. `close` gives up the rest; a program that just drops it leaves
/// the exchange unfinished until the client is closed.
pub struct Stream {
  priv status_ : Int32
  priv reason_ : String
  priv version_ : String
  priv headers_ : Array[(String, String)]
  priv url_ : String
  priv timeout_ : Int32?
  priv limit_ : Int32
  priv mut body_ : StreamBody
}

///|
pub fn Stream::status(self : Stream) -> Int32 {
  self.status_
}

///|
pub fn Stream::reason(self : Stream) -> String {
  self.reason_
}

///|
pub fn Stream::version(self : Stream) -> String {
  self.version_
}

///|
pub fn Stream::headers(self : Stream) -> Array[(String, String)] {
  self.headers_
}

///|
/// The first value of the header `name`, matched without regard to case.
pub fn Stream::header(self : Stream, name : StringView) -> String? {
  let want = name.to_owned().to_lower()
  for pair in self.headers_ {
    if pair.0 == want {
      return Some(pair.1)
    }
  }
  None
}

///|
pub fn Stream::url(self : Stream) -> String {
  self.url_
}

///|
/// Read the next piece, `None` once the body has been read to its end.
pub async fn Stream::next(self : Stream) -> Chunk? {
  match self.timeout_ {
    None => self.advance()
    Some(ms) =>
      match @async.with_timeout_opt(ms, () => self.advance()) {
        Some(chunk) => chunk
        None => {
          self.close()
          raise Timeout(limit=ms)
        }
      }
  }
}

///|
async fn Stream::advance(self : Stream) -> Chunk? {
  match self.body_ {
    Finished => None
    Hay1(conn, reader, key, pool) => {
      if reader.done {
        if reader.reusable {
          pool.checkin(key, conn)
        } else {
          conn.close()
        }
        self.body_ = Finished
        return None
      }
      match reader.next() {
        Some(piece) =>
          match piece {
            Data(bytes) => Some(Data(bytes))
            End(trailers) => {
              if reader.reusable {
                pool.checkin(key, conn)
              } else {
                conn.close()
              }
              self.body_ = Finished
              Some(End(trailers))
            }
          }
        None => {
          conn.close()
          self.body_ = Finished
          None
        }
      }
    }
    Hay2(h2, id) =>
      for ;; {
        match h2.wait(id) {
          Body(piece) => {
            h2.acknowledge(id, piece.length())
            h2.flush()
            return Some(Data(piece))
          }
          End(trailers) => {
            self.body_ = Finished
            return Some(End(trailers))
          }
          Head(_, _) => ()
          Fail(code) => {
            self.body_ = Finished
            failed(code)
          }
        }
      }
  }
}

///|
/// Read the rest of the body, refusing to hold more than `limit` octets. The stream is over
/// afterwards.
pub async fn Stream::bytes(self : Stream, limit? : Int32) -> Bytes {
  let cap = limit.unwrap_or(self.limit_)
  let out = Buffer()
  let mut got = 0
  for ;; {
    match self.next() {
      Some(Data(piece)) => {
        got += piece.length()
        if got > cap {
          self.close()
          raise Exceeded(limit=cap, got~)
        }
        out.write_bytes(piece)
      }
      Some(End(_)) | None => break
    }
  }
  out.to_bytes()
}

///|
/// The rest of the body as UTF-8 text; a malformed sequence reads as U+FFFD.
pub async fn Stream::text(self : Stream, limit? : Int32) -> String {
  @utf8.decode_lossy(self.bytes(limit?)[:])
}

///|
/// Give up the rest of the body: an HTTP/2 stream is reset, an HTTP/1.1 connection is closed.
pub fn Stream::close(self : Stream) -> Unit {
  match self.body_ {
    Finished => ()
    Hay1(conn, _, _, _) => conn.close()
    Hay2(h2, id) => h2.abandon(id)
  }
  self.body_ = Finished
}

///|
/// Send a request and return once its head is in; the body is read with `Stream::next`.
///
/// Redirects are followed as `request` follows them, the body of each hop read and dropped
/// first. `timeout` bounds reading the head and each later `Stream::next`, not the whole
/// exchange, which is the point of streaming.
pub async fn Client::stream(
  self : Client,
  verb : @method.Method,
  url : StringView,
  query? : Array[(String, String)],
  headers? : Array[(String, String)],
  body? : Body,
  timeout? : Int32,
  redirects? : Int32,
) -> Stream {
  let mut target = located(self.base, url, query)
  let mut fields = merge(self.headers, headers.unwrap_or([]))
  let mut payload = body.unwrap_or(Empty)
  let mut verb = verb
  let limit = redirects.unwrap_or(self.redirects)
  let mut hop = 0
  for ;; {
    let stream = self.open_stream(verb, target, fields, payload, timeout)
    guard limit > 0 &&
      stream.status() is (301 | 302 | 303 | 307 | 308) &&
      stream.header("location") is Some(location) else {
      return stream
    }
    if hop == limit {
      stream.close()
      raise Redirects(limit~)
    }
    ignore(stream.bytes(limit=self.limits.body))
    let next = target.resolve(parse(location))
    check(next, location)
    let to_get = (stream.status() == 303 && !(verb is Head)) ||
      (stream.status() is (301 | 302) && verb is Post)
    if to_get {
      verb = Get
      payload = Empty
      fields = without(fields, ["content-type", "content-length"])
    }
    if Origin::of(next).key() != Origin::of(target).key() {
      fields = without(fields, ["authorization", "cookie"])
    }
    target = next
    hop += 1
  }
  abort("unreachable")
}

///|
async fn Client::open_stream(
  self : Client,
  verb : @method.Method,
  url : @moonurl.Url,
  fields : Array[(String, String)],
  body : Body,
  timeout : Int32?,
) -> Stream {
  let ms = match timeout {
    Some(ms) => Some(ms)
    None => self.timeout
  }
  let run = () => self.begin(verb, url, fields, body, ms)
  match ms {
    None => run()
    Some(ms) =>
      match @async.with_timeout_opt(ms, run) {
        Some(stream) => stream
        None => raise Timeout(limit=ms)
      }
  }
}

///|
async fn Client::begin(
  self : Client,
  verb : @method.Method,
  url : @moonurl.Url,
  fields : Array[(String, String)],
  body : Body,
  timeout : Int32?,
) -> Stream {
  let (out, _) = self.pack(verb, url, fields, body, decode=false)
  let origin = Origin::of(url)
  let key = origin.key()
  let head = match self.link(origin) {
    H2(h2, reused=_) => {
      errdefer self.pool.forget(key, h2)
      let id = h2.open(out)
      h2.send_body(id, out.payload)
      h2.finish(id)
      let mut status = 0
      let mut answer = []
      for ;; {
        match h2.wait(id) {
          Head(code, headers) => {
            status = code
            answer = headers
            break
          }
          Body(_) => ()
          End(_) => raise @http2.Incomplete
          Fail(code) => failed(code)
        }
      }
      (status, "", "HTTP/2", answer, StreamBody::Hay2(h2, id))
    }
    H1(conn, reused=_) => {
      errdefer conn.close()
      let (head, reader) = h1_open(conn, out)
      (
        head.status,
        head.reason,
        head.version,
        head.headers,
        StreamBody::Hay1(conn, reader, key, self.pool),
      )
    }
  }
  let (status, reason, version, headers, source) = head
  if self.jar is Some(jar) {
    jar.store(url, headers.filter(h => h.0 == "set-cookie").map(h => h.1))
  }
  {
    status_: status,
    reason_: reason,
    version_: version,
    headers_: headers,
    url_: url.encode(),
    timeout_: timeout,
    limit_: self.limits.body,
    body_: source,
  }
}
