---
name: feature-builder
description: End-to-end workflow to take a mobile feature from idea to verified code through six phases — plan, implement by layer, test, build-fix, review, verify. Use when building a non-trivial Android/iOS/KMP feature and you want a structured, repeatable path. Sequences the real skills and agents available here; it does not invoke an external pipeline.
---

# Feature Builder (workflow)

A structured 6-phase path for building a mobile feature end to end. This is a **workflow guide** — it sequences the real skills/agents you already have; it does **not** call external `/feature-*` pipeline commands.

> **Platform auto-detect:** `shared/src/commonMain/` → **KMP** · `*.xcodeproj` / `*.xcworkspace` → **iOS** · root `build.gradle(.kts)` with an android block → **Android**. Ambiguous → ask.

## The six phases

| # | Phase | Do it with |
|---|---|---|
| 1 | **Plan** | `superpowers:brainstorming` → `superpowers:writing-plans` (or the `Plan` agent). Output: module breakdown, file list, task order. |
| 2 | **Implement (by layer)** | Build in dependency order, pulling the matching library skill per layer (below). Drive with `superpowers:test-driven-development`. |
| 3 | **Test** | Unit + UI + E2E. `mobile-testing` (Android/JVM) · `ios-testing` (iOS) · depth: `android-skills:android-tdd`. |
| 4 | **Build & fix** | Compile + run tests, fix in a loop (cap ~5 iterations, then escalate). Debug via `android-skills:android-debugging`. |
| 5 | **Review** | `superpowers:requesting-code-review`, or the `feature-dev:code-reviewer` / `pr-review-toolkit` agents. Block on security & correctness. |
| 6 | **Verify** | Run the tests for real, confirm coverage/behaviour, re-run to catch flakiness. `superpowers:verification-before-completion`. |

## Phase 2 — implementation order (layer by layer)

```
domain  →  (network ∥ ui)  →  data  →  wiring
```

- **domain** — models, repository interfaces, use cases returning a typed result (`error-handling-result`).
- **network** — API + DTOs (`kmp-networking` / `ktor-patterns`). **ui** — screens, ViewModels, state (`jetpack-compose`, `swiftui-patterns`, `swiftui-observation`, `mvi-architecture`). No mutual dependency → do them together.
- **data** — repository impl, mappers, local cache (`kmp-repositories`, `sqldelight-patterns` / `room-patterns` / `swiftdata`).
- **wiring** — DI (`kmp-di` / `android-di-koin`), navigation (`navigation`), manifest/permissions.

## Per-platform layer map

| Layer | Android | iOS | KMP |
|---|---|---|---|
| Domain | Kotlin data classes | Swift structs | commonMain models (`shared-models`) |
| Network | Retrofit / Ktor | URLSession | Ktor shared (`kmp-networking`) |
| UI | Compose + ViewModel | SwiftUI + `@Observable` | Compose MP / SwiftUI |
| Data | Room / DataStore | SwiftData / Core Data | SQLDelight |
| Wiring | Koin/Hilt + Navigation | container + NavigationStack | Koin + shared nav |

## Build & verify commands

| | Compile | Unit | UI / Instrumented |
|---|---|---|---|
| Android | `./gradlew assembleDebug` | `./gradlew test` | `./gradlew connectedAndroidTest` |
| iOS | `xcodebuild build` | `xcodebuild test` | `xcodebuild test -testPlan UITests` |
| KMP | `./gradlew build` | `./gradlew allTests` | platform-specific |

## Acceptance criteria

- Builds clean on the target platform(s).
- Unit ≥ ~80% on new code · UI covers each screen + key interactions · E2E covers happy path + top error paths.
- Code review: no unresolved critical/high findings.
- Tests pass reliably (re-run) before you call it done.

---

*This is the lean, working version. The original marketplace skill specified an automated `/feature-build` pipeline (named sub-agents, `.omc/` state files, and an instinct / mobile-memory learning layer). That orchestration isn't installed here, and its learning/memory layer is the meta-system you opted out of — so it was removed. Restore the original from the `everything-claude-code-mobile` marketplace if you ever wire that pipeline up.*
