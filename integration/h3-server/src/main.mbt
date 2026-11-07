// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The routes the live cases of moonfetch ask for: a greeting, an echo of what arrived, and a
/// redirect. The certificate is the fixture root's, so the client trusts it without a switch.
async fn app(
  scope : @moonasgi.Scope,
  receive : @moonasgi.Receive,
  send : @moonasgi.Send,
) -> Unit {
  guard scope is Http(http) else { return }
  let greet = (status : Int32, body : Bytes) => {
    send(
      @moonasgi.Event::HttpResponseStart(
        status~,
        headers=[("content-type", "text/plain")],
        trailers=false,
      ),
    )
    send(@moonasgi.Event::HttpResponseBody(body~, more_body=false))
  }
  match http.path {
    "/" => greet(200, @utf8.encode("hello over h3\n"))
    "/away" => {
      send(
        @moonasgi.Event::HttpResponseStart(
          status=302,
          headers=[("location", "/")],
          trailers=false,
        ),
      )
      send(@moonasgi.Event::HttpResponseBody(body=b"", more_body=false))
    }
    _ => {
      let mut size = 0
      for ;; {
        guard receive() is HttpRequest(body~, more_body~) else { return }
        size = size + body.length()
        if !more_body {
          break
        }
      }
      let line = "{\"method\":\"\{http.http_method}\",\"path\":\"\{http.path}\",\"size\":\{size}}"
      send(
        @moonasgi.Event::HttpResponseStart(
          status=200,
          headers=[("content-type", "application/json")],
          trailers=false,
        ),
      )
      send(@moonasgi.Event::HttpResponseBody(
        body=@utf8.encode(line),
        more_body=false,
      ))
    }
  }
}

///|
/// Serve until killed on the port `MOONFETCH_H3_PORT` names, 12000 by default.
async fn main raise {
  let port = match @env.get_env_var("MOONFETCH_H3_PORT") {
    Some(text) => @string.parse_int(text) catch { _ => 12000 }
    None => 12000
  }
  println("serving HTTP/1.1, HTTP/2 and HTTP/3 on \{port}")
  let cert = @serve.TlsCert::Pem(
    certificate_file="certs/cert.pem",
    private_key_file="certs/key.pem",
    password=None,
  )

  @quic.serve_config(app, @mooncat.Config::new(port~), cert)
}
