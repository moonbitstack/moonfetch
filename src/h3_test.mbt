// HTTP/3 against a server that is not this repository's: `MOONFETCH_H3` names its base URL, and
// the run is expected to have one there (nginx with `--with-http_v3_module`, or a mooncat with
// its QUIC listener on). The certificate is the fixture root's, since a test server's own is not
// in the Mozilla list.

///|
fn h3_server() -> String? {
  @env.get_env_var("MOONFETCH_H3")
}

///|
async test "h3: a GET over QUIC answers with HTTP/3" {
  guard h3_server() is Some(base) else { return }
  let client = @moonfetch.Client::new(
    tls=trusting(),
    http3=true,
    timeout=Some(30000),
  )
  defer client.close()
  let r = client.get("\{base}/")
  assert_eq(r.status, 200)
  assert_eq(r.version, "HTTP/3")
  assert_eq(r.text(), "hello over h3\n")
}

///|
async test "h3: requests share one connection, and a body goes out on its stream" {
  guard h3_server() is Some(base) else { return }
  let client = @moonfetch.Client::new(
    tls=trusting(),
    http3=true,
    timeout=Some(30000),
  )
  defer client.close()
  for _ in 0..<3 {
    assert_eq(client.get("\{base}/").status, 200)
  }
  let posted = client.post("\{base}/echo", body=Text("over quic"))
  assert_eq(posted.status, 200)
  assert_eq(posted.version, "HTTP/3")
  guard posted.json() is Object(members) &&
    members.get("method") is Some(String(verb)) else {
    fail("no method in \{posted.text()}")
  }
  assert_eq(verb, "POST")
}

///|
async test "h3: a redirect is followed, and the answer names where it landed" {
  guard h3_server() is Some(base) else { return }
  let client = @moonfetch.Client::new(
    tls=trusting(),
    http3=true,
    timeout=Some(30000),
  )
  defer client.close()
  let r = client.get("\{base}/away")
  assert_eq(r.text(), "hello over h3\n")
  assert_eq(r.url, "\{base}/")
}

///|
async test "h3: many exchanges at once on the one connection" {
  guard h3_server() is Some(base) else { return }
  let client = @moonfetch.Client::new(
    tls=trusting(),
    http3=true,
    timeout=Some(30000),
  )
  defer client.close()
  let answered = Ref(0)
  @async.with_task_group(group => {
    for i in 0..<8 {
      group.spawn_bg(() => {
        let r = client.get("\{base}/echo?i=\{i}")
        assert_eq(r.status, 200)
        assert_eq(r.version, "HTTP/3")
        answered.val += 1
      })
    }
  })
  assert_eq(answered.val, 8)
}

///|
async test "h3: an origin that does not answer on the datagram is spoken to over TCP" {
  // The test server listens on TCP only, so the QUIC attempt runs out and the request goes the
  // other way; the second one takes the TCP path straight away instead of waiting again.
  with_servers(secure=true, (port, _, accepted) => {
    let client = @moonfetch.Client::new(
      tls=trusting(),
      http3=true,
      timeout=Some(60000),
    )
    defer client.close()
    let r = client.get("https://localhost:\{port}/")
    assert_eq(r.status, 200)
    assert_eq(r.text(), "hello")
    assert_true(r.version is ("HTTP/2" | "HTTP/1.1"))
    assert_eq(client.get("https://localhost:\{port}/").status, 200)
    assert_eq(accepted.val, 1)
  })
}

///|
async test "h3: a stream hands the body over as it arrives" {
  guard h3_server() is Some(base) else { return }
  let client = @moonfetch.Client::new(
    tls=trusting(),
    http3=true,
    timeout=Some(30000),
  )
  defer client.close()
  let stream = client.stream(@method.Method::Get, "\{base}/")
  assert_eq(stream.status(), 200)
  assert_eq(stream.version(), "HTTP/3")
  let text = StringBuilder()
  while stream.next() is Some(piece) {
    match piece {
      Data(bytes) => text.write_string(@utf8.decode_lossy(bytes[:]))
      End(_) => break
    }
  }
  assert_eq(text.to_string(), "hello over h3\n")
}

///|
/// Read the datagrams a probe has collected: take what arrived, then stop at a quiet gap.
async fn drain_datagrams(sock : @udp.Socket) -> Int32 {
  let seen = Ref(0)
  for _ in 0..<24 {
    match sock.recv(max=1500, timeout=250) {
      Some(_) => seen.val += 1
      None => break
    }
  }
  seen.val
}

///|
async test "h3: an origin that fell back to TCP sends no QUIC datagram on the next request" {
  // The server speaks only TCP, so the first request's QUIC race is lost and the exchange moves
  // to TCP; the second request must take the TCP path straight away, with no datagram leaving for
  // it, so the wait of the first attempt is not paid again.
  with_servers(secure=true, (port, _, accepted) => {
    let client = @moonfetch.Client::new(
      tls=trusting(),
      http3=true,
      timeout=Some(60000),
    )
    defer client.close()
    // Bind on the same port the client would send a QUIC Initial to, in whatever family
    // `localhost` resolves to: the client resolves it too, so the datagram lands here.
    let to = @socket.Addr::resolve("localhost", port~) catch {
      _ => fail("cannot resolve localhost")
    }
    let probe = @udp.bind(
      host=if to.is_ipv6() { "::" } else { "0.0.0.0" },
      port~,
    )
    defer probe.close()
    let first = client.get("https://localhost:\{port}/")
    assert_eq(first.status, 200)
    assert_true(first.version is ("HTTP/2" | "HTTP/1.1"))
    // The first request's QUIC Initials reached the wire before the handshake gave up.
    let sent_first = drain_datagrams(probe)
    assert_true(sent_first > 0)
    // The next request must take the TCP path straight away: no datagram leaves for it.
    let second = client.get("https://localhost:\{port}/")
    assert_eq(second.status, 200)
    let sent_second = drain_datagrams(probe)
    assert_eq(sent_second, 0)
    // The two requests shared the one TCP connection a non-racing second request reuses.
    assert_eq(accepted.val, 1)
  })
}
