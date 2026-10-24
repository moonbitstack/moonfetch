// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A page over HTTP/2, the same origin again on the kept connection, and a JSON body:
///
///     moon run src/examples/tour --target native
#coverage.skip
async fn main {
  let client = @moonfetch.Client::new(timeout=Some(15000))
  defer client.close()
  let page = client.get("https://example.com/")
  println(
    "\{page.url}: \{page.status} over \{page.version}, \{page.body.length()} bytes",
  )
  let again = client.head("https://example.com/")
  println("again on the same connection: \{again.status}")
  let missing = client.get("https://example.com/not-here", redirects=0)
  println("is_success: \{missing.is_success()}")
}
