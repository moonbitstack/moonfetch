<p align="center">
  <a href="https://moonbitstack.github.io/moonfetch/"><img src="https://img.shields.io/badge/site-moonfetch-a83a2c" alt="site"></a>
  <a href="https://moonbitstack.github.io/moonfetch/guide.html"><img src="https://img.shields.io/badge/guide-read-a83a2c" alt="guide"></a>
  <a href="https://moonbitstack.github.io/moonfetch/api.html"><img src="https://img.shields.io/badge/API-reference-a83a2c" alt="API reference"></a>
  <a href="https://moonbitstack.github.io/moonfetch/showcase.html"><img src="https://img.shields.io/badge/ShowCase-two-demos-a83a2c" alt="ShowCase"></a>
  <a href="https://mooncakes.io/docs/moonbitstack/moonfetch"><img src="https://img.shields.io/badge/MoonCakes-moonfetch-a83a2c" alt="MoonCakes"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/licence-Apache--2.0-8a8478" alt="licence"></a>
</p>

# moonfetch

An HTTP and WebSocket client for MoonBit: one call for a request, a `Client` that keeps its
connections, HTTP/1.1 and HTTP/2 chosen by ALPN, HTTP/3 over QUIC, streamed bodies, cookies,
proxies — and the same code in a browser, where the host's `fetch` does the work.

```moonbit
async fn fetch_a_page() -> Unit raise {
  let page = @moonfetch.get("https://example.com/")
  println("\{page.url}: \{page.status}, \{page.body.length()} octets")
}
```

```bash
moon add moonbitstack/moonfetch
```

## What it does

| | |
|:--|:--|
| Versions | HTTP/1.1 and HTTP/2 by ALPN over TLS, HTTP/1.1 in the clear, HTTP/2 in the clear with `h2c`, and HTTP/3 over QUIC when asked for |
| Hosts | native and wasm over moonnet's connections; the browser and Node over `fetch` |
| Connections | idle HTTP/1.1 connections kept per origin; one HTTP/2 or HTTP/3 connection per origin carries every request to it, many at once |
| Bodies | `Body` is one value: `Text`, `Bytes`, `Json`, `Form`, `Multipart`, `Stream`; the content type follows unless a header names one |
| Streaming | `Client::stream` returns as soon as the head is in; `Stream::next` hands over pieces as they arrive, for server-sent events and downloads |
| Bounds | a buffered body stops at `Limits::body` while it is being read, not after |
| Redirects | up to 10 followed; a 303, and a 301 or 302 to a POST, become a GET; `authorization` and `cookie` stay with their origin |
| Timeouts | 5 seconds for the whole exchange, redirects included; a stream bounds the head and each read instead |
| Compression | `gzip` and `deflate` asked for and decoded; a request with its own `accept-encoding` gets the body as sent |
| Cookies | a `Jar` follows RFC 6265bis: domain and path matching, expiry, the `__Host-` and `__Secure-` prefixes, the Public Suffix List |
| Proxies | `CONNECT` for an HTTP proxy, SOCKS5 for a SOCKS one, with a username and password for either |
| Retries | a kept connection the server closed while idle, or an HTTP/2 connection it went away from, is replaced and an idempotent request sent again; a stream the server refused is sent again whatever the method, and a request with a streamed body is never replayed |
| Certificates | checked against the Mozilla roots by mooncred; there is no switch that turns checking off: trust your own CA by giving `tls` roots that hold it |
| Errors | `Refused` for what moonfetch refuses (`Status`, `Redirects`, `Reset`, `Timeout`, `Url`, `Exceeded`, `Proxy`); a socket, TLS or framing error passes through as it is |

## A client

```moonbit
async fn calls(token : String) -> Unit raise {
  let api = @moonfetch.Client::new(
    base_url="https://api.example.com/v1",
    headers=[("authorization", "Bearer \{token}")],
    timeout=Some(10000),
  )
  defer api.close()
  let user = api.get("/users/7").checked()
  let made = api.post("/users", body=@moonfetch.Body::Json({ "name": "moon" }))
  let form = api.post("/login", body=@moonfetch.Body::Form([("user", "moon")]))
  println("\{user.status} \{made.status} \{form.status}")
}
```

