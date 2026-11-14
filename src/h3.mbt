// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// HTTP/3, RFC 9114, over QUIC: the connection is moonnet's, which runs moonquic's state machine
// on a datagram socket, and the settings and QPACK are moonhttp's. What is here is the client:
// one connection per origin carrying many exchanges, one bidirectional stream each.

///|
/// How long a QUIC handshake may take before the client gives up on it and falls back to TCP:
/// the bound a browser gives one of two connections racing to the same origin.
let quic_timeout : Int32 = 3000

///|
/// The largest field section this side accepts, which is also the QPACK table it asks for: none,
/// so that a reply may only name static entries (RFC 9204 §3.2.1).
let field_section : UInt64 = 16384UL

///|
/// The frame types a request stream carries, RFC 9114 §7.2.
let frame_data : UInt64 = 0UL

///|
let frame_headers : UInt64 = 1UL

///|
let frame_cancel_push : UInt64 = 3UL

///|
let frame_settings : UInt64 = 4UL

///|
let frame_push_promise : UInt64 = 5UL

///|
let frame_goaway : UInt64 = 7UL

///|
let frame_max_push_id : UInt64 = 13UL

///|
/// Part of what arrived on a response stream.
priv enum FramePart {
  /// The field section that answers the request.
  Head(Bytes)
  /// A field section after the head: the trailers.
  Trailers(Bytes)
  /// Body octets, as they came.
  Data(Bytes)
}

///|
/// The frames of a response stream, read as they arrive.
///
/// A DATA frame may carry the whole body (RFC 9114 §7.2.2), so its payload is handed on in what
/// has arrived instead of being held until the frame ends: the octets are consumed as they come,
/// which is what gives the send window back to the server. A field section is small by the
/// settings this side sent, and is held until it is all there, since QPACK decodes it whole.
priv struct Frames {
  /// Octets that arrived and are not framed yet.
  mut held : Bytes
  /// Octets of the DATA payload in flight still to come.
  mut left : UInt64
  /// The head has been read, so the next field section is the trailers.
  mut head : Bool
  mut trailers : Bool
  /// The largest field section this side takes: what its SETTINGS advertise.
  limit : UInt64
}

///|
fn Frames::new() -> Frames {
  { held: b"", left: 0UL, head: false, trailers: false, limit: field_section, }
}

///|
/// Whether anything of a frame is still expected.
fn Frames::idle(self : Frames) -> Bool {
  self.left == 0UL && self.held.length() == 0
}

///|
/// Take what just arrived on the stream and answer with the parts it completes. A frame that is
/// not all there waits for the rest.
fn Frames::feed(self : Frames, bytes : Bytes) -> Array[FramePart] raise {
  let out : Array[FramePart] = []
  if bytes.length() > 0 {
    self.held = if self.held.length() == 0 { bytes } else { self.held + bytes }
  }
  for ;; {
    if self.left > 0UL && self.held.length() > 0 {
      let have = self.held.length().to_uint64()
      let take = if have < self.left { have } else { self.left }
      out.push(Data(self.held[0:take.to_int()].to_owned()))
      self.held = self.held[take.to_int():].to_owned()
      self.left = self.left - take
      continue
    }
    if self.held.length() == 0 {
      break
    }
    let (kind, type_len) = match @varint.decode(self.held[:]) {
      Some(v) => v
      None => break
    }
    let (length, len_len) = match @varint.decode(self.held[type_len:]) {
      Some(v) => v
      None => break
    }
    let header = type_len + len_len
    if kind == frame_data {
      // §4.1: the body rides DATA frames, after the head and before the trailers.
      guard self.head else {
        raise @http3.Refused::Malformed("DATA before HEADERS (RFC 9114 §4.1)")
      }
      guard !self.trailers else {
        raise @http3.Refused::Malformed(
          "DATA after the trailers (RFC 9114 §4.1)",
        )
      }
      self.held = self.held[header:].to_owned()
      self.left = length
      continue
    }
    // A field section is bounded by the settings this side sent; other frames are small.
    guard length <= self.limit else {
      raise @http3.Refused::Malformed(
        "a frame of \{length} octets, over the \{self.limit} this endpoint accepts",
      )
    }
    guard self.held.length() >= header + length.to_int() else { break }
    let payload = self.held[header:header + length.to_int()].to_owned()
    self.held = self.held[header + length.to_int():].to_owned()
    if kind == frame_headers {
      guard !self.trailers else {
        raise @http3.Refused::Malformed(
          "a HEADERS frame after the trailers (RFC 9114 §4.1)",
        )
      }
      if self.head {
        self.trailers = true
        out.push(Trailers(payload))
      } else {
        self.head = true
        out.push(Head(payload))
      }
    } else if kind == frame_cancel_push ||
      kind == frame_settings ||
      kind == frame_push_promise ||
      kind == frame_goaway ||
      kind == frame_max_push_id {
      raise @http3.Refused::Malformed(
        "a control or push frame on a request stream (RFC 9114 §7.2)",
      )
    }
    // Any other type is reserved: §9 lets a peer exercise it, and it is ignored.
  }
  out
}

