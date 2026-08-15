---
name: compose-resources
description: Compose Multiplatform resources - the compose.components.resources dependency, the composeResources/ directory (drawable, font, values, files) with qualifiers (values-de, drawable-dark, *-mdpi), the generated type-safe Res class, and accessing them with painterResource(Res.drawable.x), stringResource(Res.string.x), Font(Res.font.x), pluralStringResource, and Res.readBytes. Use when adding images, strings, fonts, or files to shared Compose Multiplatform UI in commonMain, configuring the Res package, or loading resources across Android/iOS/desktop/web. Requires Kotlin 2.0+ and Compose Multiplatform 1.6+. For general Compose/CMP UI use android-skills:compose; for network image loading use image-loading; for localization strategy use localization-patterns.
---

# Compose Multiplatform Resources

## Overview

Shared images, strings, fonts, and files for Compose Multiplatform live in a `composeResources/` directory. The Gradle plugin scans it and generates a **type-safe `Res` object** (`Res.drawable.*`, `Res.string.*`, `Res.font.*`) usable from `commonMain`. Requires Kotlin 2.0+ and Compose Multiplatform 1.6+ (1.6.10+ to include resources in published artifacts).

## When to use

- Adding drawables/strings/fonts/files to shared CMP UI
- `Res.drawable` / `Res.string` not resolving
- Per-locale, per-theme, or per-density resource variants
- Loading raw files across platforms (`Res.readBytes`)

## Setup

```kotlin
// build.gradle.kts (module with shared UI)
kotlin {
    sourceSets {
        commonMain.dependencies {
            implementation(compose.components.resources)
        }
    }
}
```

## Directory layout (under a source set, usually commonMain)

```
commonMain/composeResources/
├── drawable/   ic_logo.png, banner.xml   (PNG/JPEG/WebP/bitmap or Android XML vector)
├── font/       inter_regular.ttf
├── values/     strings.xml               (<string name="app_name">…</string>)
└── files/      config.json               (any folder hierarchy)
```

Qualifiers via hyphen (priority order language → theme → density):
`values-de/`, `drawable-dark/`, `drawable-en-rUS-mdpi/`.

## Usage

```kotlin
import myapp.shared.generated.resources.Res          // generated package
import myapp.shared.generated.resources.ic_logo
import myapp.shared.generated.resources.app_name

Image(painterResource(Res.drawable.ic_logo), contentDescription = null)
Text(stringResource(Res.string.app_name))
Text(stringResource(Res.string.greeting, userName))             // with args
Text(pluralStringResource(Res.plurals.items, count, count))     // plurals
val family = FontFamily(Font(Res.font.inter_regular))
val bytes: ByteArray = Res.readBytes("files/config.json")        // suspend
```

## Custom Res package (optional)

```kotlin
compose.resources {
    publicResClass = true
    packageOfResClass = "com.example.shared.resources"
    generateResClass = auto
}
```

## Common mistakes

| Mistake | Fix |
|---|---|
| `Res` import unresolved | Build once to generate it; import from `<pkg>.generated.resources.Res` |
| Strings placed outside `values/*.xml` | They must be XML `<string>` entries under `values/` |
| Using Android `R.drawable` in commonMain | Use `Res.drawable.*` instead |
| `Res.readBytes` called off a coroutine | It is `suspend` — call from a coroutine / `LaunchedEffect` |
| Resources missing in a published library | Need Compose Multiplatform 1.6.10+ |

## See also

- General Compose / CMP UI: `android-skills:compose`
- Network image loading (Coil): `image-loading` / `android-skills:coil-compose`
- Localization strategy (plurals, RTL, locale): `localization-patterns`
