// Request bodies that are not one buffer: multipart forms, and pieces produced while sending.

///|
fn text_of(value : Json, key : String) -> String raise {
  guard value is Object(members) && members.get(key) is Some(String(text)) else {
    fail("no \{key} in \{value.stringify()}")
  }
  text
}

///|
fn array(value : Json) -> Array[Json] raise {
  guard value is Array(items) else {
    fail("not an array: \{value.stringify()}")
  }
  items
}

///|
async test "body: multipart fields and files go as RFC 7578 says, over both versions" {
  with_servers(secure=true, (port, other, _) => {
    let body = @moonfetch.Body::Multipart([
      @moonfetch.Part::field("who", "moon"),
      @moonfetch.Part::file("doc", "a.txt", b"hello", content_type="text/plain"),
      @moonfetch.Part::file("blob", "b.bin", b"bin"),
    ])
    for base in ["https://localhost:\{port}", "http://localhost:\{other}"] {
      let client = @moonfetch.Client::new(
        base_url=base,
        tls=trusting(),
        timeout=Some(60000),
      )
      defer client.close()
      let parts = array(client.post("/multipart", body~).json())
      assert_eq(parts.length(), 3)
      assert_eq(text_of(parts[0], "name"), "who")
      assert_eq(text_of(parts[0], "body"), "moon")
      assert_eq(text_of(parts[0], "filename"), "")
      assert_eq(text_of(parts[1], "filename"), "a.txt")
      assert_eq(text_of(parts[1], "body"), "hello")
      assert_eq(text_of(parts[2], "filename"), "b.bin")
      assert_eq(text_of(parts[2], "body"), "bin")
      // The content type is the form's, with the boundary it used.
      let echo = client.post(
        "/echo",
        body=@moonfetch.Body::Multipart([@moonfetch.Part::field("x", "1")]),
      )
      assert_true(
        echo.json() is Object(m) &&
        m.get("type") is Some(String(kind)) &&
        kind.has_prefix("multipart/form-data; boundary="),
      )
      // A quote in a name and a boundary-looking string in the content survive the trip.
      let awkward = b"--moonfetch-1-0\r\nContent-Disposition: form-data; name=\"x\""
      let odd = array(
        client
        .post(
          "/multipart",
          body=@moonfetch.Body::Multipart([
            @moonfetch.Part::file("f\"x", "a\"b.txt", awkward),
          ]),
        )
        .json(),
      )
      assert_eq(text_of(odd[0], "name"), "f%22x")
      assert_eq(text_of(odd[0], "filename"), "a%22b.txt")
      assert_eq(text_of(odd[0], "body"), @utf8.decode_lossy(awkward[:]))
    }
  })
}

///|
async test "body: a source with a length declares it; one without is chunked, over both versions" {
  with_servers(secure=true, (port, other, _) => {
    for
      (base, version) in [
        ("https://localhost:\{port}", "HTTP/2"),
        ("http://localhost:\{other}", "HTTP/1.1"),
      ] {
      let client = @moonfetch.Client::new(
        base_url=base,
        tls=trusting(),
        timeout=Some(60000),
      )
      defer client.close()
      let pieces = Ref(0)
      let sized = @moonfetch.Source::sized(5, () => {
        if pieces.val >= 2 {
          None
        } else {
          pieces.val += 1
          Some(if pieces.val == 1 { b"hel" } else { b"lo" })
        }
      })
      let uploaded = client.post("/upload", body=@moonfetch.Body::Stream(sized))
      assert_eq(uploaded.text(), digest(b"hello"))
      // A length that was promised is the one on the wire.
      let counted = Ref(0)
      let declared = @moonfetch.Source::sized(5, () => {
        if counted.val >= 1 {
          None
        } else {
          counted.val += 1
          Some(b"hello")
        }
      })
      let echo = client.post("/echo", body=@moonfetch.Body::Stream(declared))
      assert_eq(echoed(echo, "length"), "5")
      assert_eq(echoed(echo, "body"), "hello")
      assert_eq(echoed(echo, "version"), version)
      // Without a length: chunked on HTTP/1.1, no `content-length` on HTTP/2.
      let open = Ref(0)
      let unknown = @moonfetch.Source::new(() => {
        if open.val >= 1 {
          None
        } else {
          open.val += 1
          Some(b"free")
        }
      })
      let loose = client.post("/echo", body=@moonfetch.Body::Stream(unknown))
      assert_eq(echoed(loose, "body"), "free")
      assert_eq(echoed(loose, "length"), "")
    }
  })
}
