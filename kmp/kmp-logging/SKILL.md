---
name: kmp-logging
description: Multiplatform logging in Kotlin Multiplatform with Kermit (co.touchlab:kermit:2.2.0). Use when adding logging to shared code - the global Logger, severity levels (v/d/i/w/e/a), Logger.withTag for per-class tags, configuring LogWriters and minSeverity, building a custom Logger with StaticConfig, and routing warnings/errors to Crashlytics or Bugsnag. Kermit writes to Logcat on Android and OSLog on iOS automatically; Napier is a lighter alternative. For Android-only Logcat/ADB/ANR debugging use android-skills:android-debugging; for analytics events (not logs) use analytics-patterns.
---

# KMP Logging (Kermit)

## Overview

**Kermit** (Touchlab) is the standard KMP logging library — log from `commonMain` and it writes to **Logcat** on Android and **OSLog** on iOS automatically (console on JS). Current version **2.0.7**. Logs flow through composable `LogWriter`s, so you can also send them to Crashlytics/Bugsnag.

## When to use

- Logging from shared code (`commonMain`)
- Tagged loggers per class/feature
- Sending warnings/errors to crash reporting
- Controlling verbosity per build (`minSeverity`)

## Dependency

```kotlin
commonMain.dependencies {
    implementation("co.touchlab:kermit:2.2.0")
    // implementation("co.touchlab:kermit-crashlytics:2.0.7") // optional
}
```

## Usage

```kotlin
// Global logger — lambda message is only built if it will actually be logged
Logger.i { "App started" }
Logger.e(throwable) { "Failed to load user $id" }

// Tagged logger per class
class UserRepository {
    private val log = Logger.withTag("UserRepository")
    fun load() { log.d { "loading…" } }
}
```

Severities, low → high: `v` `d` `i` `w` `e` `a`.

## Configure writers + severity (once, at startup)

```kotlin
Logger.setMinSeverity(if (isDebug) Severity.Verbose else Severity.Warn)
Logger.setLogWriters(platformLogWriter(), CrashlyticsLogWriter())

// or a fully custom instance:
val log = Logger(
    config = StaticConfig(
        minSeverity = Severity.Info,
        logWriterList = listOf(platformLogWriter()),
    ),
    tag = "MyApp",
)
```

## Common mistakes

| Mistake | Fix |
|---|---|
| String concatenation in hot log paths | Use the lambda form `{ "x=$x" }` — skipped below `minSeverity` |
| Same verbosity in release | Raise `minSeverity` for release builds |
| Expecting iOS logs in Logcat | iOS writes to **OSLog** (Console.app / Xcode), not Logcat |
| Crash logs not appearing | Add `CrashlyticsLogWriter` to the writer list |

## See also

- Android Logcat / ADB / ANR debugging: `android-skills:android-debugging`
- Analytics events (distinct from logs): `analytics-patterns`
