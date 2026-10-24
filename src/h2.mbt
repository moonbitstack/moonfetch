// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// An HTTP/2 connection carrying one exchange at a time: whoever holds the lock reads the
/// connection, so no reader task outlives a request.
priv struct H2 {
  conn : @tcp.Conn
  wire : @http2.Conn
  lock : @async.Mutex
  mut dead : Bool
}

///|
/// REFUSED_STREAM (RFC 9113 §7): the stream was not processed, so it may be sent again.
let refused_stream : Int32 = 7

///|
/// The receive window of each stream: Go's HTTP/2 transport opens 4 MiB. The protocol's 64 KiB
/// lets a server send one window per round trip, which over a long path is a slow download.
let stream_window : Int32 = 4 << 20

///|
/// The receive window of the whole connection: Go's 1 GiB.
let connection_window : Int32 = 1 << 30

///|
fn H2::new(conn : @tcp.Conn) -> H2 raise {
  let wire = @http2.Conn::new(
    Client,
    settings=@http2.Settings::new(initial_window_size=stream_window),
  )
  wire.widen(0, connection_window - @http2.initial.initial_window_size)
  { conn, wire, lock: @async.Mutex(), dead: false, }
}

///|
async fn H2::flush(self : H2) -> Unit {
  let out = self.wire.take()
  if out.length() > 0 {
    self.conn.write(out)
  }
}

///|
/// The next event, reading the connection as often as it takes.
async fn H2::event(self : H2) -> @http2.Event {
  let mut event = self.wire.next()
  while event is NeedData {
    self.flush()
    self.wire.receive(self.conn.read_some(max_len=chunk).unwrap_or(b"")[:])
    event = self.wire.next()
  }
  event
}

///|
/// Connection-specific fields, which HTTP/2 forbids (RFC 9113 §8.2.2); the authority goes in
/// `:authority` instead of `host`.
fn h2_allowed(name : String) -> Bool {
  !(name
  is ("connection"
  | "keep-alive"
  | "proxy-connection"
  | "transfer-encoding"
  | "upgrade"
  | "host"))
}

///|
priv struct Incoming {
  mut status : Int32
  headers : Array[(String, String)]
  body : Buffer
  mut done : Bool
}

///|
fn H2::take(
  self : H2,
  id : Int32,
  into : Incoming,
  event : @http2.Event,
) -> Unit raise {
  match event {
    Response(stream~, fields~) if stream == id =>
      for pair in ascii(fields) {
        if pair.0 == ":status" {
          into.status = @string.parse_int(pair.1)
        } else {
          into.headers.push(pair)
        }
      }
    Data(stream~, data~) if stream == id => {
      into.body.write_bytes(data)
      self.wire.acknowledge(id, data.length())
    }
    End(stream~) if stream == id => into.done = true
    Reset(stream~, code~, ..) if stream == id => raise Reset(code~)
    GoAway(last~, ..) => {
      self.dead = true
      // A stream past the last one the server names was never processed (§6.8).
      if id > last {
        raise Reset(code=refused_stream)
      }
    }
    Closed => {
      self.dead = true
      if !into.done {
        raise @http2.Incomplete
      }
    }
    _ => ()
  }
}

///|
/// One exchange: the request on a new stream, the body as the windows allow, then events until
/// the response ends.
async fn H2::exchange(self : H2, out : Outgoing) -> Reply {
  self.lock.acquire()
  defer self.lock.release()
  let id = self.wire.next_stream()
  let fields = [
    @header.Header::of(":method", out.verb.name()),
    @header.Header::of(":scheme", out.scheme),
    @header.Header::of(":authority", out.authority),
    @header.Header::of(":path", out.target),
  ]
  for f in out.fields {
    let (name, value) = f.ascii()
    let lower = name.to_lower()
    if h2_allowed(lower) {
      fields.push(@header.Header::of(lower, value))
    }
  }
  let payload = out.payload
  self.wire.headers(id, fields, end=payload.length() == 0)
  let into = { status: 0, headers: [], body: Buffer(), done: false, }
  let mut at = 0
  while at < payload.length() {
    let room = self.wire.window(id)
    if room > 0 {
      let n = @cmp.minimum(room, payload.length() - at)
      self.wire.data(id, payload[at:at + n], end=at + n == payload.length())
      at += n
    } else {
      self.take(id, into, self.event())
    }
  }
  self.flush()
  while !into.done {
    self.take(id, into, self.event())
  }
  self.flush()
  {
    status: into.status,
    reason: "",
    version: "HTTP/2",
    headers: into.headers,
    body: into.body.to_bytes(),
    reusable: !self.dead,
  }
}
