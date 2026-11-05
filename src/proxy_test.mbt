// Proxies: an HTTP proxy for cleartext (absolute form) and for TLS (CONNECT), and SOCKS5.

///|
/// Copy every octet one way until the source closes.
async fn relay(from : @tcp.Conn, to : @tcp.Conn) -> Unit {
  for ;; {
    match from.read_some(max_len=16384) {
      Some(data) => to.write(data)
      None => return
    }
  }
}

///|
/// Let two connections talk until one of them is done.
async fn splice(a : @tcp.Conn, b : @tcp.Conn) -> Unit {
  @async.with_task_group(g => {
    g.spawn_bg(() => relay(a, b))
    relay(b, a) catch {
      _ => ()
    }
  })
  a.close()
  b.close()
}

///|
/// What the test proxy remembers: whether `CONNECT` was used, whether it saw a username.
priv struct ProxyLog {
  mut connect : Bool
  mut absolute : Bool
  mut authorized : Bool
}

///|
/// An HTTP proxy: `CONNECT host:port` tunnels, and an absolute request target is forwarded.
async fn serve_http_proxy(listener : @tcp.Listener, log : ProxyLog) -> Unit {
  listener.serve((conn, _) => {
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
    let head = @utf8.decode_lossy(held.to_bytes()[:])
    let first = match head.split_once("\r\n") {
      Some((line, _)) => line.to_owned()
      None => return
    }
    let parts = first.split(" ").to_array()
    guard parts.length() >= 3 else { return }
    let (verb, target) = (parts[0].to_owned(), parts[1].to_owned())
    log.authorized = head.to_lower().contains("proxy-authorization: basic ")
    if verb == "CONNECT" {
      log.connect = true
      let (host, port) = match target.split_once(":") {
        Some((host, port)) =>
          (host.to_owned(), @string.parse_int(port) catch { _ => 0 })
        None => return
      }
      let upstream = @tcp.dial(host, port~)
      conn.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
      splice(conn, upstream)
      return
    }
    // Absolute form: `GET http://host:port/path HTTP/1.1`.
    let url = @moonurl.Url::decode(target) catch { _ => return }
    guard url.host is Some(host) && url.port is Some(port) else { return }
    log.absolute = true
    let upstream = @tcp.dial(host, port~)
    let path = if url.path == "" { "/" } else { url.path }
    let rest = match url.query {
      Some(q) => "\{path}?\{q}"
      None => path
    }
    let rest_of_head = match head.split_once("\r\n") {
      Some((_, rest)) => rest.to_owned()
      None => ""
    }
    let rewritten = "\{verb} \{rest} HTTP/1.1\r\n" + rest_of_head
    upstream.write(@utf8.encode(rewritten))
    splice(conn, upstream)
  })
}

///|
/// A SOCKS5 proxy (RFC 1928) with no authentication.
async fn serve_socks(listener : @tcp.Listener, log : ProxyLog) -> Unit {
  listener.serve((conn, _) => {
    let greeting = conn.read_exactly(2)
    guard greeting[0] == b'\x05' else { return }
    let methods = conn.read_exactly(greeting[1].to_int())
    let mut offered = false
    for choice in methods {
      if choice == b'\x00' {
        offered = true
      }
    }
    guard offered else {
      conn.write(b"\x05\xff")
      return
    }
    conn.write(b"\x05\x00")
    let ask = conn.read_exactly(4)
    guard ask[0] == b'\x05' && ask[1] == b'\x01' && ask[3] == b'\x03' else {
      return
    }
    log.connect = true
    let length = conn.read_exactly(1)
    let host = @utf8.decode_lossy(conn.read_exactly(length[0].to_int())[:])
    let port = conn.read_exactly(2)
    let at = port[0].to_int() * 256 + port[1].to_int()
    let upstream = @tcp.dial(host, port=at) catch { _ => return }
    conn.write(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
    splice(conn, upstream)
  })
}

///|
/// A listeners pair and the log, torn down after `body`.
async fn with_proxies(body : async (ProxyLog, Int32, Int32) -> Unit) -> Unit {
  @async.with_timeout(180000, () => {
    @async.with_task_group(g => {
      let log = { connect: false, absolute: false, authorized: false, }
      let http = @tcp.listen(port=0)
      let socks = @tcp.listen(port=0)
      let a = g.spawn(() => serve_http_proxy(http, log))
      let b = g.spawn(() => serve_socks(socks, log))
      body(log, http.addr().port(), socks.addr().port())
      a.cancel()
      b.cancel()
    })
  })
}

///|
async test "proxy: a cleartext request goes in absolute form, a TLS one through CONNECT" {
  with_servers(secure=true, (port, other, _) => {
    with_proxies((log, proxy, _) => {
      let client = @moonfetch.Client::new(
        proxy=@moonfetch.Proxy::parse("http://127.0.0.1:\{proxy}"),
        timeout=Some(60000),
      )
      defer client.close()
      assert_eq(client.get("http://127.0.0.1:\{other}/").text(), "hello")
      assert_true(log.absolute)
      assert_false(log.connect)
      let secure = @moonfetch.Client::new(
        proxy=@moonfetch.Proxy::parse("http://127.0.0.1:\{proxy}"),
        tls=trusting(),
        timeout=Some(60000),
      )
      defer secure.close()
      assert_eq(secure.get("https://localhost:\{port}/echo").version, "HTTP/2")
      assert_true(log.connect)
    })
  })
}

///|
async test "proxy: SOCKS5 carries cleartext and TLS alike" {
  with_servers(secure=true, (port, other, _) => {
    with_proxies((log, _, socks) => {
      let client = @moonfetch.Client::new(
        proxy=@moonfetch.Proxy::parse("socks5://127.0.0.1:\{socks}"),
        timeout=Some(60000),
      )
      defer client.close()
      assert_eq(client.get("http://127.0.0.1:\{other}/").text(), "hello")
      assert_true(log.connect)
      let secure = @moonfetch.Client::new(
        proxy=@moonfetch.Proxy::parse("socks5h://127.0.0.1:\{socks}"),
        tls=trusting(),
        timeout=Some(60000),
      )
      defer secure.close()
      assert_eq(secure.get("https://localhost:\{port}/").text(), "hello")
    })
  })
}

///|
async test "proxy: a username and password reach the proxy" {
  with_servers(secure=true, (port, _, _) => {
    with_proxies((log, proxy, _) => {
      let client = @moonfetch.Client::new(
        proxy=@moonfetch.Proxy::parse("http://moon:secret@127.0.0.1:\{proxy}"),
        tls=trusting(),
        timeout=Some(60000),
      )
      defer client.close()
      assert_eq(client.get("https://localhost:\{port}/").text(), "hello")
      assert_true(log.authorized)
    })
  })
}

///|
test "proxy: URLs parse into the schemes and defaults that matter" {
  let plain = @moonfetch.Proxy::parse("http://proxy.example")
  assert_eq(plain.scheme, "http")
  assert_eq(plain.host, "proxy.example")
  assert_eq(plain.port, 80)
  assert_eq(plain.user, None)
  let socks = @moonfetch.Proxy::parse("socks5://moon:pw@127.0.0.1:1080")
  assert_eq(socks.port, 1080)
  assert_eq(socks.user, Some("moon"))
  assert_eq(socks.password, Some("pw"))
  assert_true(
    try @moonfetch.Proxy::parse("ftp://proxy") catch {
      _ => true
    } noraise {
      _ => false
    },
  )
}
