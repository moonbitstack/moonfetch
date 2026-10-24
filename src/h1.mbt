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
  payload : Bytes
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
fn ascii(fields : Array[@header.Header]) -> Array[(String, String)] {
  fields.map(f => {
    let (name, value) = f.ascii()
    (name.to_lower(), value)
  })
}

///|
/// One exchange over HTTP/1.1, framed and checked by moonhttp's state machine.
async fn h1(conn : @tcp.Conn, out : Outgoing) -> Reply {
  let wire = @http1.Conn::new(Client)
  // RFC 9110 §8.6: a method that defines a body says how long it is, even when empty.
  let framing : @http1.Body = if out.payload.length() > 0 ||
    out.verb is (Post | Put | Patch) {
    Sized(out.payload.length())
  } else {
    Empty
  }
  let head = @http1.Request::of(
    out.verb.name(),
    out.target,
    fields=out.fields,
    host=out.authority,
    body=framing,
  )
  let sent = Buffer()
  sent.write_bytes(wire.send(Request(head)))
  if out.payload.length() > 0 {
    sent.write_bytes(wire.send(Data(out.payload)))
  }
  sent.write_bytes(wire.send(End([])))
  conn.write(sent.to_bytes())
  let body = Buffer()
  let mut answer = None
  for ;; {
    match wire.next() {
      NeedData => wire.receive(conn.read_some(max_len=chunk).unwrap_or(b"")[:])
      Response(r) => answer = Some(r)
      Data(piece) => body.write_bytes(piece)
      End(_) | Closed => break
      Informational(_) | Paused | Request(_) => ()
    }
  }
  guard answer is Some(r) else { raise @http1.Partial }
  {
    status: r.status,
    reason: r.reason,
    version: r.version,
    headers: ascii(r.fields),
    body: body.to_bytes(),
    reusable: wire.ours() is Done &&
    wire.theirs() is Done &&
    wire.trailing().length() == 0,
  }
}
