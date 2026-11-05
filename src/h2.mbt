// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// REFUSED_STREAM (RFC 9113 §7): the stream was not processed, so it may be sent again.
let refused_stream : Int32 = 7

///|
/// CANCEL (RFC 9113 §7): the sender is no longer interested in the stream.
let cancel : Int32 = 8

///|
/// The largest frame this side sends, which every peer must accept (RFC 9113 §4.2).
let frame_size : Int32 = 16384

///|
/// The receive window of each stream: Go's HTTP/2 transport opens 4 MiB. The protocol's 64 KiB
/// lets a server send one window per round trip, which over a long path is a slow download.
let stream_window : Int32 = 4 << 20

///|
/// The receive window of the whole connection: Go's 1 GiB.
let connection_window : Int32 = 1 << 30

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
/// One request in flight on an HTTP/2 connection.
priv struct H2Stream {
  queue : @aqueue.Queue[Piece]
  mut ready : Bool
  mut closed : Bool
  mut status : Int32
  headers : Array[(String, String)]
  mut trailers : Array[(String, String)]
  /// This side has sent END_STREAM, so nothing more may go on the stream.
  mut sent : Bool
}

///|
/// An HTTP/2 connection carrying many exchanges at once.
///
/// There is one socket read at a time — two tasks reading one connection would lose octets —
/// and whoever holds `reading` hands what it read to every stream, then wakes the rest. Only a
/// short synchronous section touches the state machine, so no lock is held across a read or a
/// write.
priv struct H2 {
  conn : @tcp.Conn
  wire : @http2.Conn
  write : @async.Mutex
  wake : @cond_var.Cond
  streams : Map[Int32, H2Stream]
  mut reading : Bool
  mut dead : Bool
  /// A GOAWAY has arrived: no new stream may start, the ones already open may finish.
  mut going : Bool
  mut why : String
}

///|
fn H2::new(conn : @tcp.Conn) -> H2 raise {
  let wire = @http2.Conn::new(
    Client,
    settings=@http2.Settings::new(initial_window_size=stream_window),
  )
  wire.widen(0, connection_window - @http2.initial.initial_window_size)
  {
    conn,
    wire,
    write: @async.Mutex(),
    wake: @cond_var.Cond(),
    streams: Map([]),
    reading: false,
    dead: false,
    going: false,
    why: "",
  }
}

