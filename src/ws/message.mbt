// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A frame about to go out.
fn frame_of(
  fin : Bool,
  opcode : @frame.Opcode,
  payload : Bytes,
) -> @frame.Frame {
  { fin, opcode, payload, }
}

///|
/// Read more octets into the buffer, or `false` when the peer closed.
async fn WebSocket::fill(self : WebSocket) -> Bool {
  match self.conn.read_some(max_len=16384) {
    Some(data) => {
      self.held.write_bytes(data)
      true
    }
    None => false
  }
}

///|
/// The next whole frame, `None` at the end of the connection.
async fn WebSocket::frame(self : WebSocket) -> @frame.Frame? {
  for ;; {
    let bytes = self.held.to_bytes()
    match @frame.decode(bytes[:], client=false, limit~) {
      Some((frame, used)) => {
        let rest = Buffer()
        rest.write_bytes(bytes[used:])
        self.held = rest
        return Some(frame)
      }
      None => if !self.fill() { return None }
    }
  }
}

///|
/// One frame out, masked as a client must (RFC 6455 §5.3).
async fn WebSocket::write(self : WebSocket, frame : @frame.Frame) -> Unit {
  let mask = @moonseed.bytes(4, @system.source)
  self.conn.write(frame.encode(mask~))
}

///|
/// Send a message. A `Text` must be UTF-8, which a `String` already is; a `Close` starts the
/// closing handshake and the socket is closed at once.
pub async fn WebSocket::send(self : WebSocket, message : Message) -> Unit {
  guard !self.closed else { raise Protocol("the connection is closed") }
  match message {
    Text(text) => self.write(frame_of(true, @frame.Text, @utf8.encode(text)))
    Binary(bytes) => self.write(frame_of(true, @frame.Binary, bytes))
    Close(status~, reason~) => {
      self.write(
        frame_of(
          true,
          @frame.Close,
          @frame.close(status, reason=@utf8.decode_lossy(reason[:])),
        ),
      )
      self.closed = true
      self.conn.close()
    }
  }
}

///|
pub async fn WebSocket::send_text(self : WebSocket, text : StringView) -> Unit {
  self.send(Text(text.to_owned()))
}

///|
pub async fn WebSocket::send_binary(self : WebSocket, bytes : Bytes) -> Unit {
  self.send(Binary(bytes))
}

///|
/// A message built from the frames that carried it.
fn assemble(opcode : @frame.Opcode, payload : Bytes) -> Message raise {
  match opcode {
    Text => Text(@utf8.decode_lossy(payload[:]))
    Binary => Binary(payload)
    _ => raise Protocol("a data message must be text or binary")
  }
}

///|
/// The next message, `None` once the connection is closed.
///
/// Ping frames are answered and pong frames dropped here, so they never reach the caller. A
/// message split over several frames is put back together. A close frame is answered and
/// returned; after it the connection is closed.
pub async fn WebSocket::recv(self : WebSocket) -> Message? {
  guard !self.closed else { return None }
  let mut kind : @frame.Opcode? = None
  let body = Buffer()
  for ;; {
    let frame = match self.frame() {
      Some(frame) => frame
      None => {
        self.closed = true
        return None
      }
    }
    match frame.opcode {
      @frame.Ping => self.write(frame_of(true, @frame.Pong, frame.payload))
      @frame.Pong => ()
      @frame.Close => {
        let status = @frame.status(frame.payload[:])
        let reason = @frame.reason(frame.payload[:])
        if !self.closed {
          self.write(frame_of(true, @frame.Close, frame.payload))
        }
        self.closed = true
        self.conn.close()
        return Some(Close(status~, reason~))
      }
      @frame.Text | @frame.Binary => {
        guard kind is None else {
          raise Protocol("a new message began before the last one ended")
        }
        if frame.fin {
          return Some(assemble(frame.opcode, frame.payload))
        }
        kind = Some(frame.opcode)
        body.write_bytes(frame.payload)
      }
      @frame.Continuation => {
        let opcode = match kind {
          Some(opcode) => opcode
          None => raise Protocol("a continuation with no message to continue")
        }
        body.write_bytes(frame.payload)
        guard body.length() <= limit else {
          raise Protocol("message over \{limit} octets")
        }
        if frame.fin {
          return Some(assemble(opcode, body.to_bytes()))
        }
      }
    }
  }
  abort("unreachable")
}

///|
/// The peer's close frame, which ends the closing handshake.
async fn WebSocket::wait_close(self : WebSocket) -> Unit {
  for ;; {
    match self.frame() {
      None => return
      Some(frame) => if frame.opcode is @frame.Close { return }
    }
  }
}

///|
/// Close the connection: a close frame, then the peer's, then the socket. A peer that does not
/// answer within two seconds is dropped rather than waited for.
pub async fn WebSocket::close(
  self : WebSocket,
  status? : Int32,
  reason? : String,
) -> Unit {
  guard !self.closed else { return }
  self.write(
    frame_of(true, @frame.Close, @frame.close(status.unwrap_or(1000), reason?)),
  )
  self.closed = true
  ignore(@async.with_timeout_opt(2000, () => self.wait_close()))
  self.conn.close()
}
