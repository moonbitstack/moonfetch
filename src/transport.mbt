// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The shapes a connection hands back: a whole answer, and a stream's pieces. They are read by the
// transports, which exist on the backends that have sockets.

///|
/// A response as it comes off the wire, and whether its connection may carry another.
priv struct Reply {
  status : Int32
  reason : String
  version : String
  headers : Array[(String, String)]
  body : Bytes
  reusable : Bool
}

///|
/// What one stream has to hand its reader.
priv enum Piece {
  Head(Int32, Array[(String, String)])
  Body(Bytes)
  End(Array[(String, String)])
  /// The stream was reset, or the connection went away under it; `None` means nothing was said.
  Fail(Int32?)
}

///|
/// Header fields as the reader sees them: names lower case, as HTTP/2 writes them.
fn ascii(fields : Array[@header.Header]) -> Array[(String, String)] {
  fields.map(f => {
    let (name, value) = f.ascii()
    (name.to_lower(), value)
  })
}
