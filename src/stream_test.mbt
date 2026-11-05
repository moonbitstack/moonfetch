// Streamed responses: pieces as they come, trailers, and the body bound.

///|
fn client_base(version : String, port : Int32, other : Int32) -> String {
  if version == "HTTP/2" {
    "https://127.0.0.1:\{port}"
  } else {
    "http://127.0.0.1:\{other}"
  }
}

///|
/// The first data piece of a stream.
async fn first_data(stream : @moonfetch.Stream) -> String {
  match stream.next() {
    Some(Data(piece)) => @utf8.decode_lossy(piece[:])
    Some(End(_)) => fail("the body ended before any data")
    None => fail("no body")
  }
}

///|
async test "stream: pieces arrive as they are sent, over both versions" {
  with_servers(secure=true, (port, other, accepted) => {
    let cases = [
      (
        @moonfetch.Client::new(
          base_url="http://127.0.0.1:\{other}",
          timeout=Some(60000),
        ),
        "HTTP/1.1",
      ),
      (
        @moonfetch.Client::new(
          base_url="https://localhost:\{port}",
          tls=trusting(),
          timeout=Some(60000),
        ),
        "HTTP/2",
      ),
    ]
    for case in cases {
      let (client, version) = case
      defer client.close()
      let stream = client.stream(@method.Method::Get, "/steps")
      assert_eq(stream.status(), 200)
      assert_eq(stream.version(), version)
      assert_eq(stream.header("content-type"), Some("text/plain"))
      // The first piece is here before the rest has been sent: that is what streaming is for.
      assert_eq(first_data(stream), "one-")
      assert_eq(stream.text(), "two-three")
      assert_true(stream.next() is None)
      // The connection is kept: an HTTP/2 one serves the next request, HTTP/1.1 is pooled.
      assert_eq(client.get("/").text(), "hello")
    }
    // The HTTP/2 client made one connection; the HTTP/1.1 one went to the other server.
    assert_eq(accepted.val, 1)
  })
}

///|
async test "stream: trailers come with the end, and a close abandons the rest" {
  with_servers((port, _, _) => {
    let client = @moonfetch.Client::new(
      base_url="http://127.0.0.1:\{port}",
      timeout=Some(60000),
    )
    defer client.close()
    let stream = client.stream(@method.Method::Get, "/trailers")
    let mut body = ""
    let mut trailers = []
    for ;; {
      match stream.next() {
        Some(Data(piece)) => body = body + @utf8.decode_lossy(piece[:])
        Some(End(fields)) => {
          trailers = fields
          break
        }
        None => break
      }
    }
    assert_eq(body, "with trailers")
    assert_eq(trailers.length(), 2)
    assert_true(trailers.iter().any(f => f.0 == "x-count" && f.1 == "13"))
    let early = client.stream(@method.Method::Get, "/steps")
    assert_eq(first_data(early), "one-")
    early.close()
    assert_eq(client.get("/").text(), "hello")
  })
}

///|
async test "stream: a body over the bound is refused while it is read" {
  with_servers((port, _, _) => {
    let client = @moonfetch.Client::new(
      base_url="http://127.0.0.1:\{port}",
      limits=@moonfetch.Limits::new(body=1000),
      timeout=Some(60000),
    )
    defer client.close()
    let over = try client.get("/big", query=[("n", "5000")]) catch {
      e => e
    } noraise {
      _ => fail("a 5000-octet body passed a 1000-octet bound")
    }
    assert_true(over is @moonfetch.Exceeded(limit=1000, ..))
    // The bound applies to a stream's own whole-body read as well, and can be raised.
    let stream = client.stream(@method.Method::Get, "/big", query=[
      ("n", "5000"),
    ])
    let refused = try stream.bytes() catch {
      e => e
    } noraise {
      _ => fail("a 5000-octet body passed the stream bound")
    }
    assert_true(refused is @moonfetch.Exceeded(limit=1000, ..))
    let again = client.stream(@method.Method::Get, "/big", query=[("n", "5000")])
    assert_eq(again.bytes(limit=10000).length(), 5000)
    assert_eq(client.get("/").text(), "hello")
  })
}

///|
async test "stream: the bound counts the whole body, not one piece" {
  with_servers(secure=true, (port, other, _) => {
    let cases = [
      (
        @moonfetch.Client::new(
          base_url="http://127.0.0.1:\{other}",
          timeout=Some(60000),
        ),
        "HTTP/1.1",
      ),
      (
        @moonfetch.Client::new(
          base_url="https://127.0.0.1:\{port}",
          tls=trusting(),
          timeout=Some(60000),
        ),
        "HTTP/2",
      ),
    ]
    for case in cases {
      let (client, version) = case
      defer client.close()
      // The body arrives in pieces of four octets each; 13 octets in all, against a bound of 6.
      let stream = client.stream(@method.Method::Get, "/steps")
      let refused = try stream.bytes(limit=6) catch {
        e => e
      } noraise {
        _ => fail("a 13-octet body passed a 6-octet bound over \{version}")
      }
      assert_true(refused is @moonfetch.Exceeded(limit=6, got=8))
      // The same bound on the buffered path, where the pieces are added up by the transport.
      let buffered = @moonfetch.Client::new(
        base_url=client_base(version, port, other),
        tls=trusting(),
        limits=@moonfetch.Limits::new(body=6),
        timeout=Some(60000),
      )
      defer buffered.close()
      let over = try buffered.get("/steps") catch {
        e => e
      } noraise {
        _ =>
          fail(
            "a 13-octet body passed a 6-octet bound when buffered over \{version}",
          )
      }
      assert_true(over is @moonfetch.Exceeded(limit=6, ..))
    }
  })
}

///|
async test "stream: an HTTP/2 stream is reset without losing the connection" {
  with_servers(secure=true, (port, _, accepted) => {
    let client = @moonfetch.Client::new(
      base_url="https://localhost:\{port}",
      tls=trusting(),
      timeout=Some(60000),
    )
    defer client.close()
    for _ in 0..<3 {
      let stream = client.stream(@method.Method::Get, "/steps")
      assert_eq(first_data(stream), "one-")
      stream.close()
    }
    assert_eq(client.get("/").text(), "hello")
    assert_eq(accepted.val, 1)
  })
}
