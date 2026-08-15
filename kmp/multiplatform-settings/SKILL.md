---
name: multiplatform-settings
description: Key-value persistence in Kotlin Multiplatform with the multiplatform-settings library (com.russhwolf:multiplatform-settings:1.3.0). Use when storing simple preferences, flags, or tokens in shared code - the Settings and ObservableSettings interfaces, typed get/put (getInt, putString, getBooleanOrNull), property delegates (by settings.int()), the no-arg Settings() factory, platform factories (SharedPreferencesSettings on Android, NSUserDefaultsSettings on Apple), and reactive FlowSettings/getIntFlow via multiplatform-settings-coroutines. For a shared relational database use sqldelight-patterns; for Android-only DataStore/Room use room-patterns; for secrets use mobile-security.
---

# Multiplatform Settings (key-value persistence)

## Overview

`multiplatform-settings` (russhwolf) is the KMP equivalent of SharedPreferences / NSUserDefaults — simple typed key-value storage from `commonMain`. Current version **1.3.0**. The `Settings` interface wraps `SharedPreferences` on Android and `NSUserDefaults` on Apple, plus `localStorage` on JS.

## When to use

- Storing small preferences, flags, or tokens in shared code
- Reactive reads of a setting (`FlowSettings`)
- NOT for structured/relational data → use `sqldelight-patterns`

## Dependencies

```kotlin
commonMain.dependencies {
    implementation("com.russhwolf:multiplatform-settings:1.3.0")
    implementation("com.russhwolf:multiplatform-settings-coroutines:1.3.0") // Flow support
    // implementation("com.russhwolf:multiplatform-settings-no-arg:1.3.0")  // Settings() factory
}
```

## Creating a Settings instance

```kotlin
// Shared code takes a Settings (inject it — see kmp-di)
class Prefs(private val settings: Settings) { /* ... */ }

// Android
val settings: Settings = SharedPreferencesSettings(sharedPreferences)
// Apple
val settings: Settings = NSUserDefaultsSettings(NSUserDefaults.standardUserDefaults)
// No-arg (platform defaults) — needs multiplatform-settings-no-arg
val settings: Settings = Settings()
```

## Typed access & delegates

```kotlin
settings.putString("token", t)
val token: String? = settings.getStringOrNull("token")
val launches: Int   = settings.getInt("launches", defaultValue = 0)

// Property delegate (key defaults to the property name)
var darkMode: Boolean by settings.boolean("dark_mode", false)
```

## Reactive (FlowSettings)

Reactive reads require an **`ObservableSettings`** — `SharedPreferencesSettings` (Android) and `NSUserDefaultsSettings` (Apple) implement it; the bare no-arg `Settings()` does not guarantee observability. Build an `ObservableSettings` and use the typed `*Flow` extensions (from `multiplatform-settings-coroutines`):

```kotlin
val observable: ObservableSettings = SharedPreferencesSettings(prefs) // or NSUserDefaultsSettings(...)

val darkModeFlow: Flow<Boolean> = observable.getBooleanFlow("dark_mode", false)
val launchesFlow: Flow<Int>     = observable.getIntFlow("launches", 0)

// or the full coroutine API:
val flowSettings: FlowSettings = observable.toFlowSettings()
val tokenFlow: Flow<String?> = flowSettings.getStringOrNullFlow("token")
```

## Common mistakes

| Mistake | Fix |
|---|---|
| Expecting listeners from a plain `Settings` | Use/cast to `ObservableSettings` for flows and listeners |
| Storing large or structured data | Use SQLDelight (`sqldelight-patterns`) |
| Leaking a `SettingsListener` | Call `deactivate()` on the returned listener when done |
| Putting secrets in plain prefs | Not encrypted — use platform secure storage (`mobile-security`) |

## See also

- Shared relational storage: `sqldelight-patterns`
- Injecting the `Settings` instance: `kmp-di`
- Android-only DataStore/Room: `room-patterns`