///|
/// The stream ended. A stream that ends between the octets of a frame never carried the frame,
/// which §7.1 makes a frame error.
fn Frames::end(self : Frames) -> Unit raise {
  guard self.idle() else {
    raise @http3.Refused::Malformed("a response stream ending inside a frame")
  }
}

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
  frames : Frames
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
  /// This side's control stream, and what arrived on it that is not framed yet.
  control : UInt64
  mut told : Bytes
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
  let control = quic.open_uni()
  let settings = @http3.Settings::new(0UL, field_section, 0UL)
  quic.write(control, @http3.control(settings.pairs()), fin=false)
  {
    quic,
    wake: @cond_var.Cond(),
    streams: Map([]),
    next: 1,
    control,
    told: b"",
    stepping: false,
    dead: false,
    going: false,
  }
}

///|
/// What the control stream has to say. Its settings are the peer's business; a GOAWAY is not:
/// it names the last exchange the peer will take, and after it this side starts no more
/// (RFC 9114 §5.2). A control stream that ends is a connection error (§6.2.1).
fn H3::supervise(self : H3) -> Unit raise {
  let arrived = self.quic.take(self.control)
  if arrived.length() > 0 {
    self.told = if self.told.length() == 0 {
      arrived
    } else {
      self.told + arrived
    }
  }
  for ;; {
    let parsed = match @http3.decode(self.told[:], limit=field_section) {
      Some(v) => v
      None => break
    }
    let (frame, used) = parsed
    self.told = self.told[used:].to_owned()
    match frame {
      @http3.Frame::GoAway(_) => self.going = true
      _ => ()
    }
  }
  guard !self.quic.ended(self.control) else {
    raise @http3.Refused::Malformed("the peer ended its control stream")
  }
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
/// Hand a field section to its exchange: the head carries the status, the trailers are kept for
/// the end of the body.
fn H3::section(
  self : H3,
  at : Int32,
  block : Bytes,
  trailers~ : Bool,
) -> Unit raise {
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
  if trailers {
    stream.trailers = ascii(fields)
    return
  }
  for field in ascii(fields) {
    if field.0 == ":status" {
      stream.status = @string.parse_int(field.1) catch { _ => 0 }
    } else {
      stream.headers.push(field)
    }
  }
  self.give(at, Head(stream.status, stream.headers))
}

///|
/// Take what arrived on `at` and turn it into pieces.
fn H3::absorb(self : H3, at : Int32, stream : H3Stream) -> Unit raise {
  let arrived = self.quic.take(stream.stream)
  for part in stream.frames.feed(arrived) {
    match part {
      Head(block) => self.section(at, block, trailers=false)
      Trailers(block) => self.section(at, block, trailers=true)
      Data(bytes) => if bytes.length() > 0 { self.give(at, Body(bytes)) }
    }
  }
  if self.quic.ended(stream.stream) {
    stream.frames.end()
    if !stream.closed {
      stream.closed = true
      self.give(at, End(stream.trailers))
    }
  }
}

///|
/// Take what arrived on every stream. A stream that arrived wrong is the connection's fault, not
/// its reader's, so the connection is marked dead and every reader is told.
fn H3::take(self : H3) -> Unit {
  if !self.dead {
    let outcome = Ok(self.supervise()) catch { e => Err(e) }
    if outcome is Err(_) {
      self.dead = true
    }
  }
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
    if h2_carries(lower) {
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
    frames: Frames::new(),
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
fn H3::finish(self : H3, at : Int32) -> Unit raise {
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
