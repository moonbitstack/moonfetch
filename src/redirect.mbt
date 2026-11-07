// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// What to send after an answer: nothing more, or the next hop of a redirect.
priv enum Next {
  Stop
  Again(
    verb~ : @method.Method,
    url~ : @moonurl.Url,
    fields~ : Array[(String, String)],
    body~ : Body
  )
}

///|
/// Whether an answer is a redirect this client follows, and what it sends next (RFC 9110
/// §15.4).
///
/// A 303, and a 301 or 302 answering a POST, turn into a GET without a body, as browsers and
/// every client in use do. Credentials stay with their origin: `authorization` and `cookie` are
/// dropped when a redirect leaves it, and a jar supplies the cookies the new origin has.
fn next_hop(
  hop : Int32,
  limit : Int32,
  status : Int32,
  location : String?,
  verb : @method.Method,
  url : @moonurl.Url,
  fields : Array[(String, String)],
  body : Body,
) -> Next raise Refused {
  guard limit > 0 &&
    status is (301 | 302 | 303 | 307 | 308) &&
    location is Some(location) else {
    return Stop
  }
  if hop == limit {
    raise Redirects(limit~)
  }
  let next = url.resolve(parse(location))
  check(next, location)
  let to_get = (status == 303 && !(verb is Head)) ||
    (status is (301 | 302) && verb is Post)
  let (verb, body, fields) = if to_get {
    (
      @method.Method::Get,
      Body::Empty,
      without(fields, ["content-type", "content-length"]),
    )
  } else {
    (verb, body, fields)
  }
  let fields = if Origin::of(next).key() == Origin::of(url).key() {
    fields
  } else {
    without(fields, ["authorization", "cookie"])
  }
  Again(verb~, url=next, fields~, body~)
}
