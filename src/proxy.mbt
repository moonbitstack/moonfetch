// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A proxy a client sends its connections through.
///
/// `http` and `https` are the `CONNECT` method of RFC 9110 §9.3.6 — an `https` proxy speaks TLS
/// to the proxy itself — and `socks5` is RFC 1928, with the host sent as a name so the proxy
/// resolves it. The user and password, when present, authenticate to the proxy: `Basic` for
/// `CONNECT`, username and password for SOCKS5.
pub(all) struct Proxy {
  scheme : String
  host : String
  port : Int32
  user : String?
  password : String?
}

///|
/// A proxy from a URL: `http://user:pass@host:1080`, `socks5://host:1080`.
pub fn Proxy::parse(text : StringView) -> Proxy raise Refused {
  let url = @moonurl.Url::decode(text) catch { _ => raise Url(text.to_owned()) }
  let scheme = url.scheme.unwrap_or("")
  guard scheme is ("http" | "https" | "socks5" | "socks5h") else {
    raise Url("\{text}: not a proxy scheme")
  }
  let port = match url.port {
    Some(port) => port
    None =>
      match scheme {
        "http" => 80
        "https" => 443
        _ => 1080
      }
  }
  guard url.host is Some(host) && host != "" else {
    raise Url("\{text}: no host")
  }
  let (user, password) = match url.userinfo {
    Some(info) =>
      match info.split_once(":") {
        Some((user, password)) =>
          (Some(user.to_owned()), Some(password.to_owned()))
        None => (Some(info), None)
      }
    None => (None, None)
  }
  { scheme, host, port, user, password, }
}

///|
/// Whether the proxy takes an `http` request in absolute form instead of a tunnel.
fn Proxy::absolute(self : Proxy) -> Bool {
  self.scheme is ("http" | "https")
}

///|
/// The `Proxy-Authorization` value, when the proxy wants one.
fn Proxy::authorization(self : Proxy) -> String? {
  match (self.user, self.password) {
    (Some(user), Some(password)) =>
      Some("Basic " + @base64.encode(@utf8.encode("\{user}:\{password}")))
    _ => None
  }
}

///|
/// Open the tunnel to `host:port` through an HTTP proxy (`CONNECT`).
async fn Proxy::tunnel(
  self : Proxy,
  conn : @tcp.Conn,
  host : String,
  port : Int32,
) -> Unit {
  let authority = if host.contains(":") {
    "[\{host}]:\{port}"
  } else {
    "\{host}:\{port}"
  }
  let head = StringBuilder()
  head.write_string("CONNECT \{authority} HTTP/1.1\r\n")
  head.write_string("Host: \{authority}\r\n")
  if self.authorization() is Some(value) {
    head.write_string("Proxy-Authorization: \{value}\r\n")
  }
  head.write_string("\r\n")
  conn.write(@utf8.encode(head.to_string()))
  let held = Buffer()
  for ;; {
    if held.to_bytes().find(b"\r\n\r\n") is Some(_) {
      break
    }
    guard held.length() < 65536 else {
      raise Proxy("\{authority}: CONNECT head too long")
    }
    match conn.read_some(max_len=chunk) {
      Some(data) => held.write_bytes(data)
      None => raise Proxy("\{authority}: closed during CONNECT")
    }
  }
  let answer = @utf8.decode_lossy(held.to_bytes()[:])
  let status = match answer.split_once("\r\n") {
    Some((line, _)) =>
      match line.split_once(" ") {
        Some((_, rest)) =>
          match rest.split_once(" ") {
            Some((code, _)) => @string.parse_int(code) catch { _ => 0 }
            None => 0
          }
        None => 0
      }
    None => 0
  }
  guard status is (200..<300) else {
    raise Proxy("\{authority}: CONNECT answered \{status}")
  }
}

///|
/// RFC 1928: greet, authenticate if asked, then ask for `host:port`.
async fn Proxy::socks5(
  self : Proxy,
  conn : @tcp.Conn,
  host : String,
  port : Int32,
) -> Unit {
  let hello = Buffer()
  hello.write_byte(b'\x05')
  if self.user is Some(_) {
    hello.write_byte(b'\x02')
    hello.write_byte(b'\x00')
    hello.write_byte(b'\x02')
  } else {
    hello.write_byte(b'\x01')
    hello.write_byte(b'\x00')
  }
  conn.write(hello.to_bytes())
  let answer = conn.read_exactly(2)
  guard answer[0] == b'\x05' else { raise Proxy("not a SOCKS5 proxy") }
  match answer[1].to_int() {
    0 => ()
    2 =>
      match (self.user, self.password) {
        (Some(user), Some(password)) => {
          let auth = Buffer()
          auth.write_byte(b'\x01')
          auth.write_byte(user.length().to_byte())
          auth.write_bytes(@utf8.encode(user))
          auth.write_byte(password.length().to_byte())
          auth.write_bytes(@utf8.encode(password))
          conn.write(auth.to_bytes())
          let reply = conn.read_exactly(2)
          guard reply[1].to_int() == 0 else {
            raise Proxy("SOCKS5 authentication refused")
          }
        }
        _ => raise Proxy("SOCKS5 wants a username and password")
      }
    code => raise Proxy("SOCKS5 wants method \{code}, which is not offered")
  }
  let name = @utf8.encode(host)
  guard name.length() <= 255 else {
    raise Proxy("host name too long for SOCKS5")
  }
  let ask = Buffer()
  ask.write_byte(b'\x05')
  ask.write_byte(b'\x01')
  ask.write_byte(b'\x00')
  ask.write_byte(b'\x03')
  ask.write_byte(name.length().to_byte())
  ask.write_bytes(name)
  ask.write_byte((port >> 8).to_byte())
  ask.write_byte((port & 0xff).to_byte())
  conn.write(ask.to_bytes())
  let reply = conn.read_exactly(4)
  guard reply[0] == b'\x05' else {
    raise Proxy("SOCKS5 reply is not version 5")
  }
  guard reply[1].to_int() == 0 else {
    raise Proxy("SOCKS5 refused: \{socks_reason(reply[1].to_int())}")
  }
  match reply[3].to_int() {
    1 => ignore(conn.read_exactly(4 + 2))
    4 => ignore(conn.read_exactly(16 + 2))
    3 => {
      let length = conn.read_exactly(1)
      ignore(conn.read_exactly(length[0].to_int() + 2))
    }
    _ => raise Proxy("SOCKS5 reply has an unknown address type")
  }
}

///|
fn socks_reason(code : Int32) -> String {
  match code {
    1 => "general failure"
    2 => "not allowed by the rules"
    3 => "network unreachable"
    4 => "host unreachable"
    5 => "connection refused"
    6 => "time out"
    7 => "command not supported"
    8 => "address type not supported"
    _ => "error \{code}"
  }
}
