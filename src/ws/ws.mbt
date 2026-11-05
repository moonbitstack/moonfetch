// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// A WebSocket client: RFC 6455, over ws and wss. The connection is the client's: the same TLS
// roots, proxy and timeouts the HTTP side uses.
//
// Opening handshake, RFC 6455 §4: https://www.rfc-editor.org/rfc/rfc6455#section-4
// Framing, §5: https://www.rfc-editor.org/rfc/rfc6455#section-5

///|
/// The GUID the handshake's `Sec-WebSocket-Accept` is derived from (RFC 6455 §1.3).
let guid : String = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

///|
/// The largest message this client assembles: 16 MiB, the same order as the HTTP body bound.
let limit : Int32 = 16 << 20

///|
/// A message on a WebSocket.
pub(all) enum Message {
  Text(String)
  Binary(Bytes)
  Close(status~ : Int32, reason~ : Bytes)
}

///|
/// What the WebSocket client refuses.
pub(all) suberror Refused {
  /// The server answered the opening handshake with something other than 101, or with a
  /// `Sec-WebSocket-Accept` that does not match the key.
  Handshake(status~ : Int32, reason~ : String)
  /// A frame that breaks RFC 6455 §5.
  Protocol(String)
}

///|
/// A WebSocket, open and ready.
pub struct WebSocket {
  priv conn : @tcp.Conn
  /// Bytes that came in behind the handshake's last line: the first frames may already be here.
  priv mut held : Buffer
  priv protocol_ : String?
  priv mut closed : Bool
}

///|
/// The subprotocol the server chose, if any.
pub fn WebSocket::protocol(self : WebSocket) -> String? {
  self.protocol_
}

///|
/// Whether the connection has been closed.
pub fn WebSocket::is_closed(self : WebSocket) -> Bool {
  self.closed
}

///|
/// The wire URL, and whether it is the secure one.
fn parse(text : StringView) -> (@moonurl.Url, Bool) raise @moonfetch.Refused {
  let raw = text.to_owned()
  let (rest, secure) = if raw.has_prefix("wss://") {
    ("https://" + raw[6:].to_owned(), true)
  } else if raw.has_prefix("ws://") {
    ("http://" + raw[5:].to_owned(), false)
  } else {
    raise @moonfetch.Url("\{raw}: not ws or wss")
  }
  let url = @moonurl.Url::decode(rest) catch {
    _ => raise @moonfetch.Url("\{raw}: does not parse")
  }
  guard url.host is Some(host) && host != "" else {
    raise @moonfetch.Url("\{raw}: no host")
  }
  (url, secure)
}

///|
/// The request target: path and query, `/` when the URL names no path.
fn target(url : @moonurl.Url) -> String {
  let path = if url.path == "" { "/" } else { url.path }
  match url.query {
    Some(q) if q != "" => path + "?" + q
    _ => path
  }
}

///|
/// The `Sec-WebSocket-Accept` a server must answer with.
fn accept(key : String) -> String {
  @base64.encode(@sha1.hash(@utf8.encode(key + guid)))
}

///|
/// Open a WebSocket.
///
/// `client` supplies the TLS roots, proxy and timeouts, so a `wss` connection is verified the
/// same way an `https` request is. `headers` are added to the handshake — an `authorization`
/// or a `cookie`, say. `protocols` are offered in the order given; the server picks one or
/// none. `timeout` bounds the handshake, in milliseconds.
pub async fn connect(
  client : @moonfetch.Client,
  url : StringView,
  headers? : Array[(String, String)],
  protocols? : Array[String],
  timeout? : Int32,
) -> WebSocket {
  let (parsed, _secure) = parse(url)
  let authority = parsed.authority().unwrap_or("")
  let key = @base64.encode(@moonseed.bytes(16, @system.source))
  let head = StringBuilder()
  head.write_string("GET \{target(parsed)} HTTP/1.1\r\n")
  head.write_string("Host: \{authority}\r\n")
  head.write_string("Upgrade: websocket\r\n")
  head.write_string("Connection: Upgrade\r\n")
  head.write_string("Sec-WebSocket-Key: \{key}\r\n")
  head.write_string("Sec-WebSocket-Version: 13\r\n")
  match protocols {
    Some(list) if list.length() > 0 =>
      head.write_string("Sec-WebSocket-Protocol: \{list.join(", ")}\r\n")
    _ => ()
  }
  for pair in headers.unwrap_or([]) {
    head.write_string("\{pair.0}: \{pair.1}\r\n")
  }
  head.write_string("\r\n")
  let request = head.to_string()
  let scheme = if parsed.scheme is Some("https") { "https" } else { "http" }
  let run = () => {
    let conn = client.connect("\{scheme}://\{authority}\{target(parsed)}")
    open(conn, request, key)
  }
  match timeout {
    None => run()
    Some(ms) =>
      match @async.with_timeout_opt(ms, run) {
        Some(socket) => socket
        None => raise @moonfetch.Timeout(limit=ms)
      }
  }
}

///|
/// The handshake and the bytes that come with it.
async fn open(conn : @tcp.Conn, request : String, key : String) -> WebSocket {
  conn.write(@utf8.encode(request))
  let held = Buffer()
  for ;; {
    if held.to_bytes().find(b"\r\n\r\n") is Some(_) {
      break
    }
    guard held.length() < 65536 else {
      raise Protocol("handshake head too long")
    }
    match conn.read_some(max_len=16384) {
      Some(data) => held.write_bytes(data)
      None => raise Protocol("closed during the handshake")
    }
  }
  let bytes = held.to_bytes()
  let at = bytes.find(b"\r\n\r\n").unwrap()
  let head = @utf8.decode_lossy(bytes[0:at][:])
  let mut status = 0
  let fields : Array[(String, String)] = []
  for i, line in head.split("\r\n").to_array() {
    if i == 0 {
      status = match line.split_once(" ") {
        Some((_, rest)) =>
          match rest.split_once(" ") {
            Some((code, _)) => @string.parse_int(code) catch { _ => 0 }
            None => 0
          }
        None => 0
      }
    } else if line.length() > 0 {
      match line.split_once(":") {
        Some((name, value)) =>
          fields.push(
            (name.to_owned().to_lower(), value.trim(chars=" ").to_owned()),
          )
        None => ()
      }
    }
  }
  guard status == 101 else { raise Handshake(status~, reason=head) }
  fn field(name : String) -> String? {
    for pair in fields {
      if pair.0 == name {
        return Some(pair.1)
      }
    }
    None
  }
  let wrong = "the server's Sec-WebSocket-Accept does not match"
  match field("sec-websocket-accept") {
    Some(value) => if value != accept(key) { raise Protocol(wrong) }
    None => raise Protocol(wrong)
  }
  let protocol_ = field("sec-websocket-protocol")
  let rest = Buffer()
  rest.write_bytes(bytes[at + 4:])
  { conn, held: rest, protocol_, closed: false, }
}