`base_url` is the prefix relative URLs are joined to, as httpx joins them: its path is kept, so
`/users` under `https://a.example/api` is `https://a.example/api/users`. `headers` go on every
request; a `headers` given for one request replaces the client's of the same name.

## Hosts

The package has two transports and picks one at build time. Nothing in a program changes between
them; what a host does not have is not offered, and the differences are these:

| | native, wasm | js |
|:--|:--|:--|
| Transport | moonnet's sockets, TLS and ALPN | the host's `fetch` |
| `Client::new` | `tls?`, `proxy?`, `jar?`, `http2~`, `h2c~`, `compression~`, `idle~` | `credentials~` |
| Connections, proxies, cookies | this library's | the host's; `close` has nothing to close |
| `Response::version` | the version that answered | empty: a browser does not say |
| `Client::connect` | a connection to upgrade | not there |
| HTTP/3 | over QUIC by moonnet | whatever the host does itself |

A browser also decides the fields of RFC 9110 §10.1 that a page may not set, follows a
cross-origin redirect itself, and rules on CORS before moonfetch sees anything.

## HTTP/3

`http3=true` speaks HTTP/3 over QUIC. It is offered for `https` only, since there is no HTTP/3 in
the clear; an origin that does not answer on the datagram within three seconds is spoken to over
TCP from then on, and the rest of the program does not see the attempt. A browser host has no such
switch.

<!-- native: the js host has no http3~ -->
```moonbit native
async fn over_quic() -> Unit raise {
  let client = @moonfetch.Client::new(http3=true, timeout=Some(10000))
  defer client.close()
  let response = client.get("https://cloudflare.com/cdn-cgi/trace")
  println(response.version)
}
```

One QUIC connection carries every exchange to an origin, one bidirectional stream each, so
requests overlap the way they do on HTTP/2. Settings advertise a QPACK table of no entries, which
keeps a reply to the static table; the connection is moonnet's, which runs moonquic's state
machine on the datagram socket.

A reply is read as it arrives rather than a frame at a time: a DATA frame may carry a whole body,
however large, so the octets are taken as they come and the room that reading frees goes back to
the server as flow-control credit while the body is still on its way. Eight mebibytes from a
server that writes its answer in one frame is one of the cases this repository runs.

## Streaming

`stream` sends the request, follows redirects, and returns once the response head is in. Each
`next` gives a `Data` piece or the `End` with its trailers; the pieces are the octets as they came,
not a line at a time.

```moonbit
async fn feed(client : @moonfetch.Client) -> Unit raise {
  let stream = client.stream(@method.Method::Get, "/events")
  for ;; {
    match stream.next() {
      Some(@moonfetch.Data(bytes)) => println(bytes.length())
      Some(@moonfetch.End(trailers)) => {
        println(trailers.length())
        break
      }
      None => break
    }
  }
}
```

A stream is not bounded — that is what makes it a stream — so a caller that reads one to the end
passes its own bound: `stream.bytes(limit=1048576)`. A buffered `request` uses `Limits::body` and
stops as the octets pass it.

Streaming does not ask for compression: a coding would have to be undone on the fly. Ask for it
yourself if you mean to.

## Request bodies

`Text`, `Bytes`, `Json` and `Form` are whole bodies. `Multipart` is a form with files, and
`Stream` is a body produced while the request is sent:

```moonbit
async fn upload(client : @moonfetch.Client, notes : Bytes) -> Unit raise {
  let part = @moonfetch.Part::file("doc", "notes.txt", notes, content_type="text/plain")
  ignore(client.post("/upload", body=@moonfetch.Body::Multipart([
    @moonfetch.Part::field("owner", "moon"),
    part,
  ])))
}
```

```moonbit
async fn put_kibibytes(client : @moonfetch.Client) -> Unit raise {
  let mut sent = 0
  let source = @moonfetch.Source::sized(4096, () => {
    guard sent < 4096 else { return None }
    sent = sent + 1024
    Some(Bytes::make(1024, b'x'))
  })
  ignore(client.put("/blob", body=@moonfetch.Body::Stream(source)))
}
```

