---
name: kmp-build-setup
description: Configuring the Kotlin Multiplatform Gradle build - the kotlin {} DSL, declaring targets (androidTarget, iosArm64, iosSimulatorArm64, jvm, js, wasmJs), the default source-set hierarchy template (commonMain/androidMain/iosMain, applyDefaultHierarchyTemplate), adding dependencies per source set, the plugins block with Kotlin/AGP versions, and the android {} config for the Android target. Use when setting up or fixing a KMP module's build.gradle.kts, adding a target or source set, or resolving source-set and dependency wiring. For iOS framework export and SKIE use kmp-ios-integration; for Android build logic and convention plugins use android-skills:android-gradle-logic; for Compose Multiplatform resources use compose-resources.
---

# KMP Build Setup (Gradle)

## Overview

The Kotlin Multiplatform Gradle plugin's `kotlin {}` block declares **targets**; from the declared targets it generates a **source-set hierarchy** (`commonMain` → intermediate `iosMain` → leaf `iosArm64Main`) via the default hierarchy template. Shared code lives in `commonMain`, platform code in the platform source sets. Requires Kotlin 1.9.20+ (hierarchy template); current line is Kotlin 2.1.x.

## When to use

- New or broken `shared/build.gradle.kts`
- Adding a target (`iosArm64`, `jvm`, `js`, `wasmJs`) or a source set
- "source set not found" or dependency-wiring issues across commonMain/iosMain
- Configuring the `android {}` block for `androidTarget`

## Plugins + targets

```kotlin
plugins {
    kotlin("multiplatform") version "2.1.x"
    id("com.android.library") version "8.x"
}

kotlin {
    androidTarget()          // Android target
    iosArm64()               // real devices
    iosSimulatorArm64()      // Apple-silicon simulator
    iosX64()                 // Intel simulator (optional)

    // The default hierarchy template runs automatically.
    // Call explicitly only when you customize the hierarchy:
    // applyDefaultHierarchyTemplate()

    sourceSets {
        commonMain.dependencies {
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:<v>")
        }
        androidMain.dependencies { /* OkHttp, Android-only libs */ }
        iosMain.dependencies     { /* Darwin engine, Apple-only libs */ }
        commonTest.dependencies  { implementation(kotlin("test")) }
    }
}

android {
    namespace = "com.example.shared"
    compileSdk = 35
    defaultConfig { minSdk = 24 }
}
```

## Source-set hierarchy (auto-generated)

```
commonMain ─┬─ androidMain
            └─ iosMain ─┬─ iosArm64Main
                        ├─ iosSimulatorArm64Main
                        └─ iosX64Main
```

Declaring `iosArm64()` + `iosSimulatorArm64()` makes the plugin create the shared **`iosMain`** intermediate set automatically — put shared iOS `actual` code there, not in a single leaf set.

## Quick reference

| Need | Do |
|---|---|
| Add a target | call `iosArm64()`, `jvm()`, `js { browser() }`, `wasmJs()` in `kotlin {}` |
| Shared deps | `commonMain.dependencies { }` |
| Platform deps | `androidMain.dependencies { }` / `iosMain.dependencies { }` |
| Shared iOS `actual` code | put it in `iosMain` |
| Re-apply hierarchy template | `applyDefaultHierarchyTemplate()` |
| Export the iOS framework | see `kmp-ios-integration` |

## Common mistakes

| Mistake | Fix |
|---|---|
| Putting iOS `actual` only in `iosArm64Main` | Use `iosMain` so it covers all iOS targets |
| Manually creating `iosMain` with `getByName(...)` | The default template already provides it; just use `iosMain.dependencies {}` |
| Mismatched Kotlin vs Compose/AGP versions | Check the Compose Multiplatform & AGP compatibility matrix |
| `commonMain` referencing platform APIs | Move to a platform source set or use expect/actual |

## See also

- iOS framework export, XCFramework, SKIE: `kmp-ios-integration`
- Android build logic / convention plugins: `android-skills:android-gradle-logic`
- Compose Multiplatform resources config: `compose-resources`
- expect/actual boundaries: `expect-actual` / `android-skills:kmp-boundaries`
