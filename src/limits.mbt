// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// What a client reads of a response before it refuses it.
///
/// `head` bounds the status line and header block, `fields` the number of header fields, and
/// `body` the body as it arrives, before any content coding is undone. The body bound is
/// checked as the octets come in, so a server that would send more is stopped early rather
/// than after the allocation.
pub(all) struct Limits {
  head : Int32
  fields : Int32
  body : Int32
}

///|
/// The bounds a client uses when none are given: a 64 KiB head, 256 fields, and a 32 MiB body.
///
/// No client of the common ones bounds a body by default; a library that returns a `Response`
/// with the whole body in memory has to, or one answer can exhaust the process. 32 MiB covers
/// the API payloads a buffered call is for; anything larger is read as a `Stream`, which is not
/// bounded.
pub let limits : Limits = { head: 65536, fields: 256, body: 33554432, }

///|
/// The same bounds with some replaced.
pub fn Limits::new(head? : Int32, fields? : Int32, body? : Int32) -> Limits {
  {
    head: head.unwrap_or(limits.head),
    fields: fields.unwrap_or(limits.fields),
    body: body.unwrap_or(limits.body),
  }
}
