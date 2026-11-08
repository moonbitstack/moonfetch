// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// What a request looks like once it leaves the caller: the semicolons are gone, and what is left
// is a head and a body. The pieces here are the ones both hosts agree on — the content type a
// body brings, the length it declares, the two fields every request carries — and the encoders
// that turn them into HTTP/1.1 octets and HTTP/2 frames.

///|
/// A request as it goes on the wire, whichever version carries it.
priv struct Outgoing {
  verb : @method.Method
  scheme : String
  authority : String
  target : String
  fields : Array[@header.Header]
  payload : Payload
}

///|
/// How a request would go on the wire: the version that would carry it, and the pieces it is
/// written as, in order.
///
/// The pieces of an HTTP/1.1 request are its head and then its body; those of an HTTP/2 one are
/// the connection preface, this side's settings, and then one entry per frame, labelled with the
/// frame's type and the flags it carries.
pub(all) struct Wire {
  version : String
  pieces : Array[(String, Bytes)]
}

///|
/// The headers a request goes out with before a transport adds what only it knows: the content
/// type the body brings, the length it declares, and the two fields every request carries.
fn prepared(
  body : Body,
  fields : Array[(String, String)],
) -> (Array[(String, String)], Payload) {
  let (payload, kind) = body.payload()
  let all = fields.copy()
  if kind is Some(k) && !has(all, "content-type") {
    all.push(("content-type", k))
  }
  if payload.length() is Some(n) && !has(all, "content-length") {
    all.push(("content-length", n.to_string()))
  }
  if !has(all, "user-agent") {
    all.push(("user-agent", "moonfetch"))
  }
  if !has(all, "accept") {
    all.push(("accept", "*/*"))
  }
  (all, payload)
}

///|
/// A request as the transports want it: the target is the path and query, the authority is what
/// goes in `host` or `:authority`.
fn going(
  verb : @method.Method,
  url : @moonurl.Url,
  fields : Array[(String, String)],
  payload : Payload,
) -> Outgoing {
  let origin = Origin::of(url)
  let path = if url.path == "" { "/" } else { url.path }
  let target = match url.query {
    Some(query) => path + "?" + query
    None => path
  }
  {
    verb,
    scheme: origin.scheme,
    authority: origin.authority(),
    target,
    fields: fields.map(field => @header.Header::of(field.0, field.1)),
    payload,
  }
}

///|
/// A whole request as one value, the way a client with no jar, proxy or codings would write it.
fn as_prepared(
  verb : @method.Method,
  url : StringView,
  query : Array[(String, String)]?,
  headers : Array[(String, String)]?,
  body : Body,
) -> Outgoing raise Refused {
  let target = located(None, url, query)
  let (fields, payload) = prepared(body, headers.unwrap_or([]))
  going(verb, target, fields, payload)
}

///|
/// The octets an HTTP/1.1 request is written as, for a caller that wants to see them: the head
/// with its framing, then the body.
///
/// A body produced while the request goes out is not read here — taking its pieces would spend
/// them — so only the head is written, with the framing that says a body follows.
///
/// `Refused::Url` for a URL no request can name, and the state machine's own refusal for a field
/// it cannot write.
pub fn wire(
  verb : @method.Method,
  url : StringView,
  query? : Array[(String, String)],
  headers? : Array[(String, String)],
  body? : Body,
) -> Wire raise {
  let out = as_prepared(verb, url, query, headers, body.unwrap_or(Empty))
  { version: "HTTP/1.1", pieces: h1_pieces(@http1.Conn::new(Client), out), }
}

///|
/// The frames an HTTP/2 request is written as: the connection preface, this side's settings, and
/// the HEADERS and DATA frames of the exchange.
///
/// The connection is a fresh one, so the field section is encoded against the static table alone,
/// which is what a first request on a connection looks like.
pub fn frames(
  verb : @method.Method,
  url : StringView,
  query? : Array[(String, String)],
  headers? : Array[(String, String)],
  body? : Body,
) -> Wire raise {
  let out = as_prepared(verb, url, query, headers, body.unwrap_or(Empty))
  { version: "HTTP/2", pieces: h2_pieces(out), }
}

///|
/// The head an HTTP/1.1 request is written as, framing included: the request line, the fields, and
/// the line the framing needs.
fn h1_head(state : @http1.Conn, out : Outgoing) -> Bytes raise {
  let length = out.payload.length()
  // RFC 9110 §8.6: a method that defines a body says how long it is, even when empty.
  let framing : @http1.Body = match length {
    Some(n) =>
      if n > 0 || out.verb is (Post | Put | Patch) {
        Sized(n.to_int())
      } else {
        Empty
      }
    None => Chunked
  }
  // The framing decides `content-length` here; one carried in would be a second, possibly
  // different, value.
  let fields = out.fields.filter(f => f.ascii().0.to_lower() != "content-length")
  let head = @http1.Request::of(
    out.verb.name(),
    out.target,
    fields~,
    host=out.authority,
    body=framing,
  )
  state.send(Request(head))
}

