// A small HTTP/1.1 and HTTP/2 server for the tests, on moonhttp's server state machines over
// moonnet: the other end is not this library's code.

///|
fn names(fields : Array[@header.Header]) -> Array[(String, String)] {
  fields.map(f => {
    let (name, value) = f.ascii()
    (name.to_lower(), value)
  })
}

///|
fn field(fields : Array[(String, String)], name : String) -> String {
  for f in fields {
    if f.0 == name {
      return f.1
    }
  }
  ""
}

///|
fn pattern(n : Int32) -> Bytes {
  Bytes::makei(n, i => (i % 251).to_byte())
}

///|
/// What a route asks of the connection after its answer.
priv enum After {
  Keep
  /// Close without saying so, as a server does to an idle keep-alive connection.
  Drop
  /// Send part of the body, then close.
  Truncate
  /// Answer, then GOAWAY and close (HTTP/2).
  GoAway
  /// Send the body chunked, a piece at a time (HTTP/1.1).
  Chunked
  /// Send the body without a length and close to end it (HTTP/1.1).
  Eof
  /// Send a 103 Early Hints first (HTTP/1.1).
  Hints
}

///|
/// The routes every test talks to: `(status, headers, body, after)` for a request. `other` is
/// the port of a second server, for redirects that leave the origin.
async fn route(
  verb : String,
  target : String,
  fields : Array[(String, String)],
  body : Bytes,
  version : String,
  other : Int32,
) -> (Int32, Array[(String, String)], Bytes, After) {
  let (path, query) = match target.split_once("?") {
    Some((p, q)) => (p.to_owned(), q.to_owned())
    None => (target, "")
  }
  let text = [("content-type", "text/plain")]
  match path {
    "/" => (200, text, b"hello", Keep)
    "/echo" => {
      let echoed : Json = {
        "method": Json(verb),
        "query": Json(query),
        "body": Json(@utf8.decode_lossy(body[:])),
        "type": Json(field(fields, "content-type")),
        "agent": Json(field(fields, "user-agent")),
        "auth": Json(field(fields, "authorization")),
        "extra": Json(field(fields, "x-extra")),
        "version": Json(version),
      }
      (
        200,
        [("content-type", "application/json")],
        @utf8.encode(echoed.stringify()),
        Keep,
      )
    }
    "/upload" => {
      let mut sum = 0
      for b in body {
        sum = (sum * 31 + b.to_int()) % 1000000007
      }
      (200, text, @utf8.encode("\{body.length()}:\{sum}"), Keep)
    }
    "/big" => {
      let n = @string.parse_int(query.strip_prefix("n=").unwrap_or(query)) catch {
        _ => 0
      }
      (200, [("content-type", "application/octet-stream")], pattern(n), Keep)
    }
    "/gzip" =>
      (
        200,
        [("content-encoding", "gzip"), ..text],
        @gzip.gzip(b"compressed hello"[:]),
        Keep,
      )
    "/deflate" =>
      (
        200,
        [("content-encoding", "deflate"), ..text],
        @zlib.zlib(b"zlib hello"[:]),
        Keep,
      )
    "/raw-deflate" =>
      (
        200,
        [("content-encoding", "deflate"), ..text],
        @deflate.deflate(b"bare hello"[:]),
        Keep,
      )
    "/brotli" => (200, [("content-encoding", "br"), ..text], b"not br", Keep)
    "/chunked" => (200, text, b"in pieces", Chunked)
    "/eof" => (200, text, b"to the close", Eof)
    "/hints" => (200, text, b"after hints", Hints)
    "/see-other" => (303, [("location", "/echo")], b"", Keep)
    "/found" => (302, [("location", "/echo")], b"", Keep)
    "/keep" => (307, [("location", "/echo")], b"", Keep)
    "/loop" => (302, [("location", "/loop")], b"", Keep)
    "/away" =>
      (302, [("location", "http://localhost:\{other}/echo")], b"", Keep)
    "/slow" => {
      @async.sleep(2000)
      (200, text, b"late", Keep)
    }
    "/close" => (200, [("connection", "close"), ..text], b"closing", Keep)
    "/drop" => (200, text, b"dropped after", Drop)
    "/truncate" => (200, text, b"0123456789", Truncate)
    "/goaway" => (200, text, b"going", GoAway)
    p if p.has_prefix("/redirect/") => {
      let n = @string.parse_int(p[10:]) catch { _ => 0 }
      if n <= 0 {
        (200, text, b"landed", Keep)
      } else {
        (302, [("location", "/redirect/\{n - 1}")], b"", Keep)
      }
    }
    p if p.has_prefix("/status/") => {
      let n = @string.parse_int(p[8:]) catch { _ => 500 }
      (n, text, b"", Keep)
    }
    _ => (404, text, b"no such route", Keep)
  }
}

