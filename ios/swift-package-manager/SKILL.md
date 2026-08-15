---
name: swift-package-manager
description: Swift Package Manager (SPM) for iOS/Swift dependencies - the Package.swift manifest (swift-tools-version, PackageDescription), declaring dependencies with version rules (from, upToNextMinor, exact, ranges, branch/revision), defining targets and products (library/executable), test targets, bundling resources via .process/.copy and Bundle.module, local path packages, and adding packages in Xcode. Use when adding a Swift dependency, creating a reusable Swift package or module, configuring Package.swift, or distributing a KMP XCFramework via SPM. For consuming a KMP shared module (XCFramework/CocoaPods/KMMBridge) use kmp-ios-integration; for testing a package use ios-testing.
---

# Swift Package Manager (SPM)

## Overview

SPM is Apple's dependency manager. A package is defined by a `Package.swift` **manifest** using the `PackageDescription` API: it declares `dependencies`, `targets` (build units), and `products` (what is exported for others to use).

## When to use

- Adding a Swift dependency to an iOS app
- Extracting reusable code into a local Swift package/module
- Configuring `Package.swift`
- Distributing a KMP `XCFramework` via SPM (see kmp-ios-integration)

## Package.swift

```swift
// swift-tools-version: 6.0          ← must be the very first line
import PackageDescription

let package = Package(
    name: "Networking",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "Networking", targets: ["Networking"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "Networking",
            dependencies: [
                .product(name: "Collections", package: "swift-collections"),
            ],
            resources: [.process("Resources")]        // asset catalogs/xib auto; others explicit
        ),
        .testTarget(name: "NetworkingTests", dependencies: ["Networking"]),
    ]
)
```

## Version rules

| Rule | Meaning |
|---|---|
| `from: "1.2.0"` | >= 1.2.0, < 2.0.0 (next major) |
| `.upToNextMinor(from: "1.2.0")` | >= 1.2.0, < 1.3.0 |
| `"1.2.0"..<"1.5.0"` | explicit range |
| `.exact("1.2.0")` | pinned |
| `branch: "main"` / `revision: "<sha>"` | track a branch/commit |

## Adding in Xcode / local packages

File → Add Package Dependencies → paste the repo URL → pick a version rule → add the product to your app target. Local package: `.package(path: "../Networking")`.

## Resources

```swift
resources: [
    .process("Media"),       // SPM optimizes (asset catalogs, etc.)
    .copy("config.json"),    // copied verbatim
]
// access inside the package:
let url = Bundle.module.url(forResource: "config", withExtension: "json")
```

## Common mistakes

| Mistake | Fix |
|---|---|
| Missing `swift-tools-version` line | Required as the very first line of `Package.swift` |
| Code in a target not usable | Export it via `products` (`.library`) |
| `Bundle.main` for package resources | Use `Bundle.module` inside a package |
| Resource file not bundled | Declare it under `resources:` (`.process` / `.copy`) |
| API unavailable at runtime | Set `platforms: [.iOS(.v17)]` to match the APIs you use |

## See also

- Consuming a KMP shared module (XCFramework / CocoaPods / KMMBridge): `kmp-ios-integration`
- Testing a Swift package: `ios-testing`
