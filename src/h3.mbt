// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// HTTP/3, RFC 9114, over QUIC: the connection is moonnet's, which runs moonquic's state machine
// on a datagram socket, and the framing, the settings and QPACK are moonhttp's. What is here is
// the client: one connection per origin carrying many exchanges, one bidirectional stream each.

///|
/// How long a QUIC handshake may take before the client gives up on it and falls back to TCP:
/// the bound a browser gives one of two connections racing to the same origin.
let quic_timeout : Int32 = 3000

///|
/// The largest field section this side accepts, which is also the QPACK table it asks for: none,
/// so that a reply may only name static entries (RFC 9204 §3.2.1).
let field_section : UInt64 = 16384UL

///|
/// One request in flight on an HTTP/3 connection.
priv struct H3Stream {
  /// The QUIC stream it rides on.
  stream : UInt64
  queue : @aqueue.Queue[Piece]
  mut closed : Bool
  mut status : Int32
  headers : Array[(String, String)]
  mut trailers : Array[(String, String)]
  /// Octets that arrived on the stream and are not framed yet.
  mut held : Bytes
  /// The head has been read, so the next HEADERS frame is the trailers.
  mut head : Bool
}

///|
/// An HTTP/3 connection carrying many exchanges at once.
///
/// There is one datagram at a time — a QUIC connection sends and receives on one socket, so two
/// tasks stepping it would lose packets — and whoever holds `stepping` hands what arrived to its
/// stream, then wakes the rest. Nothing here awaits between a write and the next one, so frames
/// of different exchanges never interleave inside one stream.
priv struct H3 {
  quic : @udp.Quic
  wake : @cond_var.Cond
  streams : Map[Int32, H3Stream]
  mut next : Int32
  mut stepping : Bool
  mut dead : Bool
  /// A GOAWAY has arrived: no new exchange may start, the ones already open may finish.
  mut going : Bool
}

///|
/// Connect over QUIC, offer `h3`, and state this side's settings on the control stream.
async fn H3::connect(host : String, port : Int32, tls : @tls.Client) -> H3 {
  let quic = @udp.dial(host, port~, tls~)
  match quic.alpn() {
    Some("h3") | None => ()
    Some(name) => {
      quic.close()
      raise Proxy("the server chose \{name}, not h3")
    }
  }
  let conn : H3 = {
    quic,
    wake: @cond_var.Cond(),
    streams: Map([]),
    next: 1,
    stepping: false,
    dead: false,
    going: false,
  }
  conn.settings()
  conn
}

///|
/// The control stream of RFC 9114 §6.2.1: this side's settings, with the dynamic table shut so
/// that no reply can name an entry this side does not have.
fn H3::settings(self : H3) -> Unit {
  let settings = @http3.Settings::new(0UL, field_section, 0UL)
  let stream = self.quic.open_uni()
  self.quic.write(stream, @http3.control(settings.pairs()), fin=false)
}

///|
/// Connection-specific fields, which HTTP/3 forbids as HTTP/2 does (RFC 9114 §4.2); the
/// authority goes in `:authority` instead of `host`.
fn h3_allowed(name : String) -> Bool {
  !(name
  is ("connection"
  | "keep-alive"
  | "proxy-connection"
  | "transfer-encoding"
  | "upgrade"
  | "host"))
}

///|
/// Hand a piece to the exchange it belongs to. Synchronous: the queue never blocks, so a slow
/// reader holds its own stream shut instead of the connection.
fn H3::give(self : H3, at : Int32, piece : Piece) -> Unit {
  match self.streams.get(at) {
    Some(stream) => ignore(stream.queue.try_put(piece) catch { _ => false })
    None => ()
  }
}

///|
/// Read a field section: the first HEADERS frame of an exchange is its head, the second its
/// trailers.
fn H3::section(self : H3, at : Int32, block : Bytes) -> Unit raise {
  let fields = @qpack.decode(block) catch {
    @qpack.Refused::Malformed(why) => raise @http3.Refused::Malformed(why)
    @qpack.Refused::Index(..) =>
      raise @http3.Refused::Malformed("a QPACK index this table does not have")
    @qpack.Refused::Exceeded(..) =>
      raise @http3.Refused::Malformed(
        "a QPACK block over the table this side has",
      )
  }
  guard self.streams.get(at) is Some(stream) else { return }
  if stream.head {
    stream.trailers = ascii(fields)
  } else {
    stream.head = true
    for field in ascii(fields) {
      if field.0 == ":status" {
        stream.status = @string.parse_int(field.1) catch { _ => 0 }
      } else {
        stream.headers.push(field)
      }
    }
    self.give(at, Head(stream.status, stream.headers))
  }
}

///|
/// Take what arrived on `at` and turn it into pieces.
fn H3::absorb(self : H3, at : Int32, stream : H3Stream) -> Unit raise {
  let arrived = self.quic.take(stream.stream)
  if arrived.length() > 0 {
    stream.held = if stream.held.length() == 0 {
      arrived
    } else {
      stream.held + arrived
    }
  }
  for ;; {
    let parsed = match @http3.decode(stream.held[:], limit=field_section) {
      Some(v) => v
      None => break
    }
    let (frame, used) = parsed
    stream.held = stream.held[used:].to_owned()
    match frame {
      @http3.Frame::Headers(block) => self.section(at, block)
      @http3.Frame::Data(bytes) =>
        if bytes.length() > 0 {
          self.give(at, Body(bytes))
        }
      @http3.Frame::GoAway(_) => self.going = true
      _ => ()
    }
  }
  if !stream.closed &&
    self.quic.ended(stream.stream) &&
    stream.held.length() == 0 {
    stream.closed = true
    self.give(at, End(stream.trailers))
  }
}

