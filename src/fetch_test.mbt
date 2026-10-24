///|
fn echoed(response : @moonfetch.Response, key : String) -> String raise {
  guard response.json() is Object(members) &&
    members.get(key) is Some(String(v)) else {
    fail("no \{key} in \{response.text()}")
  }
  v
}

///|
async fn refusal(f : async () -> @moonfetch.Response) -> Error {
  try f() catch {
    e => e
  } noraise {
    r => fail("answered \{r.status}")
  }
}

///|
fn digest(body : Bytes) -> String {
  let mut sum = 0
  for b in body {
    sum = (sum * 31 + b.to_int()) % 1000000007
  }
  "\{body.length()}:\{sum}"
}

///|
async test "fetch: a GET in the clear, and the connection is kept for the next" {
  with_servers((port, _, accepted) => {
    let client = @moonfetch.Client::new()
    defer client.close()
    for _ in 0..<3 {
      let r = client.get("http://127.0.0.1:\{port}/")
      assert_eq(r.status, 200)
      assert_eq(r.text(), "hello")
      assert_eq(r.version, "HTTP/1.1")
      assert_eq(r.header("Content-Type"), Some("text/plain"))
    }
    assert_eq(accepted.val, 1)
  })
}

///|
async test "fetch: https settles on HTTP/2 by ALPN, one connection carries every request" {
  with_servers(secure=true, (port, _, accepted) => {
    let client = @moonfetch.Client::new(tls=trusting())
    defer client.close()
    for _ in 0..<3 {
      let r = client.get("https://localhost:\{port}/echo")
      assert_eq(echoed(r, "version"), "HTTP/2")
      assert_eq(r.version, "HTTP/2")
    }
    assert_eq(accepted.val, 1)
    let h1 = @moonfetch.Client::new(tls=trusting(), http2=false)
    defer h1.close()
    assert_eq(h1.get("https://localhost:\{port}/").version, "HTTP/1.1")
    let stranger = @moonfetch.Client::new(
      tls=@tls.Client::new(@x509.Roots::new(certs=@x509.pems(other_root)[:])),
    )
    defer stranger.close()
    assert_true(
      refusal(() => stranger.get("https://localhost:\{port}/"))
      is @alert.Alert(kind=UnknownCa, ..),
    )
  })
}

///|
async test "fetch: each body goes with its content type, over both versions" {
  let cases : Array[(@moonfetch.Body, String, String)] = [
    (Text("plain"), "plain", "text/plain; charset=utf-8"),
    (Bytes(b"raw"), "raw", "application/octet-stream"),
    (Json({ "a": 1 }), "{\"a\":1}", "application/json"),
    (
      Form([("q", "two words"), ("x", "&")]),
      "q=two+words&x=%26",
      "application/x-www-form-urlencoded",
    ),
  ]
  with_servers(secure=true, (port, other, _) => {
    for base in ["https://localhost:\{port}", "http://localhost:\{other}"] {
      let client = @moonfetch.Client::new(base_url=base, tls=trusting())
      defer client.close()
      for case in cases {
        let (body, wire, kind) = case
        let r = client.post("/echo", body~)
        assert_eq(echoed(r, "body"), wire)
        assert_eq(echoed(r, "type"), kind)
      }
      let named = client.post("/echo", body=Text("{}"), headers=[
        ("Content-Type", "application/merge-patch+json"),
      ])
      assert_eq(echoed(named, "type"), "application/merge-patch+json")
      assert_eq(echoed(client.put("/echo"), "method"), "PUT")
      assert_eq(echoed(client.patch("/echo"), "method"), "PATCH")
      assert_eq(echoed(client.delete("/echo"), "method"), "DELETE")
      assert_eq(client.options("/").status, 200)
    }
  })
}

///|
async test "fetch: base URL, query and headers combine as httpx combines them" {
  with_servers((port, _, _) => {
    let client = @moonfetch.Client::new(
      base_url="http://127.0.0.1:\{port}/redirect",
      headers=[("x-extra", "client"), ("user-agent", "custom")],
    )
    defer client.close()
    assert_eq(client.get("/0").text(), "landed")
    let r = client.get(
      "http://127.0.0.1:\{port}/echo?x=1",
      query=[("y", "2 3")],
      headers=[("X-Extra", "call")],
    )
    assert_eq(echoed(r, "query"), "x=1&y=2+3")
    assert_eq(echoed(r, "extra"), "call")
    assert_eq(echoed(r, "agent"), "custom")
  })
}

