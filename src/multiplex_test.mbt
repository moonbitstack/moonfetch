// Many requests on one HTTP/2 connection, and HTTP/2 with prior knowledge in the clear.

///|
/// Answer one request on `stream`; the write lock keeps frames of different streams apart.
async fn answer_h2(
  conn : @tcp.Conn,
  write : @async.Mutex,
  wire : @http2.Conn,
  stream : Int32,
  path : String,
) -> Unit {
  if path.has_prefix("/slow") {
    @async.sleep(150)
  }
  write.acquire()
  defer write.release()
  let head = [
    @header.Header::of(":status", "200"),
    @header.Header::of("content-type", "text/plain"),
  ]
  wire.headers(stream, head)
  wire.data(stream, b"ok"[:], end=true)
  conn.write(wire.take())
}

///|
/// An HTTP/2 server that answers each stream in its own task, so the responses really do
/// overlap.
async fn serve_h2_concurrent(conn : @tcp.Conn, seen : Seen) -> Unit {
  @async.with_task_group(g => {
    let wire = @http2.Conn::new(Server)
    let write = @async.Mutex()
    let bodies : Map[Int32, Buffer] = Map([])
    let targets : Map[Int32, String] = Map([])
    for ;; {
      match wire.next() {
        NeedData =>
          match conn.read_some(max_len=16384) {
            Some(data) => wire.receive(data[:])
            None => return
          }
        Request(stream~, fields~) => {
          bodies[stream] = Buffer()
          targets[stream] = field(names(fields), ":path")
          seen.mark()
        }
        Data(stream~, data~) => {
          if bodies.get(stream) is Some(buffer) {
            buffer.write_bytes(data)
          }
          wire.acknowledge(stream, data.length())
        }
        End(stream~) => {
          bodies.remove(stream)
          let path = match targets.get(stream) {
            Some(path) => path
            None => "/"
          }
          targets.remove(stream)
          g.spawn_bg(() => answer_h2(conn, write, wire, stream, path))
        }
        Closed | GoAway(..) => return
        _ => ()
      }
    }
  })
}

///|
/// Run `body` against a TLS HTTP/2 server that answers concurrently.
async fn with_concurrent(body : async (Int32, Ref[Int32]) -> Unit) -> Unit {
  @async.with_timeout(180000, () => {
    @async.with_task_group(g => {
      let accepted = Ref(0)
      let listener = @tcp.listen(port=0, tls=server_tls())
      let task = g.spawn(() => {
        listener.serve((conn, _) => {
          let seen = { used: false, accepted, }
          serve_h2_concurrent(conn, seen)
        })
      })
      body(listener.addr().port(), accepted)
      task.cancel()
    })
  })
}

///|
async test "multiplex: a hundred requests share one connection and overlap" {
  with_concurrent((port, accepted) => {
    let client = @moonfetch.Client::new(
      base_url="https://127.0.0.1:\{port}",
      tls=trusting(),
      timeout=Some(60000),
    )
    defer client.close()
    // A first request pays the dial and the handshake, which the measurement is not about.
    assert_eq(client.get("/").status, 200)
    let answered = Ref(0)
    let start = @bench.monotonic_clock_start()
    @async.with_task_group(g => {
      for i in 0..<100 {
        g.spawn_bg(() => {
          let path = if i % 5 == 0 { "/slow" } else { "/" }
          let response = client.get(path)
          assert_eq(response.status, 200)
          assert_eq(response.text(), "ok")
          answered.val += 1
        })
      }
    })
    let elapsed = @bench.monotonic_clock_end(start) / 1000
    assert_eq(answered.val, 100)
    // One connection for all of them.
    assert_eq(accepted.val, 1)
    // Serially the twenty 150 ms answers alone would take three seconds; underneath, the
    // transport pays a Nagle delay for the small writes, which this bound allows for.
    assert_true(elapsed < 2000)
  })
}

///|
async test "multiplex: a stream reset by the client does not trouble the others" {
  with_concurrent((port, accepted) => {
    let client = @moonfetch.Client::new(
      base_url="https://localhost:\{port}",
      tls=trusting(),
      timeout=Some(60000),
    )
    defer client.close()
    let aborted = client.stream(@method.Method::Get, "/slow")
    aborted.close()
    assert_eq(client.get("/").text(), "ok")
    assert_eq(accepted.val, 1)
  })
}

///|
async test "h2c: HTTP/2 in the clear, by prior knowledge" {
  with_servers((_, other, _) => {
    let plain = @moonfetch.Client::new(
      base_url="http://127.0.0.1:\{other}",
      timeout=Some(60000),
    )
    defer plain.close()
    assert_eq(plain.get("/").version, "HTTP/1.1")
    let h2c = @moonfetch.Client::new(
      base_url="http://127.0.0.1:\{other}",
      h2c=true,
      timeout=Some(60000),
    )
    defer h2c.close()
    let response = h2c.get("/echo")
    assert_eq(response.version, "HTTP/2")
    assert_eq(echoed(response, "version"), "HTTP/2")
    assert_eq(h2c.get("/").text(), "hello")
  })
}
