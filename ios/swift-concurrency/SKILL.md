---
name: swift-concurrency
description: Modern Swift Concurrency on iOS - async/await, structured concurrency, Task and Task.detached, actor and @MainActor isolation, Sendable and Swift 6 strict concurrency, AsyncSequence/AsyncStream, TaskGroup, async let, and bridging callbacks with withCheckedContinuation. Use when writing async iOS code, fixing data races or off-main-thread UI updates, parallelizing work, wrapping delegate/completion-handler APIs, or consuming Kotlin suspend/Flow exposed as Swift async. For reactive Publisher/subscriber pipelines use combine-framework; for SwiftUI state use swiftui-observation; for the KMP bridge use kmp-ios-integration.
---

# Swift Concurrency

## Overview

Structured concurrency built on `async/await`. The compiler enforces isolation (`actor`, `@MainActor`) and, under Swift 6 strict concurrency, data-race safety via `Sendable`. Prefer this over GCD/`DispatchQueue` for new code.

## When to use

- Async iOS work: network, disk, or shared-KMP calls
- Updating UI safely from background work (`@MainActor`)
- Parallel work (`async let`, `TaskGroup`)
- Bridging callback/delegate APIs into `async` (`withCheckedContinuation`)
- Compiler errors like "call to main actor-isolated … in a synchronous nonisolated context" or `Sendable` warnings
- Consuming Kotlin `suspend`/`Flow` surfaced as Swift `async` (see kmp-ios-integration)

## Quick reference

| Need | Use |
|---|---|
| Run async work from sync code | `Task { await … }` |
| Main-thread isolation | `@MainActor` on type/func/closure |
| Parallel children, fixed count | `async let a = …; async let b = …; let (x, y) = await (a, b)` |
| Parallel children, dynamic | `withThrowingTaskGroup` |
| Serialize mutable state (no locks) | `actor` |
| Stream of values over time | `AsyncStream` / `AsyncSequence` |
| Wrap a completion-handler API | `withCheckedThrowingContinuation` |
| Opt a member out of actor isolation | `nonisolated` |

## Example — actor + @MainActor + continuation

```swift
actor ImageCache {                         // serialized state, no manual locks
    private var store: [URL: Data] = [:]
    func data(for url: URL) -> Data? { store[url] }
    func insert(_ data: Data, for url: URL) { store[url] = data }
}

@MainActor                                  // all UI state mutates on the main thread
@Observable final class FeedModel {
    var items: [Item] = []

    func load() async throws {
        async let items = api.fetchItems()  // these two run in parallel
        async let promos = api.fetchPromos()
        self.items = try await merge(items, promos)   // already on the main actor
    }
}

// Bridge a delegate/callback API into async/await
func currentLocation() async throws -> CLLocation {
    try await withCheckedThrowingContinuation { continuation in
        locationManager.requestLocation { result in
            continuation.resume(with: result)   // resume EXACTLY once, on every path
        }
    }
}
```

## Common mistakes

| Mistake | Fix |
|---|---|
| Heavy CPU work inside `Task {}` on the main actor | Use `Task.detached` or a background `actor` |
| Updating UI off the main thread | Annotate the model/view code `@MainActor` |
| Resuming a continuation twice or never | Resume exactly once on every path (incl. errors) |
| `Task {}` strongly capturing `self` in a view | Use the structured `.task {}` modifier or `[weak self]` |
| Assuming an `actor` is reentrancy-safe across `await` | State can change at suspension points — re-check invariants after `await` |
| Swift 6 `Sendable` errors | Make captured types `Sendable`, or isolate them to an actor |

## See also

- Reactive Publisher/subscriber pipelines: `combine-framework`
- SwiftUI state with `@Observable` (`@MainActor`): `swiftui-observation`
- Consuming KMP `suspend`/`Flow` as Swift async: `kmp-ios-integration`
