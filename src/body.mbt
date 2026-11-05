// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A request body that is not known when the request is made: the steps are called as the
/// connection has room for more.
pub struct Source {
  length : Int64?
  step : async () -> Bytes?
}

///|
/// A body whose length is not known in advance; HTTP/1.1 sends it chunked, HTTP/2 as data
/// frames.
pub fn Source::new(step : async () -> Bytes?) -> Source {
  { length: None, step, }
}

///|
/// A body of exactly `length` octets: HTTP/1.1 and HTTP/2 both declare the length, so no
/// chunking and no close-delimited body. A source that ends early or runs long fails the
/// request.
pub fn Source::sized(length : Int64, step : async () -> Bytes?) -> Source {
  { length: Some(length), step, }
}

///|
/// The length the source promises, when it promises one.
pub fn Source::length(self : Source) -> Int64? {
  self.length
}

///|
/// The next piece, or `None` at the end.
pub async fn Source::next(self : Source) -> Bytes? {
  (self.step)()
}

///|
/// One part of a `multipart/form-data` body (RFC 7578): a form field when `filename` is `None`,
/// a file otherwise.
#derive(Eq)
pub struct Part {
  name : String
  content : Bytes
  filename : String?
  content_type : String?
}

///|
pub extend Part with Eq::{equal, not_equal}

///|
/// A form field.
pub fn Part::field(name : StringView, text : StringView) -> Part {
  {
    name: name.to_owned(),
    content: @utf8.encode(text),
    filename: None,
    content_type: None,
  }
}

///|
/// A file part. `content_type` defaults to `application/octet-stream`, as browsers do.
pub fn Part::file(
  name : StringView,
  filename : StringView,
  content : Bytes,
  content_type? : StringView,
) -> Part {
  {
    name: name.to_owned(),
    content,
    filename: Some(filename.to_owned()),
    content_type: Some(
      content_type.unwrap_or("application/octet-stream").to_owned(),
    ),
  }
}

///|
pub fn Part::name(self : Part) -> String {
  self.name
}

///|
pub fn Part::content(self : Part) -> Bytes {
  self.content
}

///|
pub fn Part::filename(self : Part) -> String? {
  self.filename
}

///|
pub fn Part::content_type(self : Part) -> String? {
  self.content_type
}

///|
/// A request body. One value, so a request cannot carry two bodies for the library to choose
/// between.
#derive(Eq)
pub(all) enum Body {
  Empty
  Text(String)
  Bytes(Bytes)
  Json(Json)
  /// `application/x-www-form-urlencoded`, in the order given.
  Form(Array[(String, String)])
  /// `multipart/form-data`, RFC 7578, in the order given.
  Multipart(Array[Part])
  /// Pieces produced while the request is sent.
  Stream(Source)
}

///|
pub extend Body with Eq::{equal, not_equal}

///|
pub impl Debug for Source with fn to_repr(_self) {
  Repr("streamed body")
}

///|
pub extend Source with Debug::{to_repr}

///|
pub impl Eq for Source with fn equal(self, other) {
  physical_equal(self, other)
}

///|
pub impl Eq for Source with fn not_equal(self, other) {
  !physical_equal(self, other)
}

///|
pub extend Source with Eq::{equal, not_equal}

///|
pub impl Debug for Body with fn to_repr(self) {
  match self {
    Empty => Repr("Empty")
    Text(text) => Repr(text)
    Bytes(bytes) => Repr(bytes)
    Json(value) => Repr(value)
    Form(pairs) => Repr(pairs)
    Multipart(parts) => Repr(parts.map(p => p.name))
    Stream(source) => source.to_repr()
  }
}

///|
pub extend Body with Debug::{to_repr}
