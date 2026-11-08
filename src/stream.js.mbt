// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A response whose body is read a piece at a time, from the host's `fetch`.
///
/// One task reads one stream. `close` gives up the rest; a program that just drops it leaves the
/// host to cancel it when the response is collected.
pub struct Stream {
  priv status_ : Int32
  priv reason_ : String
  priv headers_ : Array[(String, String)]
  priv url_ : String
  priv timeout_ : Int32?
  priv limit_ : Int32
  priv mut body_ : @js_async.ReadableStream?
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
/// Empty on this host: it does not say which version answered.
pub fn Stream::version(_self : Stream) -> String {
  ""
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
  match self.body_ {
    None => None
    Some(stream) =>
      match self.timeout_ {
        None => next_piece(self, stream)
        Some(ms) =>
          match @async.with_timeout_opt(ms, () => next_piece(self, stream)) {
            Some(chunk) => chunk
            None => {
              self.close()
              raise Timeout(limit=ms)
            }
          }
      }
  }
}

///|
async fn next_piece(
  owner : Stream,
  stream : @js_async.ReadableStream,
) -> Chunk? {
  match stream.read_some(max_len=chunk) {
    Some(bytes) => Some(Data(bytes))
    None => {
      owner.body_ = None
      // A browser does not hand the trailer fields of a response to the page.
      Some(End([]))
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
/// Give up the rest of the body: the host cancels the response.
pub fn Stream::close(self : Stream) -> Unit {
  match self.body_ {
    None => ()
    Some(stream) => stream.close()
  }
  self.body_ = None
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
    match
      next_hop(
        hop,
        limit,
        stream.status(),
        stream.header("location"),
        verb,
        target,
        fields,
        payload,
      ) {
      Stop => return stream
      Again(verb=next_verb, url=next, fields=next_fields, body=next_body) => {
        ignore(stream.bytes(limit=self.limits.body))
        verb = next_verb
        target = next
        fields = next_fields
        payload = next_body
        hop += 1
      }
    }
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
  // `fetch` writes the length itself, and a page may not set it either.
  let (all, payload) = prepared(body, fields)
  let all = without(all, ["content-length"])
  let target = url.encode()
  let credentials = self.credentials.name()
  let ms = match timeout {
    Some(ms) => Some(ms)
    None => self.timeout
  }
  let run = () => ask(target, verb, all, payload, "manual", credentials)
  let answer = match ms {
    None => run()
    Some(ms) =>
      match @async.with_timeout_opt(ms, run) {
        Some(answer) => answer
        None => raise Timeout(limit=ms)
      }
  }
  let headers = unlabelled(answered(answer.headers()))
  {
    status_: answer.status(),
    reason_: answer.status_text(),
    headers_: headers,
    url_: answer.url(),
    timeout_: ms,
    limit_: self.limits.body,
    body_: Some(@js_async.ReadableStream::from_js(answer.body())),
  }
}
