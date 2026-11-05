// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Binary search a sorted rule list.
fn listed(rules : Array[String], key : String) -> Bool {
  let mut low = 0
  let mut high = rules.length() - 1
  while low <= high {
    let mid = (low + high) / 2
    let at = rules[mid]
    if at == key {
      return true
    }
    if at < key {
      low = mid + 1
    } else {
      high = mid - 1
    }
  }
  false
}

///|
/// Whether `host` is a public suffix: a name a registry hands out, under which anybody may
/// register. A single-label name counts, which keeps `localhost` and an internal `intranet`
/// from being a cookie domain.
///
/// The rules are the ICANN section of the Public Suffix List in `psl_data.mbt`; wildcards
/// (`*.ck`) and exceptions (`!www.ck`) are read as the list's algorithm reads them.
fn is_public_suffix(host : StringView) -> Bool {
  let text = host.to_owned()
  if listed(exception_suffixes, text) {
    return false
  }
  if listed(exact_suffixes, text) {
    return true
  }
  let labels = text.split(".").to_array()
  if labels.length() >= 2 {
    let tail = StringBuilder()
    for i in 1..<labels.length() {
      if i > 1 {
        tail.write_char('.')
      }
      tail.write_string(labels[i].to_owned())
    }
    if listed(wild_suffixes, tail.to_string()) {
      return true
    }
  }
  labels.length() == 1
}
