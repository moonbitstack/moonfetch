// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The host's `fetch` (WHATWG Fetch): a browser's, or Node's, which is undici's. There is no
// socket here and no connection to keep — the host owns both — so this file holds the calls,
// the shapes that answer them, and the one exchange built on them.

///|
#external
priv type JsHeaders

///|
#external
priv type JsResponse

///|
/// A request body as `fetch` takes one: absent, octets, or a stream the host reads from while
/// the request goes out.
#external
priv type JsBody

///|
extern "js" fn JsHeaders::new() -> JsHeaders =
  #| () => new Headers()

///|
extern "js" fn JsHeaders::append(
  self : JsHeaders,
  name : String,
  value : String,
) =
  #| (headers, name, value) => headers.append(name, value)

///|
extern "js" fn JsHeaders::to_array(
  self : JsHeaders,
) -> FixedArray[FixedArray[String]] =
  #| (headers) => Array.from(headers.entries())

///|
extern "js" fn JsBody::none() -> JsBody =
  #| () => null

///|
extern "js" fn JsBody::of_bytes(bytes : Bytes) -> JsBody =
  #| (bytes) => bytes

///|
extern "js" fn JsBody::of_stream(stream : @js_async.JsReadableStream) -> JsBody =
  #| (stream) => stream

///|
extern "js" fn JsResponse::status(self : JsResponse) -> Int32 =
  #| (response) => response.status

///|
extern "js" fn JsResponse::status_text(self : JsResponse) -> String =
  #| (response) => response.statusText

///|
/// The URL that answered, after the host followed whatever redirects it followed.
extern "js" fn JsResponse::url(self : JsResponse) -> String =
  #| (response) => response.url

///|
/// Whether the response is the placeholder a browser hands back for a cross-origin redirect it
/// was told not to follow: no status, no headers, nothing to act on.
extern "js" fn JsResponse::hidden(self : JsResponse) -> Bool =
  #| (response) => response.type === "opaqueredirect" || response.type === "opaque"

///|
extern "js" fn JsResponse::headers(self : JsResponse) -> JsHeaders =
  #| (response) => response.headers

///|
/// The body as a stream to read pieces from; a response without one — a HEAD, a 204 — reads as
/// an empty stream, so a caller never has to ask whether there is a body.
extern "js" fn JsResponse::body(
  self : JsResponse,
) -> @js_async.JsReadableStream =
  #| (response) => response.body ?? new ReadableStream({
  #|   start(controller) { controller.close() },
  #| })

///|
/// One `fetch`. `redirect` is `"manual"` so that the rules this library applies — which method
/// survives a 303, which credentials leave the origin, how many hops are allowed — are its own,
/// as they are on the other host.
extern "js" fn fetched(
  url : String,
  verb : String,
  headers : JsHeaders,
  body : JsBody,
  redirect : String,
  credentials : String,
  signal : @js_async.AbortSignal,
) -> @js_async.Promise[JsResponse] =
  #| (url, verb, headers, body, redirect, credentials, signal) => {
  #|   const init = { method: verb, headers, redirect, credentials, signal }
  #|   if (body !== null) {
  #|     init.body = body
  #|     if (body instanceof ReadableStream) { init.duplex = "half" }
  #|   }
  #|   return fetch(url, init)
  #| }

///|
/// Let a promise that nobody waits for fail without the host reporting it: the promise exists
/// only to feed a body into a pipe, and its failure is the request's failure.
extern "js" fn settle(promise : @js_async.Promise[Unit]) -> Unit =
  #| (promise) => { promise.catch(() => {}) }

///|
/// The headers `fetch` answered with, lower-cased so that both hosts agree on the spelling, and
/// in the order the host keeps them.
fn answered(headers : JsHeaders) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  for pair in headers.to_array() {
    out.push((pair[0].to_lower(), pair[1]))
  }
  out
}

///|
/// A host that undoes the content coding itself — every browser, and Node's — leaves the two
/// headers that described the octets it was given. Drop them, so that a `Response` describes its
/// body whatever host made it, as the other host's decoder does.
fn unlabelled(headers : Array[(String, String)]) -> Array[(String, String)] {
  guard headers.iter().any(pair => pair.0 == "content-encoding") else {
    return headers
  }
  without(headers, ["content-encoding", "content-length"])
}

///|
/// The headers as `fetch` takes them. `fetch` decides `content-length`, `host` and
/// `accept-encoding` itself, and a browser drops the fields of RFC 9110 §10.1 that a page may
/// not set; what is asked for here is what the host does not take away.
fn sent(fields : Array[(String, String)]) -> JsHeaders {
  let headers = JsHeaders::new()
  for field in fields {
    headers.append(field.0, field.1)
  }
  headers
}

///|
/// A body the host reads while the request goes out. The pieces are produced by a task of its
/// own, off the task group, so that a server which stops reading cannot hold the caller; the
/// task ends when the source is spent or the host cancels the stream.
fn fed(source : Source) -> JsBody {
  let (stream, sink) = @js_async.JsReadableStream::new_pipe()
  settle(
    @js_async.Promise::from_async(() => {
      defer sink.close()
      while source.next() is Some(piece) {
        sink.write(piece[:])
      }
    }),
  )
  JsBody::of_stream(stream)
}

///|
/// The body as `fetch` takes it: octets for a whole payload, a fed pipe for a streamed one.
fn wire(payload : Payload) -> JsBody {
  match payload {
    Whole(bytes) =>
      if bytes.length() == 0 {
        JsBody::none()
      } else {
        JsBody::of_bytes(bytes)
      }
    Pieces(source) => fed(source)
  }
}

///|
/// One exchange: the answer's head, its body still to be read. `redirect` is what the host is
/// told to do with a redirect, and `hop` what this library does with it afterwards.
async fn ask(
  url : String,
  verb : @method.Method,
  fields : Array[(String, String)],
  payload : Payload,
  redirect : String,
  credentials : String,
) -> JsResponse {
  @js_async.run_promise(signal => {
    fetched(
      url,
      verb.name(),
      sent(fields),
      wire(payload),
      redirect,
      credentials,
      signal,
    )
  })
}