///|
/// Queue what the state machine has produced and write it, one writer at a time so frames of
/// different exchanges never interleave inside one `write`.
async fn H2::flush(self : H2) -> Unit {
  self.write.acquire()
  defer self.write.release()
  let out = self.wire.take()
  if out.length() > 0 {
    errdefer {
      self.dead = true
    }
    self.conn.write(out)
  }
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
/// Hand an event to the stream it belongs to. Synchronous: the queues never block, so a slow
/// reader holds its own window shut instead of the whole connection.
fn H2::give(self : H2, id : Int32, piece : Piece) -> Unit {
  match self.streams.get(id + 2) {
    Some(stream) => {
      ignore(stream.queue.try_put(piece) catch { _ => false })
      stream.ready = true
    }
    None => ()
  }
}

///|
/// Every stream that has not finished takes what arrived for it.
fn H2::dispatch(self : H2, event : @http2.Event) -> Unit {
  match event {
    Response(stream~, fields~) =>
      if self.streams.get(stream) is Some(s) {
        for pair in ascii(fields) {
          if pair.0 == ":status" {
            s.status = @string.parse_int(pair.1) catch { _ => 0 }
          } else {
            s.headers.push(pair)
          }
        }
        self.give(stream, Head(s.status, s.headers))
      }
    Data(stream~, data~) => self.give(stream, Body(data))
    // A window that opened is what a sender is waiting for; it is not a piece of the body.
    WindowUpdated(stream~, ..) =>
      if self.streams.get(stream) is Some(s) {
        s.ready = true
      }
    Trailers(stream~, fields~) =>
      if self.streams.get(stream) is Some(s) {
        s.trailers = ascii(fields)
      }
    End(stream~) =>
      match self.streams.get(stream) {
        Some(s) => {
          s.closed = true
          self.give(stream, End(s.trailers))
        }
        None => ()
      }
    Reset(stream~, code~, ..) =>
      match self.streams.get(stream) {
        Some(s) => {
          s.closed = true
          self.give(stream, Fail(Some(code)))
        }
        None => ()
      }
    GoAway(last~, ..) => {
      self.going = true
      // A stream past the last one the server names was never processed (§6.8).
      for id, s in self.streams {
        if id > last && !s.closed {
          s.closed = true
          self.give(id, Fail(Some(refused_stream)))
        }
      }
    }
    Closed => {
      self.dead = true
      if self.why == "" {
        self.why = "the connection closed"
      }
      for id, s in self.streams {
        if !s.closed {
          s.closed = true
          self.give(id, Fail(None))
        }
      }
    }
    _ => ()
  }
}

///|
/// Read once and hand everything that came to its stream. Failures are recorded rather than
/// raised: the task that happens to be reading is rarely the one the failure belongs to.
async fn H2::read_round(self : H2) -> Unit {
  self.reading = true
  defer {
    self.reading = false
    self.wake.broadcast()
  }
  errdefer self.dispatch(Closed)
  match self.conn.read_some(max_len=chunk) {
    None => self.dispatch(Closed)
    Some(data) => self.wire.receive(data[:])
  }
  for ;; {
    let event = self.wire.next()
    if event is NeedData {
      break
    }
    self.dispatch(event)
  }
}

///|
/// Wait until `id` has something, reading the connection while nobody else is.
async fn H2::wait(self : H2, id : Int32) -> Piece {
  let stream = match self.streams.get(id) {
    Some(stream) => stream
    None => raise Reset(code=refused_stream)
  }
  for ;; {
    let taken = stream.queue.try_get() catch { _ => None }
    match taken {
      Some(piece) => {
        stream.ready = false
        return piece
      }
      None => ()
    }
    if self.reading {
      self.wake.wait()
    } else {
      self.read_round()
    }
  }
}

///|
/// One shift of reading: returns when `id` has something or the connection has gone.
async fn H2::pump(self : H2, id : Int32) -> Unit {
  let stream = match self.streams.get(id) {
    Some(stream) => stream
    None => return
  }
  for ;; {
    if self.dead || (self.going && stream.closed) {
      return
    }
    if stream.ready {
      stream.ready = false
      return
    }
    if self.reading {
      self.wake.wait()
    } else {
      self.read_round()
    }
  }
}

///|
/// Start a stream. `Err` when the connection can take no more work.
fn H2::open(self : H2, out : Outgoing) -> Int32 raise {
  guard !self.dead && !self.going else { raise Reset(code=refused_stream) }
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
  let empty = out.payload.length() is Some(0)
  self.streams[id] = {
    queue: @aqueue.Queue::Queue(kind=@aqueue.Kind::Unbounded),
    ready: false,
    closed: false,
    status: 0,
    headers: [],
    trailers: [],
    sent: empty,
  }
  self.wire.headers(id, fields, end=empty)
  id
}

///|
/// Send the body as the windows allow, reading the connection while they are shut.
async fn H2::send_body(self : H2, id : Int32, payload : Payload) -> Unit {
  match payload {
    Whole(bytes) => self.send_whole(id, bytes)
    Pieces(source) =>
      while source.next() is Some(piece) {
        self.send_whole(id, piece)
        if self.streams.get(id) is Some(s) && s.closed {
          raise @http2.Incomplete
        }
      }
  }
}

///|
async fn H2::send_whole(self : H2, id : Int32, bytes : Bytes) -> Unit {
  let mut at = 0
  for ;; {
    if at >= bytes.length() {
      return
    }
    let room = self.wire.window(id)
    if room > 0 {
      let n = @cmp.minimum(@cmp.minimum(room, bytes.length() - at), frame_size)
      self.wire.data(id, bytes[at:at + n])
      at += n
      self.flush()
    } else {
      self.pump(id)
      guard !self.dead else { raise Reset(code=refused_stream) }
    }
  }
}

///|
/// End the stream now that the body is sent.
async fn H2::finish(self : H2, id : Int32) -> Unit {
  match self.streams.get(id) {
    Some(s) if !s.sent && !s.closed => {
      s.sent = true
      self.wire.end(id)
    }
    _ => ()
  }
  self.flush()
}

///|
/// One exchange, buffered: the response body is held to `limit` as it arrives.
async fn H2::exchange(self : H2, out : Outgoing, limit : Int32) -> Reply {
  let id = self.open(out)
  self.send_body(id, out.payload)
  self.finish(id)
  let body = Buffer()
  let mut got = 0
  let mut status = 0
  let mut headers = []
  for ;; {
    match self.wait(id) {
      Head(code, fields) => {
        status = code
        headers = fields
      }
      Body(piece) => {
        got += piece.length()
        if got > limit {
          self.abandon(id)
          raise Exceeded(limit~, got~)
        }
        body.write_bytes(piece)
        self.acknowledge(id, piece.length())
      }
      End(_) => break
      Fail(code) => failed(code)
    }
  }
  {
    status,
    reason: "",
    version: "HTTP/2",
    headers,
    body: body.to_bytes(),
    reusable: !self.dead && !self.going,
  }
}

///|
/// Tell the peer the octets of `id` have been taken, so its window opens again.
fn H2::acknowledge(self : H2, id : Int32, n : Int32) -> Unit raise {
  if n > 0 && !self.dead {
    self.wire.acknowledge(id, n)
  }
}

///|
/// Give up on a stream: reset it so the server stops sending, and open the connection window
/// again for whatever was already in flight.
fn H2::abandon(self : H2, id : Int32) -> Unit {
  match self.streams.get(id) {
    Some(s) if !s.closed => {
      s.closed = true
      if !self.dead {
        ignore(self.wire.reset(id, code=cancel) catch { _ => () })
      }
    }
    _ => ()
  }
}

///|
/// Turn a stream failure into the error the caller sees.
fn failed(code : Int32?) -> Unit raise {
  match code {
    Some(c) => raise Reset(code=c)
    None => raise @http2.Incomplete
  }
}
