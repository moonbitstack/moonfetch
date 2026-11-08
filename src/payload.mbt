// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A request body in the form the transport sends it.
priv enum Payload {
  Whole(Bytes)
  Pieces(Source)
}

///|
/// How many boundaries have been made in this process: with the clock, enough to keep two
/// bodies made at the same time apart.
let boundaries : Ref[Int64] = Ref(0)

///|
/// A boundary no part contains. The first choice is random enough not to be in anything; the
/// loop makes it certain rather than likely.
fn boundary(parts : Array[Part]) -> String {
  boundaries.val += 1
  let mut text = "moonfetch-\{boundaries.val}-\{@async.now()}"
  for ;; {
    guard parts.iter().any(p => contains(p.content, text)) else { break }
    text = text + "x"
  }
  text
}

///|
fn contains(content : Bytes, text : String) -> Bool {
  let needle = @utf8.encode(text)
  if needle.length() > content.length() {
    return false
  }
  let last = content.length() - needle.length()
  let mut start = 0
  while start <= last {
    let mut same = true
    for i in 0..<needle.length() {
      if content[start + i] != needle[i] {
        same = false
        break
      }
    }
    if same {
      return true
    }
    start += 1
  }
  false
}

///|
/// A name or filename as a `Content-Disposition` parameter spells it: a quote, a line break and
/// a percent sign cannot appear raw.
fn parameter(text : String) -> String {
  let out = StringBuilder()
  for c in text {
    match c {
      '"' => out.write_string("%22")
      '\r' => out.write_string("%0D")
      '\n' => out.write_string("%0A")
      '%' => out.write_string("%25")
      _ => out.write_char(c)
    }
  }
  out.to_string()
}

///|
/// A `multipart/form-data` body (RFC 7578) and the content type that names its boundary.
fn multipart(parts : Array[Part]) -> (Bytes, String) {
  let mark = boundary(parts)
  let out = Buffer()
  for part in parts {
    out.write_bytes(@utf8.encode("--\{mark}\r\n"))
    out.write_bytes(
      @utf8.encode(
        "Content-Disposition: form-data; name=\"\{parameter(part.name)}\"",
      ),
    )
    if part.filename is Some(name) {
      out.write_bytes(@utf8.encode("; filename=\"\{parameter(name)}\""))
    }
    out.write_bytes(@utf8.encode("\r\n"))
    if part.content_type is Some(kind) {
      out.write_bytes(@utf8.encode("Content-Type: \{kind}\r\n"))
    }
    out.write_bytes(@utf8.encode("\r\n"))
    out.write_bytes(part.content)
    out.write_bytes(@utf8.encode("\r\n"))
  }
  out.write_bytes(@utf8.encode("--\{mark}--\r\n"))
  (out.to_bytes(), "multipart/form-data; boundary=\{mark}")
}

///|
/// The octets, and the content type they go out under unless the caller names one.
fn Body::payload(self : Body) -> (Payload, String?) {
  match self {
    Empty => (Whole(b""), None)
    Text(text) => (Whole(@utf8.encode(text)), Some("text/plain; charset=utf-8"))
    Bytes(bytes) => (Whole(bytes), Some("application/octet-stream"))
    Json(value) =>
      (Whole(@utf8.encode(value.stringify())), Some("application/json"))
    Form(pairs) =>
      (
        Whole(@utf8.encode(@moonurl.Query::new(pairs~).encode())),
        Some("application/x-www-form-urlencoded"),
      )
    Multipart(parts) => {
      let (bytes, kind) = multipart(parts)
      (Whole(bytes), Some(kind))
    }
    Stream(source) => (Pieces(source), None)
  }
}

///|
/// How many octets a whole payload holds.
fn Payload::length(self : Payload) -> Int64? {
  match self {
    Whole(bytes) => Some(bytes.length().to_int64())
    Pieces(source) => source.length
  }
}
