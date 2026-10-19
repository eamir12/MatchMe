// swift-tools-version: 5.9

// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import PackageDescription

let package = Package(
  name: "google_sign_in_ios",
  platforms: [
    .iOS("15.0"),
    .macOS("12.0"),
  ],
  products: [
    .library(name: "google-sign-in-ios", targets: ["google_sign_in_ios"])
  ],
  dependencies: [
    // NOTE: Firebase 13 needs GTMSessionFetcher 4.x/5.x and AppCheckCore 12.x.
    // GoogleSignIn 10.0.0 already widens GTMSessionFetcher (9.x pins <4.0) but
    // still caps AppCheckCore at 11.x; upstream main fixes that in commit
    // 4ce331c ("[App Check] Add SPM AppCheckCore 12.x support"), which is not
    // tagged yet. Pinned by revision for reproducible builds.
    .package(
      url: "https://github.com/google/GoogleSignIn-iOS.git",
      revision: "4ce331c226c24cfee688b31e9c3731cc5c5e2862")
  ],
  targets: [
    .target(
      name: "google_sign_in_ios",
      dependencies: [
        .product(name: "GoogleSignIn", package: "GoogleSignIn-iOS")
      ],
      resources: [
        .process("Resources")
      ]
    )
  ]
)