///|
/// The octets of an HTTP/1.1 request, piece by piece: the head, the body, and the empty line that
/// ends a chunked one.
fn h1_pieces(
  state : @http1.Conn,
  out : Outgoing,
) -> Array[(String, Bytes)] raise {
  let pieces : Array[(String, Bytes)] = [("request head", h1_head(state, out))]
  match out.payload {
    Whole(bytes) =>
      if bytes.length() > 0 {
        pieces.push(("body", state.send(Data(bytes))))
      }
    Pieces(_) => ()
  }
  let end = state.send(End([]))
  if end.length() > 0 {
    pieces.push(("end of body", end))
  }
  pieces
}

///|
/// The connection preface of RFC 9113 §3.4.
let preface : Bytes = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

///|
/// The octets of an HTTP/2 request, cut into frames: the preface and this side's settings, then
/// the exchange's own.
fn h2_pieces(out : Outgoing) -> Array[(String, Bytes)] raise {
  let state = @http2.Conn::new(Client)
  let id = state.next_stream()
  let fields : Array[@header.Header] = [
    @header.Header::of(":method", out.verb.name()),
    @header.Header::of(":scheme", out.scheme),
    @header.Header::of(":authority", out.authority),
    @header.Header::of(":path", out.target),
  ]
  for f in out.fields {
    let (name, value) = f.ascii()
    let lower = name.to_lower()
    if h2_carries(lower) {
      fields.push(@header.Header::of(lower, value))
    }
  }
  let empty = out.payload.length() is Some(0)
  state.headers(id, fields, end=empty)
  match out.payload {
    Whole(bytes) => {
      let mut at = 0
      while at < bytes.length() {
        let room = state.window(id)
        if room <= 0 {
          break
        }
        let n = if room < bytes.length() - at {
          room
        } else {
          bytes.length() - at
        }
        state.data(id, bytes[at:at + n])
        at += n
      }
      if !empty {
        state.end(id)
      }
    }
    Pieces(_) => if !empty { state.end(id) }
  }
  cut(state.take())
}

///|
/// Whether HTTP/2 carries this field: the connection-specific ones it forbids (RFC 9113 §8.2.2)
/// belong to HTTP/1.1, and the authority took `host`'s place.
fn h2_carries(name : String) -> Bool {
  !(name
  is ("connection"
  | "keep-alive"
  | "proxy-connection"
  | "transfer-encoding"
  | "upgrade"
  | "host"))
}

///|
/// Cut a connection's octets into the pieces a reader can name: the preface, then each frame with
/// its type and flags.
fn cut(bytes : Bytes) -> Array[(String, Bytes)] {
  let pieces : Array[(String, Bytes)] = []
  let mut at = 0
  if bytes.length() >= preface.length() && bytes[0:preface.length()] == preface {
    pieces.push(("connection preface", preface))
    at = preface.length()
  }
  while at + 9 <= bytes.length() {
    let length = (bytes[at].to_int() << 16) |
      (bytes[at + 1].to_int() << 8) |
      bytes[at + 2].to_int()
    let end = at + 9 + length
    if end > bytes.length() {
      break
    }
    pieces.push(
      (
        frame_label(bytes[at + 3].to_int(), bytes[at + 4].to_int()),
        bytes[at:end].to_owned(),
      ),
    )
    at = end
  }
  if at < bytes.length() {
    pieces.push(("trailing octets", bytes[at:].to_owned()))
  }
  pieces
}

///|
/// A frame's name, with the flags a reader cares about: end of stream, end of headers, an
/// acknowledgement (RFC 9113 §6).
fn frame_label(kind : Int32, flags : Int32) -> String {
  let name = match kind {
    0 => "DATA"
    1 => "HEADERS"
    2 => "PRIORITY"
    3 => "RST_STREAM"
    4 => "SETTINGS"
    5 => "PUSH_PROMISE"
    6 => "PING"
    7 => "GOAWAY"
    8 => "WINDOW_UPDATE"
    9 => "CONTINUATION"
    _ => "frame \{kind}"
  }
  let end_stream : Int32 = 1
  let end_headers : Int32 = 4
  let mut suffix = ""
  if (flags & end_stream) != 0 && (kind == 0 || kind == 1) {
    suffix = " + END_STREAM"
  } else if (flags & end_headers) != 0 && kind == 1 {
    suffix = " + END_HEADERS"
  } else if (flags & end_stream) != 0 && kind == 4 {
    suffix = " + ACK"
  }
  name + suffix
}
