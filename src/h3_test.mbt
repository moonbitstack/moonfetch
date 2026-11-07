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