///|
async test "fetch: redirects are followed, capped, not followed at all, and a loop ends" {
  with_servers((port, _, _) => {
    let client = @moonfetch.Client::new(base_url="http://127.0.0.1:\{port}")
    defer client.close()
    let r = client.get("/redirect/3")
    assert_eq(r.text(), "landed")
    assert_eq(r.url, "http://127.0.0.1:\{port}/redirect/0")
    assert_true(
      refusal(() => client.get("/redirect/3", redirects=2))
      is @moonfetch.Redirects(limit=2),
    )
    assert_eq(client.get("/redirect/3", redirects=0).status, 302)
    assert_true(
      refusal(() => client.get("/loop")) is @moonfetch.Redirects(limit=10),
    )
  })
}

///|
async test "fetch: a 303 and a POST's 302 turn into GET; a 307 keeps the method and body" {
  with_servers((port, _, _) => {
    let client = @moonfetch.Client::new(base_url="http://127.0.0.1:\{port}")
    defer client.close()
    let seen = client.post("/see-other", body=Text("x"))
    assert_eq(echoed(seen, "method"), "GET")
    assert_eq(echoed(seen, "body"), "")
    assert_eq(echoed(client.post("/found", body=Text("x")), "method"), "GET")
    let kept = client.post("/keep", body=Text("kept"))
    assert_eq(echoed(kept, "method"), "POST")
    assert_eq(echoed(kept, "body"), "kept")
  })
}

///|
async test "fetch: credentials stay with their origin across a redirect" {
  with_servers((port, other, _) => {
    let client = @moonfetch.Client::new(base_url="http://localhost:\{port}", headers=[
      ("authorization", "Bearer t"),
    ])
    defer client.close()
    assert_eq(echoed(client.get("/found"), "auth"), "Bearer t")
    let away = client.get("/away")
    assert_eq(away.url, "http://localhost:\{other}/echo")
    assert_eq(echoed(away, "auth"), "")
  })
}

///|
async test "fetch: a slow answer is a Timeout, and checked raises for 4xx and 5xx" {
  with_servers((port, _, _) => {
    let client = @moonfetch.Client::new(base_url="http://127.0.0.1:\{port}")
    defer client.close()
    assert_true(
      refusal(() => client.get("/slow", timeout=200))
      is @moonfetch.Timeout(limit=200),
    )
    let missing = client.get("/status/404")
    assert_false(missing.is_success())
    let e = try missing.checked() catch {
      e => e
    } noraise {
      _ => fail("expected a refusal")
    }
    assert_true(e is @moonfetch.Status(status=404, ..))
    assert_eq(client.get("/status/204").checked().status, 204)
  })
}

///|
async test "fetch: a connection the server closes is not kept, and HEAD reads no body" {
  with_servers(secure=true, (port, _, accepted) => {
    let client = @moonfetch.Client::new(tls=trusting(), http2=false)
    defer client.close()
    assert_eq(client.get("https://localhost:\{port}/close").text(), "closing")
    assert_eq(client.get("https://localhost:\{port}/close").text(), "closing")
    assert_eq(accepted.val, 2)
    for http2 in [false, true] {
      let c = @moonfetch.Client::new(tls=trusting(), http2~)
      defer c.close()
      let r = c.head("https://localhost:\{port}/")
      assert_eq(r.status, 200)
      assert_eq(r.body, b"")
    }
  })
}

///|
async test "fetch: a kept connection the server dropped is retried on a new one" {
  with_servers((port, _, accepted) => {
    let client = @moonfetch.Client::new(base_url="http://127.0.0.1:\{port}")
    defer client.close()
    assert_eq(client.get("/drop").text(), "dropped after")
    // Give the close time to arrive, so the kept connection is dead when it is reused.
    @async.sleep(100)
    assert_eq(client.get("/").text(), "hello")
    assert_eq(accepted.val, 2)
  })
}

