// The cookie jar: RFC 6265bis storage, domain and path matching, expiry.

///|
fn at(text : String) -> @moonurl.Url raise {
  @moonurl.Url::decode(text) catch {
    _ => fail("bad URL: \{text}")
  }
}

///|
async test "jar: a cookie goes where its domain, path and secure flags say" {
  let jar = @moonfetch.Jar::new()
  let set = at("https://api.example.com/v1/users")
  jar.store(set, [
    "id=42; Path=/v1", "wide=1; Domain=example.com; Path=/", "secure=2; Path=/; Secure",
    "elsewhere=3; Domain=other.example; Path=/", "hopeless=4; Domain=com; Path=/",
  ])
  assert_eq(jar.size(), 3)
  assert_eq(
    jar.cookies(at("https://api.example.com/v1/me")),
    "id=42; wide=1; secure=2",
  )
  // Outside `/v1` the path-scoped cookie is not sent.
  assert_eq(jar.cookies(at("https://api.example.com/v2")), "wide=1; secure=2")
  // A secure cookie does not cross to http.
  assert_eq(jar.cookies(at("http://api.example.com/v1/")), "id=42; wide=1")
  // A cookie without a domain is the host's alone.
  assert_eq(jar.cookies(at("https://sub.api.example.com/v1/")), "wide=1")
}

///|
async test "jar: a deletion takes away what it names, and an old expiry is not kept" {
  let jar = @moonfetch.Jar::new()
  let url = at("https://example.com/a/b")
  jar.store(url, [
    "keep=1; Path=/", "drop=2; Path=/", "old=3; Expires=Thu, 01 Jan 1970 00:00:00 GMT",
  ])
  assert_eq(jar.cookies(url), "keep=1; drop=2")
  jar.store(url, ["drop=2; Path=/; Max-Age=0"])
  assert_eq(jar.cookies(url), "keep=1")
  assert_eq(jar.size(), 1)
}

///|
async test "jar: a path without Path defaults to the request's own directory" {
  let jar = @moonfetch.Jar::new()
  jar.store(at("https://example.com/a/b/c?q=1"), ["x=1"])
  assert_eq(jar.cookies(at("https://example.com/a/b/other")), "x=1")
  assert_eq(jar.cookies(at("https://example.com/a/other")), "")
  // The root is the root.
  jar.store(at("https://example.com/"), ["root=1"])
  assert_eq(jar.cookies(at("https://example.com/deep/er")), "root=1")
}

///|
async test "jar: the same triple replaces in place, and the longer path goes first" {
  let jar = @moonfetch.Jar::new()
  let url = at("https://example.com/")
  jar.store(url, ["a=1; Path=/", "b=2; Path=/deep", "c=3; Path=/deep/x"])
  assert_eq(jar.size(), 3)
  assert_eq(jar.cookies(at("https://example.com/deep/x/y")), "c=3; b=2; a=1")
  jar.store(url, ["a=7; Path=/"])
  assert_eq(jar.size(), 3)
  assert_eq(jar.cookies(at("https://example.com/deep/x/y")), "c=3; b=2; a=7")
}

///|
async test "jar: the cookie prefixes are enforced" {
  let jar = @moonfetch.Jar::new()
  let url = at("https://example.com/x")
  jar.store(url, [
    "__Host-good=1; Path=/; Secure", "__Host-bad=1; Path=/", "__Host-bad2=1; Path=/a; Secure",
    "__Secure-good=1; Path=/; Secure", "__Secure-bad=1; Path=/",
  ])
  assert_eq(jar.cookies(url), "__Host-good=1; __Secure-good=1")
}

///|
async test "jar: a client carries cookies between requests, and only to the right paths" {
  with_servers((port, _, _) => {
    let jar = @moonfetch.Jar::new()
    let client = @moonfetch.Client::new(
      base_url="http://127.0.0.1:\{port}",
      jar~,
      timeout=Some(60000),
    )
    defer client.close()
    assert_eq(client.get("/cookie/set").text(), "set")
    // The longer path sorts first (RFC 6265bis §5.4).
    assert_eq(echoed(client.get("/cookie/read"), "cookie"), "deep=2; plain=1")
    // `/` does not match the cookie scoped to `/cookie`.
    assert_eq(echoed(client.get("/echo"), "cookie"), "plain=1")
    // The secure one stayed away from http, and the deleted one was never stored.
    assert_false(echoed(client.get("/echo"), "cookie").contains("secure=3"))
    assert_false(echoed(client.get("/echo"), "cookie").contains("gone=4"))
    assert_eq(jar.size(), 3)
  })
}
