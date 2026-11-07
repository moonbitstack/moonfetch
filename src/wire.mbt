// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A request as it goes on the wire, whichever version carries it.
priv struct Outgoing {
  verb : @method.Method
  scheme : String
  authority : String
  target : String
  fields : Array[@header.Header]
  payload : Payload
}

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
fn ascii(fields : Array[@header.Header]) -> Array[(String, String)] {
  fields.map(f => {
    let (name, value) = f.ascii()
    (name.to_lower(), value)
  })
}

///|
/// The host and port as a request names them: the port left out when it is the scheme's own.
fn Origin::authority(self : Origin) -> String {
  let host = if self.host.contains(":") { "[\{self.host}]" } else { self.host }
  match (self.scheme, self.port) {
    ("http", 80) | ("https", 443) => host
    _ => "\{host}:\{self.port}"
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