///|
async fn serve_h1(conn : @tcp.Conn, other : Int32, seen : Seen) -> Unit {
  let wire = @http1.Conn::new(Server)
  for ;; {
    let mut head = None
    let body = Buffer()
    let mut ended = false
    while !ended {
      match wire.next() {
        NeedData => {
          guard conn.read_some(max_len=16384) is Some(data) else { return }
          wire.receive(data[:])
        }
        Request(r) => {
          head = Some(r)
          seen.mark()
        }
        Data(piece) => body.write_bytes(piece)
        End(_) => ended = true
        Closed | Paused => return
        _ => ()
      }
    }
    guard head is Some(r) else { return }
    let (status, fields, payload, after) = route(
      r.verb,
      r.target,
      names(r.fields),
      body.to_bytes(),
      "HTTP/1.1",
      other,
    )
    let framing : @http1.Body = match after {
      Truncate => Sized(100)
      Chunked => Chunked
      Eof => Closed
      _ => Sized(payload.length())
    }
    let response = @http1.Response::of(
      status,
      fields=fields.map(f => @header.Header::of(f.0, f.1)),
      body=framing,
    )
    let out = Buffer()
    if after is Hints {
      let hint = @http1.Response::of(103, fields=[
        @header.Header::of("link", "</style.css>; rel=preload"),
      ])
      out.write_bytes(wire.send(Informational(hint)))
    }
    out.write_bytes(wire.send(Response(response)))
    if after is Chunked {
      for piece in [payload[0:3], payload[3:6], payload[6:]] {
        out.write_bytes(wire.send(Data(piece.to_owned())))
      }
      out.write_bytes(wire.send(End([])))
      conn.write(out.to_bytes())
      wire.start_next()
      continue
    }
    if after is Truncate {
      // Fewer octets than the Content-Length promised, written past the state machine.
      out.write_bytes(payload)
      conn.write(out.to_bytes())
      return
    }
    if payload.length() > 0 {
      out.write_bytes(wire.send(Data(payload)))
    }
    out.write_bytes(wire.send(End([])))
    conn.write(out.to_bytes())
    if after is Drop {
      return
    }
    guard wire.ours() is Done && wire.theirs() is Done else { return }
    wire.start_next()
  }
}

///|
async fn serve_h2(conn : @tcp.Conn, other : Int32, seen : Seen) -> Unit {
  let wire = @http2.Conn::new(Server)
  let open : Map[Int32, (Array[(String, String)], Buffer)] = Map([])
  // Bodies waiting for window: stream, the rest of the body.
  let queued : Map[Int32, Bytes] = Map([])
  let mut going = false
  for ;; {
    for pending in queued.to_array() {
      let (stream, rest) = pending
      let room = wire.window(stream)
      if room > 0 {
        let n = if room < rest.length() { room } else { rest.length() }
        wire.data(stream, rest[:n], end=n == rest.length())
        if n == rest.length() {
          queued.remove(stream)
        } else {
          queued[stream] = rest[n:].to_owned()
        }
      }
    }
    let out = wire.take()
    if out.length() > 0 {
      conn.write(out)
    }
    if going && queued.is_empty() {
      wire.goaway()
      conn.write(wire.take())
      return
    }
    match wire.next() {
      NeedData => {
        guard conn.read_some(max_len=16384) is Some(data) else { return }
        wire.receive(data[:])
      }
      Request(stream~, fields~) => {
        open[stream] = (names(fields), Buffer())
        seen.mark()
      }
      Data(stream~, data~) => {
        if open.get(stream) is Some((_, buf)) {
          buf.write_bytes(data)
        }
        wire.acknowledge(stream, data.length())
      }
      End(stream~) => {
        guard open.get(stream) is Some((fields, buf)) else { continue }
        open.remove(stream)
        let verb = field(fields, ":method")
        let (status, extra, payload, after) = route(
          verb,
          field(fields, ":path"),
          fields,
          buf.to_bytes(),
          "HTTP/2",
          other,
        )
        let head = [@header.Header::of(":status", status.to_string())]
        for f in extra {
          if f.0 != "connection" {
            head.push(@header.Header::of(f.0, f.1))
          }
        }
        let bare = payload.length() == 0 || verb == "HEAD"
        wire.headers(stream, head, end=bare)
        if !bare {
          queued[stream] = payload
        }
        if after is GoAway {
          going = true
        }
      }
      Closed | GoAway(..) => return
      _ => ()
    }
  }
}

///|
/// Counts a connection once, at its first request: a dialler racing two connects closes the
/// loser before it says anything, and that one is not counted.
priv struct Seen {
  mut used : Bool
  accepted : Ref[Int32]
}

///|
fn Seen::mark(self : Seen) -> Unit {
  if !self.used {
    self.used = true
    self.accepted.val += 1
  }
}

///|
/// Serve the routes on `listener`, counting in `accepted` the connections that carried a request.
async fn test_server(
  listener : @tcp.Listener,
  accepted : Ref[Int32],
  other : Int32,
) -> Unit {
  listener.serve((conn, _) => {
    let seen = { used: false, accepted, }
    let h2 = match conn.alpn() {
      Some(p) => p == "h2"
      None => conn.starts_with(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"[:])
    }
    if h2 {
      serve_h2(conn, other, seen)
    } else {
      serve_h1(conn, other, seen)
    }
  })
}

///|
fn server_tls() -> @tls.Server raise {
  @tls.Server::new(@x509.pems(cert), @x509.PrivateKey::pem(key), alpn=[
    "h2", "http/1.1",
  ])
}

///|
fn trusting() -> @tls.Client raise {
  @tls.Client::new(@x509.Roots::new(certs=@x509.pems(root)[:]))
}

///|
/// Run `body` with a server on a free port (TLS when `secure`), the port of a second server in
/// the clear, and the first server's connection count. Bounded, so a hang fails the test rather
/// than the suite.
async fn with_servers(
  body : async (Int32, Int32, Ref[Int32]) -> Unit,
  secure~ : Bool = false,
) -> Unit {
  let accepted = Ref(0)
  let tls = if secure { Some(server_tls()) } else { None }
  @async.with_timeout(180000, () => {
    @async.with_task_group(g => {
      let main = @tcp.listen(port=0, tls?)
      let side = @tcp.listen(port=0)
      let port = main.addr().port()
      let other = side.addr().port()
      let a = g.spawn(() => test_server(main, accepted, other))
      let b = g.spawn(() => test_server(side, Ref(0), port))
      body(port, other, accepted)
      a.cancel()
      b.cancel()
    })
  })
}