A `Source` with a length declares `content-length`; without one the body is chunked on HTTP/1.1
and unframed on HTTP/2 and HTTP/3.

## Seeing the bytes

`wire` and `frames` write a request the way the transports do, without sending it: for a log, a
test, or a page that wants to show a reader what it builds.

```moonbit
let sent = @moonfetch.wire(@method.Method::Get, "https://example.com/a?b=1")
assert_eq(sent.version, "HTTP/1.1")
assert_eq(@utf8.decode_lossy(sent.pieces[0].1[:]), "GET /a?b=1 HTTP/1.1\r\nhost: example.com\r\nuser-agent: moonfetch\r\naccept: */*\r\n\r\n")
```

`frames` gives the same request as HTTP/2 writes it: the connection preface, this side's settings,
and one entry per frame, each labelled with its type and flags — `HEADERS + END_STREAM`, `DATA`,
`DATA + END_STREAM`. Both take the same `Body` a request does, so the octets are the ones that
would go out, not a sketch of them.

## Cookies

```moonbit native
async fn browser() -> Unit raise {
  let jar = @moonfetch.Jar::new()
  let client = @moonfetch.Client::new(jar~)
  defer client.close()
  ignore(client.get("https://example.com/login"))
  ignore(client.get("https://example.com/account"))
}
```

One jar may be shared by several clients and by tasks; it lives as long as the process, since
persistence is not part of it.

## Proxies

```moonbit native
fn through_a_proxy() -> Unit raise {
  let http = @moonfetch.Proxy::parse("http://user:pass@proxy.internal:3128")
  let socks = @moonfetch.Proxy::parse("socks5://proxy.internal:1080")
  println("\{http.host} \{socks.host}")
}
```

An `http` request through an HTTP proxy goes in absolute form; an `https` one is tunnelled with
`CONNECT`. SOCKS5 sends the host as a name and lets the proxy resolve it.

## WebSocket

`moonfetch/ws` shares the client's TLS roots, proxy and timeouts:

```moonbit native
async fn chat(client : @moonfetch.Client) -> Unit raise {
  let socket = @ws.connect(client, "wss://example.com/chat", protocols=["chat"])
  socket.send_text("hello")
  while socket.recv() is Some(message) {
    match message {
      @ws.Text(text) => println(text)
      @ws.Binary(bytes) => println(bytes.length())
      @ws.Close(status~, ..) => {
        println(status)
        break
      }
    }
  }
  socket.close(status=1000)
}
```

Pings are answered and fragmented messages put back together inside `recv`, so a caller sees
messages, not frames.

## Consistency

What this client was checked against, and what it came out as.

| Suite | Where | Result |
|:--|:--|:--|
| This repository's cases, over HTTP/1.1, HTTP/2 and HTTP/3 | every push, three systems | pass |
| The same cases on the js host, against a server written on Node's `http` | every push | pass |
| HTTP/3 against nginx 1.29 (`--with-http_v3_module`, in a container) and against mooncat's QUIC listener, real traffic each | every push | pass |
| HTTP/3 against aioquic 1.3.0, which writes a reply as one DATA frame however large, the 8 MiB body included | every push | pass |
| 21 public HTTPS origins, 15 of them over HTTP/2 | once, by hand | 19 of 21; the two that fail offer TLS 1.2 only, which moontls does not speak |

## Beside the official client

`moonbitlang/async/http` has a client too. What differs:

| | `async/http` | moonfetch |
|:--|:--|:--|
| HTTP/2 | no | by ALPN, many streams on one connection |
| HTTP/3 | no | over QUIC, with a fallback to TCP |
| Streaming | whole bodies | `Stream`, a piece at a time |
| Cookies, proxies | manual | `Jar`, `CONNECT` and SOCKS5 |
| WebSocket | a separate client | `moonfetch/ws`, on the same client |
| TLS | the system's (OpenSSL, SChannel) | moontls, the same on every platform |
| Connection reuse | one connection per `Client` | a pool per origin |
| Redirects, compression | no | yes |
| Browser host | `fetch` behind the same interface | `fetch` behind the same interface |
| Turning certificate checks off | `trust=NoVerification` | not possible; give the roots instead |

## Licence

Apache-2.0. See [LICENSE](LICENSE).
