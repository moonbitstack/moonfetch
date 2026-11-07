// The cases the transport tests run against a server of this repository's are run here against
// one written in another language on purpose: Node's `http`, started by `scripts/js_serve.mjs`.
// What each case asserts is what the same request means on either host; a version string, a kept
// connection and a redirect chain are the host's and are asserted where the host exposes them.

///|
/// The two origins `scripts/js_serve.mjs` prints, or nothing when no peer was named: a run
/// without one has nobody to talk to, and the live cases are not this run's.
fn live() -> (String, String)? {
  match
    (
      @env.get_env_var("MOONFETCH_LIVE"),
      @env.get_env_var("MOONFETCH_LIVE_OTHER"),
    ) {
    (Some(one), Some(two)) => Some((one, two))
    _ => None
  }
}

///|
fn answered(response : @moonfetch.Response, key : String) -> String raise {
  guard response.json() is Object(members) &&
    members.get(key) is Some(String(value)) else {
    fail("no \{key} in \{response.text()}")
  }
  value
}

///|
async fn refused(f : async () -> @moonfetch.Response) -> Error {
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
fn pattern(n : Int32) -> Bytes {
  Bytes::makei(n, i => (i % 251).to_byte())
}

///|
async test "js: a GET in the clear, and the response describes itself" {
  let (base, _) = match live() {
    Some(pair) => pair
    None => return
  }
  let client = @moonfetch.Client::new(timeout=Some(60000))
  for _ in 0..<3 {
    let r = client.get("\{base}/")
    assert_eq(r.status, 200)
    assert_eq(r.text(), "hello")
    assert_eq(r.header("Content-Type"), Some("text/plain"))
    assert_eq(r.url, "\{base}/")
  }
}

///|
async test "js: each body goes with its content type" {
  guard live() is Some(_) else { return }
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
  let client = @moonfetch.Client::new(
    base_url=match live() {
      Some(pair) => pair.0
      None => return
    },
    timeout=Some(60000),
  )
  for case in cases {
    let (body, wire, kind) = case
    let r = client.post("/echo", body~)
    assert_eq(answered(r, "body"), wire)
    assert_eq(answered(r, "type"), kind)
  }
  let named = client.post("/echo", body=Text("{}"), headers=[
    ("Content-Type", "application/merge-patch+json"),
  ])
  assert_eq(answered(named, "type"), "application/merge-patch+json")
  assert_eq(answered(client.put("/echo"), "method"), "PUT")
  assert_eq(answered(client.patch("/echo"), "method"), "PATCH")
  assert_eq(answered(client.delete("/echo"), "method"), "DELETE")
  assert_eq(client.options("/").status, 200)
}

///|
async test "js: a multipart body reaches the server as parts" {
  let client = @moonfetch.Client::new(
    base_url=match live() {
      Some(pair) => pair.0
      None => return
    },
    timeout=Some(60000),
  )
  let r = client.post(
    "/multipart",
    body=Multipart([
      @moonfetch.Part::field("owner", "moon"),
      @moonfetch.Part::file(
        "doc",
        "notes.txt",
        b"hello file",
        content_type="text/plain",
      ),
    ]),
  )
  guard r.json() is Array(parts) && parts.length() == 2 else {
    fail("expected two parts, got \{r.text()}")
  }
  guard parts[1] is Object(second) else { fail("not an object") }
  let of = (key : String) => {
    match second.get(key) {
      Some(String(value)) => value
      _ => fail("no \{key}")
    }
  }
  assert_eq(of("name"), "doc")
  assert_eq(of("filename"), "notes.txt")
  assert_eq(of("body"), "hello file")
}

///|
async test "js: base URL, query and headers combine as they do on the other host" {
  let (base, _) = match live() {
    Some(pair) => pair
    None => return
  }
  let client = @moonfetch.Client::new(
    base_url="\{base}/redirect",
    headers=[("x-extra", "client")],
    timeout=Some(60000),
  )
  assert_eq(client.get("/0").text(), "landed")
  let r = client.get("\{base}/echo?x=1", query=[("y", "2 3")])
  assert_eq(answered(r, "query"), "x=1&y=2+3")
  let replaced = client.get("\{base}/echo", headers=[("X-Extra", "call")])
  assert_eq(answered(replaced, "extra"), "call")
}

///|
async test "js: redirects are followed, capped, not followed at all, and a loop ends" {
  let (base, _) = match live() {
    Some(pair) => pair
    None => return
  }
  let client = @moonfetch.Client::new(base_url=base, timeout=Some(60000))
  let r = client.get("/redirect/3")
  assert_eq(r.text(), "landed")
  assert_eq(r.url, "\{base}/redirect/0")
  assert_true(
    refused(() => client.get("/redirect/3", redirects=2))
    is @moonfetch.Redirects(limit=2),
  )
  assert_eq(client.get("/redirect/3", redirects=0).status, 302)
  assert_true(
    refused(() => client.get("/loop")) is @moonfetch.Redirects(limit=10),
  )
}

///|
async test "js: a 303 and a POST's 302 turn into GET; a 307 keeps the method and body" {
  let client = @moonfetch.Client::new(
    base_url=match live() {
      Some(pair) => pair.0
      None => return
    },
    timeout=Some(60000),
  )
  let seen = client.post("/see-other", body=Text("x"))
  assert_eq(answered(seen, "method"), "GET")
  assert_eq(answered(seen, "body"), "")
  assert_eq(answered(client.post("/found", body=Text("x")), "method"), "GET")
  let kept = client.post("/keep", body=Text("kept"))
  assert_eq(answered(kept, "method"), "POST")
  assert_eq(answered(kept, "body"), "kept")
}

///|
async test "js: credentials stay with their origin across a redirect" {
  let (base, other) = match live() {
    Some(pair) => pair
    None => return
  }
  let client = @moonfetch.Client::new(
    base_url=base,
    headers=[("authorization", "Bearer t")],
    timeout=Some(60000),
  )
  assert_eq(answered(client.get("/found"), "auth"), "Bearer t")
  let away = client.get("/away")
  assert_true(away.url.has_prefix(other))
  assert_eq(answered(away, "auth"), "")
}

///|
async test "js: a slow answer is a Timeout, and checked raises for 4xx" {
  let client = @moonfetch.Client::new(
    base_url=match live() {
      Some(pair) => pair.0
      None => return
    },
    timeout=Some(60000),
  )
  assert_true(
    refused(() => client.get("/slow", timeout=200))
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
}

///|
async test "js: HEAD reads no body" {
  let client = @moonfetch.Client::new(
    base_url=match live() {
      Some(pair) => pair.0
      None => return
    },
    timeout=Some(60000),
  )
  let r = client.head("/")
  assert_eq(r.status, 200)
  assert_eq(r.body, b"")
}

///|
async test "js: two megabytes up and down" {
  let size = 2 << 20
  let data = Bytes::makei(size, i => (i * 13 % 256).to_byte())
  let client = @moonfetch.Client::new(
    base_url=match live() {
      Some(pair) => pair.0
      None => return
    },
    timeout=Some(50000),
  )
  assert_eq(client.post("/upload", body=Bytes(data)).text(), digest(data))
  let down = client.get("/big", query=[("n", size.to_string())])
  assert_eq(down.body.length(), size)
  assert_true(down.body == pattern(size))
}

///|
async test "js: gzip and deflate come back decoded, and the coding leaves the headers" {
  let client = @moonfetch.Client::new(
    base_url=match live() {
      Some(pair) => pair.0
      None => return
    },
    timeout=Some(60000),
  )
  let g = client.get("/gzip")
  assert_eq(g.text(), "compressed hello")
  assert_eq(g.header("content-encoding"), None)
  assert_eq(client.get("/deflate").text(), "zlib hello")
  assert_eq(client.get("/raw-deflate").text(), "bare hello")
}

///|
async test "js: a chunked body and a body to the close" {
  let client = @moonfetch.Client::new(
    base_url=match live() {
      Some(pair) => pair.0
      None => return
    },
    timeout=Some(60000),
  )
  assert_eq(client.get("/chunked").text(), "in pieces")
  assert_eq(client.get("/eof").text(), "to the close")
}

///|
async test "js: a one-off request, and URLs that are not http" {
  let (base, _) = match live() {
    Some(pair) => pair
    None => return
  }
  let r = @moonfetch.get("\{base}/echo", query=[("one", "off")], timeout=60000)
  assert_eq(answered(r, "query"), "one=off")
  assert_true(
    refused(() => @moonfetch.get("ftp://127.0.0.1/")) is @moonfetch.Url(_),
  )
  assert_true(refused(() => @moonfetch.get("/relative")) is @moonfetch.Url(_))
}

///|
async test "js: a stream hands over the pieces as they arrive" {
  let client = @moonfetch.Client::new(
    base_url=match live() {
      Some(pair) => pair.0
      None => return
    },
    timeout=Some(60000),
  )
  let stream = client.stream(@method.Method::Get, "/steps")
  assert_eq(stream.status(), 200)
  let mut pieces = 0
  let text = StringBuilder()
  while stream.next() is Some(piece) {
    match piece {
      Data(bytes) => {
        pieces += 1
        text.write_string(@utf8.decode_lossy(bytes[:]))
      }
      End(_) => break
    }
  }
  assert_eq(text.to_string(), "one-two-three")
  assert_true(pieces > 1)
}

///|
async test "js: a body produced while the request goes out" {
  let client = @moonfetch.Client::new(
    base_url=match live() {
      Some(pair) => pair.0
      None => return
    },
    timeout=Some(60000),
  )
  let data = Bytes::makei(9000, i => (i * 7 % 256).to_byte())
  let mut at = 0
  let source = @moonfetch.Source::sized(data.length().to_int64(), () => {
    guard at < data.length() else { return None }
    let piece = data[at:at + 1000].to_owned()
    at += 1000
    Some(piece)
  })
  let r = client.post("/upload", body=Stream(source))
  assert_eq(r.text(), digest(data))
}
