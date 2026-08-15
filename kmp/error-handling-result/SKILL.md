---
name: error-handling-result
description: Typed error handling in Kotlin/KMP shared code - kotlin.Result and runCatching, modeling outcomes with sealed result types (sealed interface with Success/Failure), and Arrow's Either, the either {} builder, and the Raise DSL (raise, bind, ensure, recover, context(Raise<E>)). Use when designing how shared code reports failures (network, parsing, validation), choosing between exceptions, Result, sealed types, or Arrow, or surfacing errors across the KMP boundary to Swift. For coroutine cancellation and exception handling use android-skills:kotlin-coroutines; for surfacing results to iOS use kmp-ios-integration; for model validation use shared-models.
---

# Typed Error Handling (Kotlin / KMP)

## Overview

In shared KMP code, prefer **modeling expected failures as values** over throwing across layers — it forces callers to handle them and crosses the iOS boundary cleanly. Three idiomatic tiers: `kotlin.Result`, **sealed result types**, and **Arrow** (`Either`/`Raise`).

## When to use

- Designing how a repository or use case reports failure
- Network / parse / validation outcomes
- Deciding between exceptions, Result, sealed types, or Arrow
- Surfacing errors to Swift across the KMP boundary

## Decision

| Situation | Use |
|---|---|
| One-off wrap of a throwing call | `runCatching { }` → `kotlin.Result` |
| A domain with named, exhaustive error cases | sealed result type |
| Functional composition, short-circuit, no boxing | Arrow `Either` / `Raise` |
| Truly unexpected / programmer error | throw (don't model it) |

## Sealed result type (most KMP-friendly)

```kotlin
sealed interface LoadResult<out T> {
    data class Success<T>(val data: T) : LoadResult<T>
    data class Failure(val error: AppError) : LoadResult<Nothing>
}

enum class AppError { Network, NotFound, Unauthorized, Unknown }

when (val r = repo.load()) {
    is LoadResult.Success -> show(r.data)
    is LoadResult.Failure -> handle(r.error)   // compiler enforces exhaustiveness
}
```

## kotlin.Result

```kotlin
val result: Result<User> = runCatching { api.fetchUser(id) }
result.map { it.toUiModel() }.getOrElse { e -> fallback(e) }
```

⚠️ `runCatching` also catches `CancellationException` — inside coroutines, rethrow it (see kotlin-coroutines).

## Arrow Either + Raise

```kotlin
// build.gradle.kts: implementation("io.arrow-kt:arrow-core:<v>")
fun parsePort(s: String): Either<AppError, Int> = either {
    val n = s.toIntOrNull() ?: raise(AppError.Unknown)   // short-circuits
    ensure(n in 1..65535) { AppError.Unknown }
    n
}

val config: Either<AppError, Config> = either {
    val port = parsePort(raw).bind()                     // unwrap or short-circuit
    Config(port)
}
```

## Common mistakes

| Mistake | Fix |
|---|---|
| Swallowing `CancellationException` in `runCatching` | Rethrow it inside coroutines |
| Throwing across module boundaries | Return a sealed / `Either` result instead |
| Stringly-typed errors | Model an `AppError` sealed type or enum |
| Exposing `kotlin.Result` / `Either` directly to Swift | Map to a plain sealed type/value SKIE can bridge (see kmp-ios-integration) |

## See also

- Coroutine cancellation & exception handling: `android-skills:kotlin-coroutines`
- Surfacing results to Swift: `kmp-ios-integration`
- Validation in shared models: `shared-models`
