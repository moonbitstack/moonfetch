---
name: moonfetch
description: "Make HTTP and WebSocket requests from MoonBit: one call for a request, a Client that keeps its connections, HTTP/1.1, HTTP/2 and HTTP/3, streamed bodies, cookies, proxies, and the same code in a browser."
---

# moonfetch

```bash
moon add moonbitstack/moonfetch
```

```moonbit
import {
  "moonbitstack/moonfetch",
  "moonbitstack/moonhttp/method",
}
```

`Client` is the reusable one; the `get`/`post`/… functions each make a client of their own.

## A request

```moonbit
async fn read(client : @moonfetch.Client) -> String raise {
  let response = client.get("/users/7")
  response.checked().text()
}
```

`checked()` raises `@moonfetch.Refused::Status` for a 4xx or 5xx; `json()` parses the body,
`text()` decodes it as UTF-8, `body` is the octets.

## A client with defaults

```moonbit
async fn calls() -> Unit raise {
  let api = @moonfetch.Client::new(
    base_url="https://api.example.com/v1",
    headers=[("authorization", "Bearer token")],
    timeout=Some(10000),
  )
  defer api.close()
  let created = api.post("/users", body=@moonfetch.Body::Json({ "name": "moon" }))
  assert_eq(created.status, 201)
}
```

`base_url` is joined as httpx joins it, `headers` go on every request, and a per-request
`headers=[...]` replaces the client's of the same name. `timeout` (milliseconds, 5000 by default)
bounds each request, redirects included.

## Reading a large body as it arrives

```moonbit
async fn tail(client : @moonfetch.Client) -> Unit raise {
  let stream = client.stream(@method.Method::Get, "/events")
  for ;; {
    match stream.next() {
      Some(@moonfetch.Data(bytes)) => println(bytes.length())
      Some(@moonfetch.End(_trailers)) => break
      None => break
    }
  }
}
```

A `Stream` is not bounded; `stream.bytes(limit=1 << 20)` reads the rest with one.

## Rules that catch people out

- `Body` is one value: `Text`, `Bytes`, `Json`, `Form`, `Multipart`, `Stream`. The content type
  follows from it unless a header names one.
- There is no switch that turns certificate checking off. Put your own CA in `tls`
  (`@tls.Client::new(@x509.Roots::new(certs=...))`) instead.
- Redirects are followed 10 times by default; a 303, and a 301 or 302 answering a POST, become a
  GET without a body, and `authorization` and `cookie` are dropped when the redirect leaves the
  origin.
- Ask for HTTP/3 with `http3=true` on `Client::new`. It is HTTPS only, and an origin that does not
  answer on the datagram is spoken to over TCP from then on.
- On the js backend the host's `fetch` does the work: `close`, `jar`, `proxy` and the TLS settings
  are not there, and `Response::version` is empty because a browser does not say which version
  answered. `Client::new` takes `credentials` there.
- A `Source` body (`Body::Stream`) is produced while the request goes out, so it can only be sent
  once; a retry of such a request is refused rather than sent with an empty body.
