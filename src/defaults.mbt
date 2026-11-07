// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// How long a request may take when nothing else is said, in milliseconds: httpx's 5 seconds.
pub let timeout : Int32 = 5000

///|
/// How many redirects are followed when nothing else is said: reqwest's and requests' 10.
///
/// A host that hands the redirect to its own stack follows as many as it allows; this is the
/// number requests say.
pub let redirects : Int32 = 10