///|
async test "fetch: a body cut short raises rather than waiting or passing for whole" {
  with_servers((port, _, _) => {
    let client = @moonfetch.Client::new(base_url="http://127.0.0.1:\{port}")
    defer client.close()
    let cut = try client.post("/truncate") catch {
      _ => true
    } noraise {
      _ => false
    }
    assert_true(cut)
    assert_eq(client.get("/").text(), "hello")
  })
}

///|
async test "fetch: after an HTTP/2 GOAWAY the next request opens a new connection" {
  with_servers(secure=true, (port, _, accepted) => {
    let client = @moonfetch.Client::new(tls=trusting())
    defer client.close()
    assert_eq(client.get("https://localhost:\{port}/goaway").text(), "going")
    @async.sleep(100)
    assert_eq(client.get("https://localhost:\{port}/").text(), "hello")
    assert_eq(accepted.val, 2)
  })
}

///|
async test "fetch: two megabytes up and down, over both versions" {
  let size = 2 << 20
  let data = Bytes::makei(size, i => (i * 13 % 256).to_byte())
  with_servers(secure=true, (port, _, _) => {
    for http2 in [false, true] {
      let client = @moonfetch.Client::new(
        base_url="https://localhost:\{port}",
        tls=trusting(),
        http2~,
        timeout=Some(50000),
      )
      defer client.close()
      assert_eq(client.post("/upload", body=Bytes(data)).text(), digest(data))
      let down = client.get("/big", query=[("n", size.to_string())])
      assert_eq(down.body.length(), size)
      assert_true(down.body == pattern(size))
    }
  })
}

///|
async test "fetch: a one-off request, and URLs that are not http" {
  with_servers((port, _, _) => {
    let r = @moonfetch.get("http://127.0.0.1:\{port}/echo", query=[
      ("one", "off"),
    ])
    assert_eq(echoed(r, "query"), "one=off")
    assert_eq(echoed(r, "agent"), "moonfetch")
    assert_true(
      refusal(() => @moonfetch.get("ftp://127.0.0.1/")) is @moonfetch.Url(_),
    )
    assert_true(refusal(() => @moonfetch.get("/relative")) is @moonfetch.Url(_))
  })
}

///|
async test "fetch: gzip and deflate come back decoded, both deflate forms, over both versions" {
  with_servers(secure=true, (port, _, _) => {
    for http2 in [false, true] {
      let client = @moonfetch.Client::new(
        base_url="https://localhost:\{port}",
        tls=trusting(),
        http2~,
      )
      defer client.close()
      let g = client.get("/gzip")
      assert_eq(g.text(), "compressed hello")
      assert_eq(g.header("content-encoding"), None)
      assert_eq(client.get("/deflate").text(), "zlib hello")
      assert_eq(client.get("/raw-deflate").text(), "bare hello")
      let br = client.get("/brotli")
      assert_eq(br.text(), "not br")
      assert_eq(br.header("content-encoding"), Some("br"))
      let raw = client.get("/gzip", headers=[("accept-encoding", "gzip")])
      assert_eq(raw.header("content-encoding"), Some("gzip"))
      assert_true(raw.body != b"compressed hello")
    }
    let plain = @moonfetch.Client::new(tls=trusting(), compression=false)
    defer plain.close()
    let r = plain.get("https://localhost:\{port}/gzip")
    assert_eq(r.header("content-encoding"), Some("gzip"))
  })
}

///|
async test "fetch: a chunked body, a body to the close, and 103 Early Hints before the answer" {
  with_servers((port, _, accepted) => {
    let client = @moonfetch.Client::new(base_url="http://127.0.0.1:\{port}")
    defer client.close()
    assert_eq(client.get("/chunked").text(), "in pieces")
    assert_eq(client.get("/hints").text(), "after hints")
    assert_eq(accepted.val, 1)
    assert_eq(client.get("/eof").text(), "to the close")
    assert_eq(client.get("/").text(), "hello")
    assert_eq(accepted.val, 2)
  })
}
