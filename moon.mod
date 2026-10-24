name = "moonbitstack/moonfetch"

version = "0.1.0"

readme = "README.md"

repository = "https://github.com/moonbitstack/moonfetch"

license = "Apache-2.0"

keywords = [ "http", "client", "fetch", "async", "requests", "moonbit" ]

description = "moonfetch — an HTTP client for MoonBit (← httpx, reqwest): one call for a request, a Client that keeps connections, HTTP/1.1 and HTTP/2 chosen by ALPN, redirects, timeouts and JSON."

source = "src"

import {
  "moonbitstack/moonnet@0.1.1",
  "moonbitstack/moontls@0.9.2",
  "moonbitstack/mooncred@0.6.4",
  "moonbitstack/moonhttp@0.15.1",
  "moonbitstack/moonurl@0.2.0",
  "moonbitstack/moonzip@0.3.0",
  "moonbitlang/async@0.22.5",
}
