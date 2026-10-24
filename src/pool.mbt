// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// How much is read from a connection at once: a TLS record's worth. The async default is a
/// kibibyte.
let chunk : Int32 = 16384

///|
/// Where a request goes: scheme, host and port, the unit connections are kept by (RFC 6454).
priv struct Origin {
  scheme : String
  host : String
  port : Int32
}

///|
fn Origin::key(self : Origin) -> String {
  "\{self.scheme}://\{self.host}:\{self.port}"
}

///|
/// The host and port as a request names them: the port left out when it is the scheme's own.
fn Origin::authority(self : Origin) -> String {
  let host = if self.host.contains(":") { "[\{self.host}]" } else { self.host }
  match (self.scheme, self.port) {
    ("http", 80) | ("https", 443) => host
    _ => "\{host}:\{self.port}"
  }
}

///|
/// A connection to an origin, in whichever version ALPN settled on.
priv enum Link {
  H1(@tcp.Conn, reused~ : Bool)
  H2(H2, reused~ : Bool)
}

///|
/// Idle HTTP/1.1 connections, a few per origin, and one HTTP/2 connection per origin, which
/// carries every request to it.
priv struct Pool {
  idle : Map[String, Array[@tcp.Conn]]
  h2 : Map[String, H2]
  keep : Int32
}

///|
fn Pool::new(keep : Int32) -> Pool {
  { idle: Map([]), h2: Map([]), keep, }
}

///|
async fn Pool::checkout(
  self : Pool,
  origin : Origin,
  tls : @tls.Client,
) -> Link {
  let key = origin.key()
  if self.h2.get(key) is Some(h2) {
    if !h2.dead {
      return H2(h2, reused=true)
    }
    self.forget(origin, h2)
  }
  if self.idle.get(key) is Some(conns) && conns.pop() is Some(conn) {
    return H1(conn, reused=true)
  }
  let secure = if origin.scheme == "https" { Some(tls) } else { None }
  let conn = @tcp.dial(origin.host, port=origin.port, tls?=secure)
  guard conn.alpn() is Some("h2") else { return H1(conn, reused=false) }
  // Another request may have dialled the same origin meanwhile; one HTTP/2 connection is enough.
  if self.h2.get(key) is Some(other) && !other.dead {
    conn.close()
    return H2(other, reused=true)
  }
  let h2 = H2::new(conn)
  self.h2[key] = h2
  H2(h2, reused=false)
}

///|
/// Drop an HTTP/2 connection that has failed or been told to go away.
fn Pool::forget(self : Pool, origin : Origin, h2 : H2) -> Unit {
  h2.dead = true
  let key = origin.key()
  if self.h2.get(key) is Some(kept) && physical_equal(kept, h2) {
    self.h2.remove(key)
  }
  h2.conn.close()
}

///|
/// Keep a connection for the next request to its origin, or close it when enough are kept.
fn Pool::checkin(self : Pool, origin : Origin, conn : @tcp.Conn) -> Unit {
  let key = origin.key()
  let conns = match self.idle.get(key) {
    Some(conns) => conns
    None => {
      let conns = []
      self.idle[key] = conns
      conns
    }
  }
  if conns.length() < self.keep {
    conns.push(conn)
  } else {
    conn.close()
  }
}

///|
fn Pool::close(self : Pool) -> Unit {
  for _, conns in self.idle {
    for conn in conns {
      conn.close()
    }
  }
  for _, h2 in self.h2 {
    h2.conn.close()
  }
  self.idle.clear()
  self.h2.clear()
}
