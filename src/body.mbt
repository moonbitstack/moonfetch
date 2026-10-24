// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A request body. One value, so a request cannot carry two bodies for the library to choose
/// between.
pub(all) enum Body {
  Empty
  Text(String)
  Bytes(Bytes)
  Json(Json)
  /// `application/x-www-form-urlencoded`, in the order given.
  Form(Array[(String, String)])
} derive(Eq, Debug)

///|
pub extend Body with Eq::{equal, not_equal}

///|
pub extend Body with Debug::{to_repr}
