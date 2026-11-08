// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A response body being read from an HTTP/1.1 connection, a piece at a time.
priv struct H1 {
  conn : @tcp.Conn
  wire : @http1.Conn
  mut done : Bool
  mut reusable : Bool
}

///|
/// Send the request and read the response head; the body is left on `H1`.
async fn h1_open(conn : @tcp.Conn, out : Outgoing) -> (Reply, H1) {
  // The state machine that writes the request is the one that reads the answer: it is what tells
  // a connection that carried a whole exchange from one that did not.
  let wire = @http1.Conn::new(Client)
  let sent = Buffer()
  sent.write_bytes(h1_head(wire, out))
  match out.payload {
    Whole(bytes) =>
      if bytes.length() > 0 {
        sent.write_bytes(wire.send(Data(bytes)))
      }
    Pieces(source) =>
      while source.next() is Some(piece) {
        if piece.length() > 0 {
          sent.write_bytes(wire.send(Data(piece)))
        }
      }
  }
  sent.write_bytes(wire.send(End([])))
  conn.write(sent.to_bytes())
  let reader = { conn, wire, done: false, reusable: false, }
  let reply = {
    status: 0,
    reason: "",
    version: "HTTP/1.1",
    headers: [],
    body: b"",
    reusable: false,
  }
  match reader.head(reply) {
    Some(head) => (head, reader)
    None => raise @http1.Partial
  }
}

///|
/// Read up to the response head, skipping informational answers. `None` means the connection
/// closed first.
async fn H1::head(self : H1, _ : Reply) -> Reply? {
  for ;; {
    match self.wire.next() {
      NeedData =>
        match self.conn.read_some(max_len=chunk) {
          Some(data) => self.wire.receive(data[:])
          None => self.wire.receive(b"")
        }
      Response(r) => {
        // A response that ends its message in the head: the connection may carry another.
        let empty = self.wire.theirs() is Done
        self.done = empty
        self.reusable = empty && self.wire.ours() is Done
        return Some({
          status: r.status,
          reason: r.reason,
          version: r.version,
          headers: ascii(r.fields),
          body: b"",
          reusable: false,
        })
      }
      Closed => return None
      Informational(_) | Data(_) | End(_) | Paused | Request(_) => ()
    }
  }
}

///|
/// The next piece of the body, trailers at the end, `None` once it has all been read.
async fn H1::next(self : H1) -> Chunk? {
  for ;; {
    match self.wire.next() {
      Data(piece) => return Some(Data(piece))
      End(trailers) => {
        self.done = true
        self.reusable = self.wire.ours() is Done &&
          self.wire.theirs() is Done &&
          self.wire.trailing().length() == 0
        return Some(End(ascii(trailers)))
      }
      Closed => {
        self.done = true
        self.reusable = false
        // A body that ran to the close is complete when the framing said so; anything else cut
        // short is an error, and the state machine reports nothing else here.
        if self.wire.theirs() is Done {
          return Some(End([]))
        }
        raise @http1.Partial
      }
      NeedData =>
        match self.conn.read_some(max_len=chunk) {
          Some(data) => self.wire.receive(data[:])
          None => self.wire.receive(b"")
        }
      Informational(_) | Response(_) | Paused | Request(_) => ()
    }
  }
}

///|
/// Read the rest of the body, refusing to hold more than `limit` octets.
async fn H1::collect(self : H1, limit : Int32) -> Bytes {
  let out = Buffer()
  let mut got = 0
  for ;; {
    match self.next() {
      Some(Data(piece)) => {
        got += piece.length()
        if got > limit {
          raise Exceeded(limit~, got~)
        }
        out.write_bytes(piece)
      }
      Some(End(_)) | None => break
    }
  }
  out.to_bytes()
}

///|
/// One exchange over HTTP/1.1, framed and checked by moonhttp's state machine.
async fn h1(conn : @tcp.Conn, out : Outgoing, limit : Int32) -> Reply {
  let (head, reader) = h1_open(conn, out)
  let body = reader.collect(limit)
  { ..head, body, reusable: reader.reusable, }
}