///|
/// Take what arrived on every stream. A stream that arrived wrong is the connection's fault, not
/// its reader's, so the connection is marked dead and every reader is told.
fn H3::take(self : H3) -> Unit {
  for at, stream in self.streams {
    if stream.closed {
      continue
    }
    let outcome = Ok(self.absorb(at, stream)) catch { e => Err(e) }
    if outcome is Err(_) {
      self.dead = true
      stream.closed = true
      self.give(at, Fail(None))
    }
  }
}

///|
/// One turn of the connection: send what is queued, take a datagram in, and hand it to its
/// streams. Failures are recorded rather than raised: the task that happens to be stepping is
/// rarely the one the failure belongs to.
async fn H3::step(self : H3) -> Unit {
  self.stepping = true
  defer {
    self.stepping = false
    self.wake.broadcast()
  }
  let arrived = self.quic.step(timeout=5) catch {
    _ => {
      self.dead = true
      false
    }
  }
  if arrived {
    self.take()
  }
}

///|
/// Wait until `at` has something, stepping the connection while nobody else is.
async fn H3::wait(self : H3, at : Int32) -> Piece {
  let stream = match self.streams.get(at) {
    Some(stream) => stream
    None => raise Reset(code=refused_stream)
  }
  for ;; {
    let taken = stream.queue.try_get() catch { _ => None }
    match taken {
      Some(piece) => return piece
      None => ()
    }
    if self.dead {
      raise @http2.Incomplete
    }
    if self.stepping {
      self.wake.wait()
    } else {
      self.step()
    }
  }
}

///|
/// Start an exchange: the pseudo-fields of RFC 9114 §4.3.1, then the caller's own.
fn H3::open(self : H3, out : Outgoing) -> Int32 raise {
  guard !self.dead && !self.going else { raise Reset(code=refused_stream) }
  let at = self.next
  self.next += 1
  let sid = self.quic.open_bi()
  let fields : Array[@header.Header] = [
    @header.Header::of(":method", out.verb.name()),
    @header.Header::of(":scheme", out.scheme),
    @header.Header::of(":authority", out.authority),
    @header.Header::of(":path", out.target),
  ]
  for f in out.fields {
    let (name, value) = f.ascii()
    let lower = name.to_lower()
    if h3_allowed(lower) {
      fields.push(@header.Header::of(lower, value))
    }
  }
  self.streams[at] = {
    stream: sid,
    queue: @aqueue.Queue::Queue(kind=@aqueue.Kind::Unbounded),
    closed: false,
    status: 0,
    headers: [],
    trailers: [],
    held: b"",
    head: false,
  }
  let head = @http3.Frame::encode(@http3.Frame::Headers(@qpack.encode(fields)))
  let empty = out.payload.length() is Some(0)
  self.quic.write(sid, head, fin=empty)
  at
}

///|
/// Send the body as data frames, and end the stream once it is sent.
async fn H3::send_body(self : H3, at : Int32, payload : Payload) -> Unit {
  let stream = match self.streams.get(at) {
    Some(stream) => stream
    None => return
  }
  match payload {
    Whole(bytes) =>
      if bytes.length() > 0 {
        self.quic.write(
          stream.stream,
          @http3.Frame::encode(@http3.Frame::Data(bytes)),
          fin=false,
        )
      }
    Pieces(source) =>
      while source.next() is Some(piece) {
        if piece.length() > 0 {
          self.quic.write(
            stream.stream,
            @http3.Frame::encode(@http3.Frame::Data(piece)),
            fin=false,
          )
        }
      }
  }
}

///|
/// End the exchange's stream now that its body is sent.
fn H3::finish(self : H3, at : Int32) -> Unit {
  match self.streams.get(at) {
    Some(stream) if !stream.closed =>
      self.quic.write(stream.stream, b"", fin=true)
    _ => ()
  }
}

///|
/// One exchange, buffered: the response body is held to `limit` as it arrives.
async fn H3::exchange(self : H3, out : Outgoing, limit : Int32) -> Reply {
  let at = self.open(out)
  self.send_body(at, out.payload)
  self.finish(at)
  let body = Buffer()
  let mut got = 0
  let mut status = 0
  let mut headers = []
  for ;; {
    match self.wait(at) {
      Head(code, fields) => {
        status = code
        headers = fields
      }
      Body(piece) => {
        got += piece.length()
        if got > limit {
          self.abandon(at)
          raise Exceeded(limit~, got~)
        }
        body.write_bytes(piece)
      }
      End(_) => break
      Fail(code) => failed(code)
    }
  }
  {
    status,
    reason: "",
    version: "HTTP/3",
    headers,
    body: body.to_bytes(),
    reusable: !self.dead && !self.going,
  }
}

///|
/// Give up on an exchange: the stream is finished here, so the server's remaining octets are
/// dropped with the connection.
fn H3::abandon(self : H3, at : Int32) -> Unit {
  match self.streams.get(at) {
    Some(stream) if !stream.closed => stream.closed = true
    _ => ()
  }
}

///|
fn H3::close(self : H3) -> Unit {
  self.dead = true
  self.quic.close()
}

///|
fn H3::live(self : H3) -> Bool {
  !self.dead && !self.going
}
