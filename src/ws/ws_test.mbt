// The WebSocket client against a server that speaks the protocol: RFC 6455 §4 and §5.

///|
let ws_accept_guid : String = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

///|
/// A frame the test server sends.
fn srv_frame(
  fin : Bool,
  opcode : @frame.Opcode,
  payload : Bytes,
) -> @frame.Frame {
  { fin, opcode, payload, }
}

///|
/// The text a message carries, or a failure.
fn expect_text(message : @ws.Message?, want : String) -> Unit raise {
  match message {
    Some(Text(text)) => assert_eq(text, want)
    _ => fail("expected text \{want}")
  }
}

///|
/// What the WebSocket test server remembers.
priv struct WsLog {
  mut pong : Bool
  mut protocol : String
  mut path : String
}

///|
/// A WebSocket server: echo text and binary, split one message over two frames, ping, and
/// answer a close.
async fn serve_ws(conn : @tcp.Conn, log : WsLog) -> Unit {
  let held = Buffer()
  for ;; {
    if held.to_bytes().find(b"\r\n\r\n") is Some(_) {
      break
    }
    guard held.length() < 65536 else { return }
    match conn.read_some(max_len=16384) {
      Some(data) => held.write_bytes(data)
      None => return
    }
  }
  let bytes = held.to_bytes()
  let at = bytes.find(b"\r\n\r\n").unwrap()
  let head = @utf8.decode_lossy(bytes[0:at][:])
  let mut key = ""
  for i, line in head.split("\r\n").to_array() {
    if i == 0 {
      let parts = line.split(" ").to_array()
      if parts.length() >= 2 {
        log.path = parts[1].to_owned()
      }
    } else if line.to_lower().has_prefix("sec-websocket-key:") {
      key = line[18:].trim(chars=" ").to_owned()
    } else if line.to_lower().has_prefix("sec-websocket-protocol:") {
      // A server picks one of the offered protocols.
      let offered = line[23:].trim(chars=" ").to_owned()
      log.protocol = match offered.split_once(",") {
        Some((first, _)) => first.trim(chars=" ").to_owned()
        None => offered
      }
    }
  }
  let rest = Ref(Buffer())
  rest.val.write_bytes(bytes[at + 4:])
  let accept = @base64.encode(@sha1.hash(@utf8.encode(key + ws_accept_guid)))
  let answer = "HTTP/1.1 101 Switching Protocols\r\n" +
    "Upgrade: websocket\r\n" +
    "Connection: Upgrade\r\n" +
    "Sec-WebSocket-Accept: \{accept}\r\n" +
    "Sec-WebSocket-Protocol: \{log.protocol}\r\n" +
    "\r\n"
  conn.write(@utf8.encode(answer))
  for ;; {
    let frame = match
      @frame.decode(rest.val.to_bytes()[:], client=true, limit=1 << 20) {
      Some((frame, used)) => {
        let left = Buffer()
        left.write_bytes(rest.val.to_bytes()[used:])
        rest.val = left
        frame
      }
      None =>
        match conn.read_some(max_len=16384) {
          Some(data) => {
            rest.val.write_bytes(data)
            continue
          }
          None => return
        }
    }
    match frame.opcode {
      @frame.Text => {
        let text = @utf8.decode_lossy(frame.payload[:])
        if text == "split" {
          // The ping comes inside the fragmented message, so it is taken while assembling.
          conn.write(srv_frame(true, @frame.Ping, b"p").encode())
          conn.write(srv_frame(false, @frame.Text, b"split-").encode())
          conn.write(srv_frame(true, @frame.Continuation, b"in-two").encode())
        } else {
          let payload = @utf8.encode("echo:" + text)
          conn.write(srv_frame(true, @frame.Text, payload).encode())
        }
      }
      @frame.Binary =>
        conn.write(srv_frame(true, @frame.Binary, frame.payload).encode())
      @frame.Ping =>
        conn.write(srv_frame(true, @frame.Pong, frame.payload).encode())
      @frame.Pong => log.pong = true
      @frame.Close => {
        conn.write(srv_frame(true, @frame.Close, frame.payload).encode())
        return
      }
      @frame.Continuation => ()
    }
  }
}

///|
/// Run `body` against a WebSocket server, in the clear or over TLS.
async fn with_ws(
  body : async (Int32, WsLog) -> Unit,
  secure~ : Bool = false,
) -> Unit {
  @async.with_timeout(120000, () => {
    @async.with_task_group(g => {
      let log = { pong: false, protocol: "", path: "", }
      let tls = if secure {
        Some(
          @tls.Server::new(@x509.pems(ws_cert), @x509.PrivateKey::pem(ws_key), alpn=[
            "http/1.1",
          ]),
        )
      } else {
        None
      }
      let listener = @tcp.listen(port=0, tls?)
      let task = g.spawn(() => listener.serve((conn, _) => serve_ws(conn, log)))
      body(listener.addr().port(), log)
      task.cancel()
    })
  })
}

///|
fn ws_trusting() -> @tls.Client raise {
  @tls.Client::new(@x509.Roots::new(certs=@x509.pems(ws_root)[:]))
}

