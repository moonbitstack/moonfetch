// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The site's engine: this library built to JavaScript, so that the pages call it rather than
// describe it. Strings and JSON in, JSON out — nothing here reimplements the library.

///|
/// The fields a page asked for: a JSON array of `[name, value]` pairs.
fn fields_of(json : String) -> Array[(String, String)] {
  let parsed = @json.parse(json) catch { _ => return [] }
  let out : Array[(String, String)] = []
  guard parsed is Array(rows) else { return out }
  for row in rows {
    guard row is Array(cells) && cells.length() == 2 else { continue }
    let (name, value) = match (cells[0], cells[1]) {
      (String(name), String(value)) => (name, value)
      _ => continue
    }
    out.push((name, value))
  }
  out
}

///|
/// The body a page asked for: no body when the field is empty, the text as UTF-8 otherwise.
fn body_of(text : String) -> @moonfetch.Body {
  if text == "" {
    @moonfetch.Body::Empty
  } else {
    @moonfetch.Body::Text(text)
  }
}

///|
/// One piece of a request, as a page shows it: what it is called, how long it is, its text when it
/// has one, and its octets in hex either way.
fn piece_json(label : String, bytes : Bytes) -> Json {
  let hex = StringBuilder()
  for byte in bytes {
    hex.write_string(byte.to_hex())
  }
  {
    "label": Json(label),
    "size": Json::number(bytes.length().to_double()),
    "text": Json(@utf8.decode_lossy(bytes[:])),
    "hex": Json(hex.to_string()),
  }
}

///|
/// A request as a page shows it: the version, and the pieces in the order they are written.
fn wire_json_of(version : String, pieces : Array[(String, Bytes)]) -> Json {
  let rows : Array[Json] = []
  for piece in pieces {
    rows.push(piece_json(piece.0, piece.1))
  }
  { "version": Json(version), "pieces": Json(rows) }
}

///|
/// A quote or a backslash in a message would end the JSON string early.
fn escaped(text : String) -> String {
  let out = StringBuilder()
  for c in text {
    match c {
      '"' => out.write_string("\\\"")
      '\\' => out.write_string("\\\\")
      '\n' => out.write_string("\\n")
      '\r' => out.write_string("\\r")
      _ => out.write_char(c)
    }
  }
  out.to_string()
}

///|
/// The same request as HTTP/1.1 and as HTTP/2 write it, for the anatomy page.
pub fn preview(
  verb_name : String,
  url : String,
  headers : String,
  body : String,
) -> String {
  let verb = @method.Method::of(verb_name) catch {
    _ => @method.Method::Other(verb_name)
  }
  let fields = fields_of(headers)
  let payload = body_of(body)
  let one = @moonfetch.wire(verb, url, headers=fields, body=payload) catch {
    e => return "{\"error\":\"\{escaped(e.to_string())}\"}"
  }
  let two = @moonfetch.frames(verb, url, headers=fields, body=payload) catch {
    e => return "{\"error\":\"\{escaped(e.to_string())}\"}"
  }
  let answer : Json = {
    "h1": wire_json_of(one.version, one.pieces),
    "h2": wire_json_of(two.version, two.pieces),
    "error": Json(null),
  }
  answer.stringify()
}

///|
/// A real request, made by this library's browser host, for the same page: the answer's status,
/// fields and body, or what went wrong.
pub fn send(
  verb_name : String,
  url : String,
  headers : String,
  body : String,
) -> @js_async.Promise[String] {
  @js_async.Promise::from_async(() => {
    let verb = @method.Method::of(verb_name) catch {
      _ => @method.Method::Other(verb_name)
    }
    let fields = fields_of(headers)
    let payload = body_of(body)
    let started = @async.now()
    let answer = @moonfetch.request(
      verb,
      url,
      headers=fields,
      body=payload,
      timeout=15000,
    ) catch {
      e => return "{\"error\":\"\{escaped(e.to_string())}\"}"
    }
    let rows : Array[Json] = []
    for pair in answer.headers {
      let row : Array[Json] = [Json(pair.0), Json(pair.1)]
      rows.push(Json(row))
    }
    let result : Json = {
      "status": Json::number(answer.status.to_double()),
      "reason": Json(answer.reason),
      "version": Json(answer.version),
      "url": Json(answer.url),
      "headers": Json(rows),
      "body": Json(answer.text()),
      "ms": Json::number((@async.now() - started).to_double()),
      "error": Json(null),
    }
    result.stringify()
  })
}

///|
/// What one request costs in octets on each version, for the game: the head and the body as
/// HTTP/1.1 writes them, and the frames HTTP/2 writes, summed.
pub fn costs(url : String) -> String {
  let into = (wire : @moonfetch.Wire) => {
    let mut sum = 0
    for piece in wire.pieces {
      sum = sum + piece.1.length()
    }
    sum
  }
  let one = @moonfetch.wire(@method.Method::Get, url) catch {
    _ => return "{\"error\":\"refused\"}"
  }
  let two = @moonfetch.frames(@method.Method::Get, url) catch {
    _ => return "{\"error\":\"refused\"}"
  }
  let answer : Json = {
    "h1": Json::number(into(one).to_double()),
    "h2": Json::number(into(two).to_double()),
  }
  answer.stringify()
}
