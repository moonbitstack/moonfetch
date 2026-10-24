// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// What moonfetch itself refuses. Errors from below pass through as they are: a socket that
/// will not connect, a TLS alert, a response that does not parse.
pub(all) suberror Refused {
  /// `checked` on a 4xx or 5xx response.
  Status(status~ : Int32, url~ : String)
  /// More redirects than allowed.
  Redirects(limit~ : Int32)
  /// The server reset the stream, or went away before answering it, with an HTTP/2 error code
  /// (RFC 9113 §7).
  Reset(code~ : Int32)
  /// The exchange, redirects included, took longer than `limit` milliseconds.
  Timeout(limit~ : Int32)
  /// A URL that does not parse, or names a scheme other than http and https.
  Url(String)
} derive(Eq, Debug)

///|
pub extend Refused with Eq::{equal, not_equal}

///|
pub extend Refused with Debug::{to_repr}

///|
pub impl Show for Refused with fn output(self, logger) {
  match self {
    Status(status~, url~) => logger.write_string("\{url} answered \{status}")
    Redirects(limit~) => logger.write_string("more than \{limit} redirects")
    Reset(code~) =>
      logger.write_string("stream reset with HTTP/2 error \{code}")
    Timeout(limit~) => logger.write_string("no answer within \{limit} ms")
    Url(why) => logger.write_string("bad URL: \{why}")
  }
}

///|
pub extend Refused with Show::{output, to_string}

///|
/// A response, read whole. Header names are lower case, as HTTP/2 writes them, and keep the
/// order they arrived in.
pub(all) struct Response {
  status : Int32
  reason : String
  version : String
  headers : Array[(String, String)]
  /// The URL that answered, after any redirects.
  url : String
  body : Bytes
} derive(Eq, Debug)

///|
pub extend Response with Eq::{equal, not_equal}

///|
pub extend Response with Debug::{to_repr}

///|
/// The first value of the header `name`, matched without regard to case.
pub fn Response::header(self : Response, name : StringView) -> String? {
  let want = name.to_owned().to_lower()
  for pair in self.headers {
    if pair.0 == want {
      return Some(pair.1)
    }
  }
  None
}

///|
/// Every value of the header `name`, in order: what `set-cookie` needs.
pub fn Response::values(self : Response, name : StringView) -> Array[String] {
  let want = name.to_owned().to_lower()
  self.headers.filter(pair => pair.0 == want).map(pair => pair.1)
}

///|
/// The body as UTF-8 text; a malformed sequence reads as U+FFFD.
pub fn Response::text(self : Response) -> String {
  @utf8.decode_lossy(self.body[:])
}

///|
/// The body parsed as JSON.
pub fn Response::json(self : Response) -> Json raise @json.ParseError {
  @json.parse(self.text())
}

///|
/// Whether the status is 2xx.
pub fn Response::is_success(self : Response) -> Bool {
  self.status is (200..<300)
}

///|
/// The response itself, or `Status` for a 4xx or 5xx, as reqwest's `error_for_status` does.
pub fn Response::checked(self : Response) -> Response raise Refused {
  if self.status is (400..<600) {
    raise Status(status=self.status, url=self.url)
  }
  self
}
