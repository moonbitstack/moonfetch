# moonfetch

An HTTP client for MoonBit, after httpx and reqwest: one call for a request, a
`Client` that keeps its connections, HTTP/1.1 and HTTP/2 chosen by ALPN.

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

|  | |
|:--|:--|
| Versions | HTTP/1.1 and HTTP/2 by ALPN over TLS 1.3 (moontls), HTTP/1.1 in the clear |
| Connections | idle HTTP/1.1 connections kept per origin; one HTTP/2 connection per origin carries every request to it |
| Bodies | `Body` is one value: `Text`, `Bytes`, `Json`, `Form`; the content type follows unless a header names one |
| Redirects | up to 10 followed; a 303, and a 301 or 302 to a POST, become a GET; `authorization` and `cookie` stay with their origin |
| Timeouts | 5 seconds for the whole exchange, redirects included; `timeout=None` on the client waits for ever |
| Compression | `gzip` and `deflate` asked for and decoded; a request with its own `accept-encoding` gets the body as sent |
| Retries | a kept connection the server closed while idle, or an HTTP/2 connection it went away from, is replaced and an idempotent request sent again; a stream the server refused is sent again whatever the method |
| Certificates | checked against the Mozilla roots by mooncred; there is no switch that turns checking off: trust your own CA by giving `tls` roots that hold it |
| Errors | `Refused` for what moonfetch refuses (`Status`, `Redirects`, `Reset`, `Timeout`, `Url`); a socket, TLS or framing error passes through as it is |

## Settings

`Client::new` takes the defaults; each request may replace `timeout` and
`redirects`, and its `headers` replace the client's of the same name.

| Setting | Default | From |
|:--|:--|:--|
| `timeout` | 5000 ms | httpx |
| `redirects` | 10 | reqwest, requests |
| `idle` | 10 connections per origin | urllib3 |
| `http2` | on | reqwest, curl |
| `compression` | on | httpx, reqwest |
| HTTP/2 receive window | 4 MiB per stream, 1 GiB per connection | Go |

## Beside the official client

`moonbitlang/async/http` has a client too. What differs:

|  | `async/http` | moonfetch |
|:--|:--|:--|
| HTTP/2 | no | by ALPN |
| TLS | the system's (OpenSSL, SChannel) | moontls, the same on every platform |
| Connection reuse | one connection per `Client` | a pool per origin |
| Redirects, compression | no | yes |
| Turning certificate checks off | `trust=NoVerification` | not possible; give the roots instead |

The sockets are `moonbitlang/async`'s, so moonfetch runs on the native and wasm
backends. A browser host, streamed responses, WebSocket and HTTP/3 come next.

## Install

```bash
moon add moonbitstack/moonfetch
```

## Licence

Apache-2.0. See [LICENSE](LICENSE).
