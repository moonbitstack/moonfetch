// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A connection to an origin, in whichever version ALPN settled on.
priv enum Link {
  H1(@tcp.Conn, reused~ : Bool)
  H2(H2, reused~ : Bool)
  H3(H3, reused~ : Bool)
}

///|
/// Idle HTTP/1.1 connections, a few per origin, and one HTTP/2 connection per origin, which
/// carries every request to it. Both maps are keyed by the origin.
priv struct Pool {
  idle : Map[String, Array[@tcp.Conn]]
  h2 : Map[String, H2]
  h3 : Map[String, H3]
  /// Origins whose QUIC handshake failed: they are spoken to over TCP from then on.
  no_h3 : Set[String]
  keep : Int32
  /// One dial at a time: without it a hundred requests that start together open a hundred
  /// connections and throw all but one away.
  dial : @async.Mutex
}

///|
fn Pool::new(keep : Int32) -> Pool {
  {
    idle: Map([]),
    h2: Map([]),
    h3: Map([]),
    no_h3: Set([]),
    keep,
    dial: @async.Mutex(),
  }
}

///|
/// The HTTP/2 connection for an origin, when it can still take work.
fn Pool::live(self : Pool, key : String) -> H2? {
  match self.h2.get(key) {
    Some(h2) if !h2.dead && !h2.going => Some(h2)
    Some(h2) => {
      self.forget(key, h2)
      None
    }
    None => None
  }
}

///|
fn Pool::keep_h2(self : Pool, key : String, h2 : H2) -> Unit {
  self.h2[key] = h2
}

///|
/// The HTTP/3 connection for an origin, when it can still take work.
fn Pool::live_h3(self : Pool, key : String) -> H3? {
  match self.h3.get(key) {
    Some(h3) if h3.live() => Some(h3)
    Some(h3) => {
      h3.close()
      self.h3.remove(key)
      None
    }
    None => None
  }
}

///|
fn Pool::keep_h3(self : Pool, key : String, h3 : H3) -> Unit {
  self.h3[key] = h3
}

///|
/// Drop an HTTP/3 connection that has failed or been told to go away, and stop asking this
/// origin for another.
fn Pool::forget_h3(self : Pool, key : String, h3 : H3) -> Unit {
  h3.close()
  self.no_h3.add(key)
  if self.h3.get(key) is Some(kept) && physical_equal(kept, h3) {
    self.h3.remove(key)
  }
}

///|
/// Note that an origin does not answer over QUIC, so that every later request to it goes over
/// TCP straight away.
fn Pool::refuse_h3(self : Pool, key : String) -> Unit {
  self.no_h3.add(key)
}

///|
fn Pool::tried_h3(self : Pool, key : String) -> Bool {
  self.no_h3.contains(key)
}

///|
/// Take an idle connection for the origin, or `None`.
fn Pool::take(self : Pool, key : String) -> @tcp.Conn? {
  match self.idle.get(key) {
    Some(conns) => conns.pop()
    None => None
  }
}

///|
/// Drop an HTTP/2 connection that has failed or been told to go away.
fn Pool::forget(self : Pool, key : String, h2 : H2) -> Unit {
  h2.dead = true
  if self.h2.get(key) is Some(kept) && physical_equal(kept, h2) {
    self.h2.remove(key)
  }
  h2.conn.close()
}

///|
/// Keep a connection for the next request to its origin, or close it when enough are kept.
fn Pool::checkin(self : Pool, key : String, conn : @tcp.Conn) -> Unit {
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
  for _, h3 in self.h3 {
    h3.close()
  }
  self.idle.clear()
  self.h2.clear()
  self.h3.clear()
}
