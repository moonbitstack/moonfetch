# moonfetch

An HTTP client for MoonBit, after httpx and reqwest: one call for a request, a
`Client` that keeps its connections, HTTP/1.1 and HTTP/2 chosen by ALPN, streamed
bodies, cookies, proxies and a WebSocket client.

```moonbit
// One request.
let r = @moonfetch.get("https://example.com/")
r.status                 // 200
r.version                // "HTTP/2"
r.text()

// A client: connections kept per origin, defaults for every request.
let api = @moonfetch.Client::new(
  base_url="https://api.example.com/v1",
  headers=[("authorization", "Bearer \{token}")],
)
defer api.close()
let user = api.get("/users/7").checked().json()
let made = api.post("/users", body=Json({ "name": "moon" }))
let form = api.post("/login", body=Form([("user", "moon"), ("pass", secret)]))
```

Run `moon run src/examples/tour --target native` to fetch a page over HTTP/2.

## What it does

| | |
|:--|:--|
| Versions | HTTP/1.1 and HTTP/2 by ALPN over TLS (moontls), HTTP/1.1 in the clear, and HTTP/2 in the clear with `h2c` |
| Connections | idle HTTP/1.1 connections kept per origin; one HTTP/2 connection per origin carries every request to it, many at once |
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

## Settings

`Client::new` takes the defaults; each request may replace `timeout` and
`redirects`, and its `headers` replace the client's of the same name.

| Setting | Default | From |
|:--|:--|:--|
| `timeout` | 5000 ms | httpx |
| `redirects` | 10 | reqwest, requests |
| `idle` | 10 connections per origin | urllib3 |
| `http2` | on | reqwest, curl |
| `h2c` | off | — |
| `compression` | on | httpx, reqwest |
| `limits.body` | 32 MiB | — (a stream has no bound) |
| HTTP/2 receive window | 4 MiB per stream, 1 GiB per connection | Go |

## Streaming

`stream` sends the request, follows redirects, and returns once the response head
is in. Each `next` gives a `Data` piece or the `End` with its trailers; the pieces
are the octets as they came, not a line at a time.

```moonbit
let feed = client.stream(Method::Get, "/events")
while feed.next() is Some(piece) {
  match piece {
    Data(bytes) => handle(@sse.decode(@utf8.decode_lossy(bytes[:])))
    End(_) => break
  }
}
```

A stream is not bounded — that is what makes it a stream — so a caller that reads
one to the end passes its own bound: `feed.bytes(limit=1 << 20)`. A buffered
`request` uses `Limits::body` and stops as the octets pass it.

Streaming does not ask for compression: a coding would have to be undone on the
fly. Ask for it yourself if you mean to.

## Request bodies

`Text`, `Bytes`, `Json` and `Form` are whole bodies. `Multipart` is a form with
files, and `Stream` is a body produced while the request is sent:

```moonbit
let upload = Part::file("doc", "notes.txt", @fs.read_file("notes.txt"), content_type="text/plain")
client.post("/upload", body=Multipart([Part::field("owner", "moon"), upload]))

// A body of exactly 4096 octets, produced a kibibyte at a time.
let source = Source::sized(4096, () => next_kibibyte())
client.put("/blob", body=Stream(source))
```

A `Source` with a length declares `content-length`; without one the body is
chunked on HTTP/1.1 and unframed on HTTP/2.

## Cookies

```moonbit
let jar = Jar::new()
let browser = Client::new(jar~)
browser.get("https://example.com/login")    // what the server set is kept
browser.get("https://example.com/account")  // and sent back, where it matches
```

One jar may be shared by several clients and by tasks; it lives as long as the
process, since persistence is not part of it.

## Proxies

```moonbit
let proxied = Client::new(proxy=Proxy::parse("http://user:pass@proxy.internal:3128"))
let socks = Client::new(proxy=Proxy::parse("socks5://proxy.internal:1080"))
```

An `http` request through an HTTP proxy goes in absolute form; an `https` one is
tunnelled with `CONNECT`. SOCKS5 sends the host as a name and lets the proxy
resolve it.

## WebSocket

`moonfetch/ws` shares the client's TLS roots, proxy and timeouts:

```moonbit
let client = Client::new()
let socket = @ws.connect(client, "wss://example.com/chat", protocols=["chat"])
socket.send_text("hello")
while socket.recv() is Some(message) {
  match message {
    Text(text) => handle(text)
    Binary(bytes) => handle(bytes)
    Close(status~, ..) => break
  }
}
socket.close(status=1000)
```

Pings are answered and fragmented messages put back together inside `recv`, so a
caller sees messages, not frames.

## Beside the official client

`moonbitlang/async/http` has a client too. What differs:

| | `async/http` | moonfetch |
|:--|:--|:--|
| HTTP/2 | no | by ALPN, many streams on one connection |
| Streaming | whole bodies | `Stream`, a piece at a time |
| Cookies, proxies | manual | `Jar`, `CONNECT` and SOCKS5 |
| WebSocket | a separate client | `moonfetch/ws`, on the same client |
| TLS | the system's (OpenSSL, SChannel) | moontls, the same on every platform |
| Connection reuse | one connection per `Client` | a pool per origin |
| Redirects, compression | no | yes |
| Turning certificate checks off | `trust=NoVerification` | not possible; give the roots instead |

The sockets are `moonbitlang/async`'s, so moonfetch runs on the native and wasm
backends. A browser host and HTTP/3 are not part of this version.

## Install

```bash
moon add moonbitstack/moonfetch
```

## Licence

Apache-2.0. See [LICENSE](LICENSE).