///|
async test "ws: a text message goes and comes back, and the handshake is the one RFC 6455 wants" {
  with_ws((port, log) => {
    let client = @moonfetch.Client::new()
    defer client.close()
    let socket = @ws.connect(client, "ws://127.0.0.1:\{port}/chat", protocols=[
      "chat", "superchat",
    ])
    assert_eq(socket.protocol(), Some("chat"))
    assert_eq(log.path, "/chat")
    socket.send_text("hello")
    expect_text(socket.recv(), "echo:hello")
    socket.send(Text("again"))
    expect_text(socket.recv(), "echo:again")
    socket.send(Binary(b"\x00\x01\x02"))
    match socket.recv() {
      Some(Binary(bytes)) => assert_eq(bytes, b"\x00\x01\x02")
      _ => fail("no binary came back")
    }
    socket.close(status=1000, reason="done")
    assert_true(socket.is_closed())
  })
}

///|
async test "ws: a message split over frames is put together, and a ping is answered" {
  with_ws((port, log) => {
    let client = @moonfetch.Client::new()
    defer client.close()
    let socket = @ws.connect(client, "ws://127.0.0.1:\{port}/split")
    socket.send_text("split")
    expect_text(socket.recv(), "split-in-two")
    // The ping came between the frames; the pong went back without the caller seeing either.
    @async.sleep(50)
    assert_true(log.pong)
    socket.close()
  })
}

///|
async test "ws: wss verifies the server like https does" {
  with_ws(secure=true, (port, _) => {
    let client = @moonfetch.Client::new(tls=ws_trusting())
    defer client.close()
    let socket = @ws.connect(client, "wss://localhost:\{port}/secure")
    socket.send_text("tls")
    expect_text(socket.recv(), "echo:tls")
    let stranger = @moonfetch.Client::new(
      tls=@tls.Client::new(@x509.Roots::new(certs=[])),
    )
    defer stranger.close()
    let refused = try {
      let _closed = @ws.connect(stranger, "wss://localhost:\{port}/secure")
      false
    } catch {
      _ => true
    }
    assert_true(refused)
  })
}

///|
async test "ws: the server's close ends the exchange" {
  with_ws((port, _) => {
    let client = @moonfetch.Client::new()
    defer client.close()
    let socket = @ws.connect(client, "ws://127.0.0.1:\{port}/bye")
    socket.send(Close(status=1001, reason=b"going"))
    // The client's close frame is answered by the server, so the read ends cleanly.
    assert_true(socket.recv() is None)
  })
}

///|
/// The same test certificate the rest of the suite uses; a package cannot see another
/// package's test fixtures.
let ws_root : String =
  #|-----BEGIN CERTIFICATE-----
  #|MIIBUDCB96ADAgECAhRZrqGMqdHBmQ6rYqs5Nef5wV7AbTAKBggqhkjOPQQDAjAe
  #|MRwwGgYDVQQDDBNtb29uZmV0Y2ggdGVzdCByb290MB4XDTIwMDEwMTAwMDAwMFoX
  #|DTQwMDEwMTAwMDAwMFowHjEcMBoGA1UEAwwTbW9vbmZldGNoIHRlc3Qgcm9vdDBZ
  #|MBMGByqGSM49AgEGCCqGSM49AwEHA0IABH3R2gdGYvaCUv7w1ri97+XdgVwU2KzO
  #|4usUdhwWlhmYCmXPATtc8Toyst2HlzQrq8oICi3HMZVb2Emm9WranbWjEzARMA8G
  #|A1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIgIakMXTNQdX0efvT8tKjP
  #|ct5AnQGBqJxGs4VUcnqT48MCIQCql59ak6BCueBwJjtt04ygEB0H8VUkS3jsvJQj
  #|1vJbbg==
  #|-----END CERTIFICATE-----

///|
let ws_cert : String =
  #|-----BEGIN CERTIFICATE-----
  #|MIIBZzCCAQ2gAwIBAgIUXn8s2zP4hqXWVPVvi5vO1H9nkkYwCgYIKoZIzj0EAwIw
  #|HjEcMBoGA1UEAwwTbW9vbmZldGNoIHRlc3Qgcm9vdDAeFw0yMDAxMDEwMDAwMDBa
  #|Fw00MDAxMDEwMDAwMDBaMBQxEjAQBgNVBAMMCWxvY2FsaG9zdDBZMBMGByqGSM49
  #|AgEGCCqGSM49AwEHA0IABPTRkG0eic/XGf8YmWDAKYJEC4TLSP5Cj1QrffqG+ME8
  #|0DpxbQJuCe4CRRKsAith9O+Or2D93YoN6ecJLcpNjO6jMzAxMBoGA1UdEQQTMBGC
  #|CWxvY2FsaG9zdIcEfwAAATATBgNVHSUEDDAKBggrBgEFBQcDATAKBggqhkjOPQQD
  #|AgNIADBFAiEA4Jnmys3aJBJF7/49dXtofAnXMus9lQHzIbOZ0K35CeMCIHnCTQzU
  #|7igtfgVqPoXvSpNYRQE2BrUWC4aQ/7liXvmR
  #|-----END CERTIFICATE-----

///|
let ws_key : String =
  #|-----BEGIN PRIVATE KEY-----
  #|MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgSaPR5t7zyPcLc9Pq
  #|sW+cWIAVPsJVpr56zXfyh2rsHVmhRANCAAT00ZBtHonP1xn/GJlgwCmCRAuEy0j+
  #|Qo9UK336hvjBPNA6cW0CbgnuAkUSrAIrYfTvjq9g/d2KDennCS3KTYzu
  #|-----END PRIVATE KEY-----
