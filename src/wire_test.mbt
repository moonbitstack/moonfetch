// The octets these functions hand back are the ones the transports write, so the cases here pin
// both: what a head looks like, and the frames a first request on an HTTP/2 connection is.

///|
test "wire: an HTTP/1.1 request is its head and its body" {
  let sent = @moonfetch.wire(
    @method.Method::Post,
    "https://example.com/a?b=1",
    body=@moonfetch.Body::Json({ "n": 1 }),
  ) catch {
    _ => fail("a plain request was refused")
  }
  assert_eq(sent.version, "HTTP/1.1")
  assert_eq(sent.pieces.length(), 2)
  assert_eq(sent.pieces[0].0, "request head")
  assert_eq(
    @utf8.decode_lossy(sent.pieces[0].1[:]),
    "POST /a?b=1 HTTP/1.1\r\nhost: example.com\r\ncontent-type: application/json\r\nuser-agent: moonfetch\r\naccept: */*\r\ncontent-length: 7\r\n\r\n",
  )
  assert_eq(sent.pieces[1].0, "body")
  assert_eq(@utf8.decode_lossy(sent.pieces[1].1[:]), "{\"n\":1}")
}

///|
test "wire: a GET carries no body, and its head says so by not saying otherwise" {
  let sent = @moonfetch.wire(@method.Method::Get, "https://example.com/", headers=[
    ("accept", "text/html"),
  ]) catch {
    _ => fail("a plain request was refused")
  }
  assert_eq(sent.pieces.length(), 1)
  assert_eq(
    @utf8.decode_lossy(sent.pieces[0].1[:]),
    "GET / HTTP/1.1\r\nhost: example.com\r\naccept: text/html\r\nuser-agent: moonfetch\r\n\r\n",
  )
}

///|
test "wire: a URL no request can name is refused" {
  let outcome = try {
    ignore(@moonfetch.wire(@method.Method::Get, "ftp://example.com/"))
    false
  } catch {
    @moonfetch.Refused::Url(_) => true
    _ => false
  }
  assert_true(outcome)
}

///|
test "frames: the preface, the settings, then the exchange" {
  let sent = @moonfetch.frames(@method.Method::Get, "https://example.com/a") catch {
    _ => fail("a plain request was refused")
  }
  assert_eq(sent.version, "HTTP/2")
  assert_eq(sent.pieces.map(p => p.0), [
    "connection preface", "SETTINGS", "HEADERS + END_STREAM",
  ])
  assert_eq(
    @utf8.decode_lossy(sent.pieces[0].1[:]),
    "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n",
  )
  // A field section is HPACK, so its octets are not text; what is checked is that there are some.
  assert_true(sent.pieces[2].1.length() > 9)
}

///|
test "frames: a body becomes DATA frames, and the connection-facing fields go" {
  let body = Bytes::make(40000, b'x')
  let sent = @moonfetch.frames(
    @method.Method::Post,
    "http://example.com/upload",
    headers=[("connection", "keep-alive"), ("host", "elsewhere")],
    body=@moonfetch.Body::Bytes(body),
  ) catch {
    _ => fail("a plain request was refused")
  }
  let labels = sent.pieces.map(p => p.0)
  assert_true(labels.any(label => label.has_prefix("HEADERS")))
  // 40000 octets are more than the largest frame this side sends, so the body is cut into
  // several, and the last of them ends the stream.
  assert_eq(labels.filter(label => label.has_prefix("DATA")).length(), 4)
  assert_true(labels.any(label => label == "DATA + END_STREAM"))
}
