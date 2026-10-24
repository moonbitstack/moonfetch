// Concurrent connections, native only: the wasm host's socket table and listen queue are small
// enough that a burst is refused. A hundred at once stays under macOS's default listen queue of
// 128, past which it refuses rather than queueing.

///|
async test "fetch: a hundred requests at once on one client, over both versions" {
  with_servers(secure=true, (port, _, accepted) => {
    for http2 in [true, false] {
      let client = @moonfetch.Client::new(
        base_url="https://localhost:\{port}",
        tls=trusting(),
        http2~,
        timeout=Some(120000),
      )
      defer client.close()
      let ok = Ref(0)
      @async.with_task_group(g => {
        for i in 0..<100 {
          g.spawn_bg(() => {
            let r = client.get("/echo", query=[("i", i.to_string())])
            if echoed(r, "query") == "i=\{i}" {
              ok.val += 1
            }
          })
        }
      })
      assert_eq(ok.val, 100)
    }
    // HTTP/2 multiplexes onto one connection; HTTP/1.1 opens one per request in flight.
    assert_true(accepted.val > 2)
  })
}

///|
async test "fetch: ten requests at once on one client, over both versions" {
  with_servers(secure=true, (port, _, accepted) => {
    for http2 in [true, false] {
      let client = @moonfetch.Client::new(
        base_url="https://localhost:\{port}",
        tls=trusting(),
        http2~,
        timeout=Some(50000),
      )
      defer client.close()
      let ok = Ref(0)
      @async.with_task_group(g => {
        for i in 0..<10 {
          g.spawn_bg(() => {
            let r = client.get("/echo", query=[("i", i.to_string())])
            if echoed(r, "query") == "i=\{i}" {
              ok.val += 1
            }
          })
        }
      })
      assert_eq(ok.val, 10)
    }
    // HTTP/2 multiplexes onto one connection; HTTP/1.1 opens one per request in flight.
    assert_true(accepted.val > 2)
  })
}
