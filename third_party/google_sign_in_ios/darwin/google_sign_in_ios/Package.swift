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
    // NOTE: GoogleSignIn-iOS 10 is required for Firebase 13 SPM compatibility:
    // it widens the GTMSessionFetcher range to 4.x/5.x, while GoogleSignIn 9.x
    // pins <4.0 and cannot resolve alongside firebase-ios-sdk 13. App targets
    // iOS 16, so the iOS 15/macOS 12 floors GoogleSignIn 10 introduces are fine.
    .package(
      url: "https://github.com/google/GoogleSignIn-iOS.git",
      from: "10.0.0")
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
