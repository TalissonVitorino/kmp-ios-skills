---
name: kmp-ios-integration
description: Integrating a Kotlin Multiplatform shared module into an iOS/Xcode app. Use when exporting the shared framework (binaries.framework, XCFramework, baseName, isStatic), choosing distribution (direct framework with embedAndSign, the kotlin-cocoapods plugin, or Swift Package Manager / KMMBridge), and exposing Kotlin suspend functions and Flow to Swift as async/await and AsyncSequence via SKIE or KMP-NativeCoroutines. Covers calling shared code from Swift and Kotlin/Native threading. For general expect/actual boundary design use android-skills:kmp-boundaries; for the shared coroutine/Flow side use shared-coroutines; for the Swift async side use swift-concurrency.
---

# KMP → iOS Integration

## Overview

The KMP `shared` module compiles to a native Apple framework that the iOS app links against. Two things must be right: (1) **export** the framework from Gradle, and (2) **bridge** Kotlin `suspend`/`Flow` into idiomatic Swift `async`/`AsyncSequence`.

## When to use

- Wiring an iOS app to consume a KMP `shared` module
- `binaries.framework` / XCFramework export configuration
- Choosing CocoaPods vs Swift Package Manager vs a direct framework
- Kotlin `suspend`/`Flow` not callable nicely from Swift → SKIE / NativeCoroutines
- Errors like "framework not found", missing symbols, "embedAndSign", or a crash on launch from a non-embedded framework

## Framework export (shared/build.gradle.kts)

```kotlin
kotlin {
    listOf(iosArm64(), iosSimulatorArm64()).forEach { target ->
        target.binaries.framework {
            baseName = "Shared"   // becomes `import Shared` in Swift
            isStatic = true       // static linking — simplest for an app target
        }
    }
}
```

Build an XCFramework for binary distribution:
`./gradlew :shared:assembleSharedXCFramework`

## Distribution options

| Option | When | Setup |
|---|---|---|
| Direct framework + embedAndSign | Single repo; the app build also builds shared | Run `embedAndSignAppleFrameworkForXcode` in a Run Script build phase; set the framework to **Embed & Sign** |
| CocoaPods (`kotlin-cocoapods`) | You already use a Pods workflow | `cocoapods { framework { baseName = "Shared" } }` block, then `pod install` |
| SPM / KMMBridge | Ship a prebuilt binary to a separate iOS repo | XCFramework + `Package.swift` (KMMBridge automates publishing) |

## Exposing suspend/Flow to Swift — SKIE (recommended)

Plain Kotlin/Native exposes `suspend` as a completion-handler function and `Flow` as an opaque type. **SKIE** rewrites the generated Swift API so suspend becomes `async` and `Flow`/`StateFlow` become `AsyncSequence`:

```kotlin
// shared/build.gradle.kts
plugins { id("co.touchlab.skie") version "<latest>" }
```

```swift
import Shared

// suspend fun loadUser(id): User  ->  Swift async
let user = try await repository.loadUser(id: id)

// StateFlow<UiState>  ->  AsyncSequence
for await state in viewModel.uiState {
    self.state = state            // hop to @MainActor before touching UI
}
```

Alternative: **KMP-NativeCoroutines** (`@NativeCoroutines`) when you want async/await *or* Combine `Publisher` output.

## Calling shared code from Swift

```swift
import Shared
let greeting = Greeting().greet()        // plain function
let repo = SharedKoin().userRepository   // or resolve from the shared Koin graph (see kmp-di)
```

Kotlin/Native uses the new memory model (default since 1.7.20) — objects are freely shareable across threads, but **always update SwiftUI state on the main actor** after awaiting shared code.

## Common mistakes

| Mistake | Fix |
|---|---|
| `import Shared` fails | `baseName` must match the import name; clean & rebuild |
| Crash on launch (dyld) | Set the framework to **Embed & Sign**, not "Do Not Embed" |
| `suspend` shows up as `completionHandler:` in Swift | Add SKIE or KMP-NativeCoroutines |
| `Flow` not collectable in Swift | SKIE exposes it as `AsyncSequence`; iterate in a `Task` |
| UI updated off the main thread | Hop to `@MainActor` in Swift after `await` |
| XCFramework stale after Kotlin change | Re-run the assemble task; Xcode caches the binary |

## See also

- Shared coroutine/Flow design and dispatchers: `shared-coroutines`
- expect/actual and platform services: `android-skills:kmp-boundaries`
- Swift-side async/await, actors, continuations: `swift-concurrency`
- Shared DI consumed from Swift: `kmp-di`
