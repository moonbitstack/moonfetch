// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A piece of a response body as it arrives.
pub(all) enum Chunk {
  Data(Bytes)
  /// The body is over; the trailers are those the server sent, empty when it sent none.
  End(Array[(String, String)])
}

///|
/// How much is read from a connection at once: a TLS record's worth. The async default is a
/// kibibyte.
let chunk : Int32 = 16384
