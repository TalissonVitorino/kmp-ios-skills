# kmp-ios-skills

**108 agent skills for Kotlin Multiplatform and iOS development.** Built for a KMP + iOS stack where Android is a KMP target — not the other way around.

Every skill is a plain `SKILL.md`: procedural knowledge an agent loads *only when the task calls for it*. Works with Claude Code, Codex, Cursor, Copilot, Gemini and [75+ other agents](https://github.com/vercel-labs/skills#supported-agents) via the `skills` CLI.

```bash
# everything (108 skills)
npx skills add TalissonVitorino/kmp-ios-skills

# just one area
npx skills add TalissonVitorino/kmp-ios-skills/ios
npx skills add TalissonVitorino/kmp-ios-skills/kmp
npx skills add TalissonVitorino/kmp-ios-skills/android
npx skills add TalissonVitorino/kmp-ios-skills/cross-platform
npx skills add TalissonVitorino/kmp-ios-skills/workflow

# a single skill
npx skills add TalissonVitorino/kmp-ios-skills/ios/swiftui-expert-skill
```

| Folder | Skills | Covers |
|:---|---:|:---|
| [`ios/`](ios) | 48 | Swift, SwiftUI, Apple frameworks, security, on-device AI, profiling, App Store |
| [`kmp/`](kmp) | 15 | Shared layer, DI, Ktor, SQLDelight, iOS framework export, money |
| [`android/`](android) | 27 | Compose, Gradle/AGP, profiling, Play, CameraX, R8, credentials |
| [`cross-platform/`](cross-platform) | 14 | Navigation, architecture, security, a11y, i18n, offline-first |
| [`workflow/`](workflow) | 4 | Feature flow, checkpoints, commit hygiene, pre-merge verification |

Prefer per-area installs. Skill *descriptions* are always in the agent's context (that's how routing works) — installing all 108 costs ~8–10k tokens of permanent index. One area costs a fraction of that, and skill *bodies* only load when invoked.

---

## What's inside

### 🍎 `ios/` — Swift & SwiftUI

| Need | Skill |
|---|---|
| Swift language (optionals, generics, protocols) | `swift-patterns` |
| async/await, actors, TaskGroup | `swift-concurrency` |
| Swift 6.2 approachable concurrency migration | `swift-concurrency-6-2` |
| Reactive publisher/subscriber | `combine-framework` |
| **Review/refactor SwiftUI** — deprecated-API migration, Instruments `.trace` analysis | `swiftui-expert-skill` |
| Quick SwiftUI layout/nav/animation patterns | `swiftui-patterns` |
| SwiftUI state (`@Observable`, iOS 17+) | `swiftui-observation` |
| Bridge UIKit ↔ SwiftUI, migrate incrementally | `swiftui-uikit-interop` |
| Liquid Glass (iOS 26) | `liquid-glass` |
| Swift Package Manager dependencies | `swift-package-manager` |
| Choose/migrate app architecture (MV, MVVM, TCA, Clean) | `swift-architecture` |
| Name/label/document Swift APIs | `swift-api-design-guidelines` |
| iOS tests (XCTest, Swift Testing, XCUITest) | `ios-testing` |
| Protocol-based DI for testable Swift | `swift-protocol-di-testing` |

**Apple app-surface frameworks**

| Need | Skill |
|---|---|
| Widgets — Home/Lock Screen/StandBy/Control Center | `widgetkit` |
| Live Activities & Dynamic Island | `activitykit` |
| Siri/Shortcuts/Spotlight/Apple Intelligence actions | `app-intents` |
| In-app purchases & subscriptions (StoreKit 2) | `storekit` |
| Apple Pay + Wallet passes | `passkit` |
| Maps, annotations, geocoding, geofencing | `mapkit` |
| Photo picker, camera capture, AVFoundation | `photokit` |
| Contacts read/write | `contacts-framework` |
| Display/annotate/fill PDFs | `pdfkit` |
| Read/write NFC tags | `core-nfc` |
| VoIP calling, caller ID (CallKit + PushKit) | `callkit` |
| iCloud sync (CloudKit, CKSyncEngine) | `cloudkit` |
| App Clips — invocation URLs, codes, handoff | `app-clips` |
| In-app tips / feature discovery | `tipkit` |
| Embed web content in SwiftUI (iOS 26+) | `swiftui-webkit` |
| Background tasks (BGTaskScheduler) | `background-processing` |
| iOS 17+ persistence | `swiftdata` |
| Legacy persistence | `core-data` |

**Security, AI, formatting, tooling**

| Need | Skill |
|---|---|
| Keychain, biometrics, CryptoKit, Secure Enclave, MASVS | `swift-security` |
| Sign in with Apple, passkeys/WebAuthn, OAuth | `authentication` |
| Device legitimacy / anti-fraud (DeviceCheck, App Attest) | `device-integrity` |
| Wallet financial data — transactions/balances | `financekit` |
| Pick an on-device AI runtime (Foundation Models, Core ML, MLX) | `apple-on-device-ai` |
| Load & run a Core ML model | `coreml` |
| OCR, barcode/face detection, segmentation | `vision-framework` |
| Tokenize/tag/embeddings + translation | `natural-language` |
| Charts — bar/line/area/pie/3D | `swift-charts` |
| Locale-aware number/currency/date formatting | `swift-formatstyle` |
| Debug/profile (LLDB, Memory Graph, Instruments) | `debugging-instruments` |
| Production telemetry (MetricKit) | `metrickit` |
| Drive the Simulator via `simctl` | `ios-simulator` |
| Lint config & rollout (SwiftLint) | `swiftlint` |
| Pre-submission audit / rejection risk | `app-store-review` |
| Generate app-icon imagesets | `ios-icon-gen` |

### 🧩 `kmp/` — shared layer

| Need | Skill |
|---|---|
| KMP Gradle: targets, source sets, `kotlin {}` DSL | `kmp-build-setup` |
| expect/actual patterns | `expect-actual` |
| Ship the shared module to iOS (XCFramework, SKIE, suspend/Flow→Swift) | `kmp-ios-integration` |
| Shared `@Serializable` domain models | `shared-models` |
| Coroutines/Flow in shared code (iOS dispatchers) | `shared-coroutines` |
| Typed error handling (Result / sealed / Arrow) | `error-handling-result` |
| Multiplatform logging (Kermit) | `kmp-logging` |
| **Money/currency/decimal** — never-Double, banker's rounding, allocation | `kmp-money` |
| Shared DI consumed from iOS | `kmp-di` |
| Shared Ktor client (per-platform engines) | `kmp-networking` |
| Shared TLS/SPKI pinning (OkHttp + Darwin) | `kmp-tls-pinning` |
| Shared DB across Android + iOS | `sqldelight-patterns` |
| Repository pattern (shared) | `kmp-repositories` |
| Key-value prefs | `multiplatform-settings` |
| CMP resources (`Res.drawable`/`string`/`font`) | `compose-resources` |

### 🟩 `android/`

| Need | Skill |
|---|---|
| Compose UI patterns | `jetpack-compose` |
| Material 3 Expressive | `m3-expressive` |
| Adaptive layouts (WindowSizeClass, multi-pane) | `compose-adaptive` |
| Edge-to-edge / insets / system bars | `edge-to-edge` |
| Compose Styles API, design-system theming | `compose-theming-styles` |
| Image loading | `image-loading` |
| Kotlin coroutines/Flow | `coroutines-patterns` |
| Android Kotlin idioms | `android-patterns` |
| Koin DSL / scopes / qualifiers | `koin-patterns` |
| Android app Koin (module-per-layer, koinViewModel) | `android-di-koin` |
| Android Ktor/OkHttp client | `ktor-patterns` |
| Room | `room-patterns` |
| Android/JVM tests (JUnit5, MockK, Turbine, Compose UI) | `mobile-testing` |
| Gradle (version catalogs, modules) | `gradle-patterns` |
| Migrate to AGP 9 | `agp-9-upgrade` |
| Analyze/optimize R8 keep rules | `r8-analyzer` |
| CameraX (capture, recording lifecycle, ML Kit interop) | `camerax` |
| `android` CLI (projects, devices/AVDs, SDK, docs) | `android-cli` |
| End-to-end profiling — record traces/heap dumps + guided analysis | `android-profiler` |
| Query a Perfetto trace with SQL — quick standalone | `perfetto-sql` |
| Root-cause jank/latency/memory from an existing trace — quick standalone | `perfetto-trace-analysis` |
| Silent re-sign-in after device restore (Restore Credentials) | `restore-credentials` |
| OTP-less verified email sign-up (Credential Manager) | `verified-email` |
| Google Play Billing upgrade | `play-billing-upgrade` |
| Audit Intent security (redirection, exported components) | `android-intent-security` |
| Audit against Google Play policies | `play-policy-insights` |
| App/device integrity + root detection (Play Integrity) | `android-device-integrity` |

### 🔀 `cross-platform/`

| Need | Skill |
|---|---|
| Any navigation — Jetpack Nav / **Nav3** / Voyager · Decompose · SwiftUI | `navigation` |
| MVI / unidirectional state | `mvi-architecture` |
| Lifecycle / process death / SavedStateHandle | `app-lifecycle` |
| Offline-first sync / cache / conflict | `offline-first` |
| Pagination (Paging 3, cursor/offset) | `pagination-patterns` |
| Deep links (App Links / Universal Links) | `deep-linking` |
| Push (FCM / APNs) | `push-notifications` |
| Feature flags / remote config / A·B | `feature-flags` |
| Analytics events | `analytics-patterns` |
| Localization / i18n / RTL | `localization-patterns` |
| Accessibility (a11y, WCAG, dynamic type) | `accessibility-patterns` |
| CI/CD (GitHub Actions, Fastlane, signing) | `ci-cd-patterns` |
| Android secure storage, network config, biometrics | `mobile-security` |
| Session auto-lock, screen-capture protection | `mobile-session-security` |

### 🔁 `workflow/`

| Need | Skill |
|---|---|
| End-to-end feature (plan → architecture → code → test → verify) | `feature-builder` |
| Checkpoint / restore safety | `mobile-checkpoint` |
| Ship a branch: prove the suites ran (counts JUnit XML, not `BUILD SUCCESSFUL`), curate the history, push under the developer's own authorship | `prepare-merge-request` |
| Fix production issues from Sentry (needs the Sentry MCP) | `sentry-fix-issues` |

---

## How to use them well

- **One task = one skill.** Be specific so the right one triggers. Descriptions are deliberately disambiguated — "shared Koin DI consumed from iOS" routes to `kmp-di`, not to the three other DI skills.
- **Don't invoke "just in case."** Each invocation injects that skill's body into the context.
- **Depth lives in `references/`** — e.g. `cross-platform/navigation/references/` carries 23 Navigation 3 recipes, `ios/swiftui-expert-skill/references/` a full review tree with Instruments-trace scripts. Those load only when read.
- **Some descriptions point at `android-skills:`** — that's [rcosteira79/android-skills](https://github.com/rcosteira79/android-skills), a separate source-backed plugin. Where a skill here is the light version of a topic it covers in depth, the description says so. Install it alongside if you're Android-heavy.

Versions pinned in the skills (Ktor, AGP, Compose BOM, Kotlin, SQLDelight…) were verified at the time of writing — re-check before assuming they're current.

## Provenance & licenses

This repository is MIT. It bundles work from several sources, all under permissive licenses — see [NOTICE.md](NOTICE.md) for the full attribution.

- **34 skills written from scratch** and adversarially verified against Apple's official documentation (every API symbol checked by an independent pass): the iOS framework set, `swift-security`, `kmp-money`, `kmp-tls-pinning`, `android-device-integrity`, `mobile-session-security`.
- **Google's [android/skills](https://github.com/android/skills)** (Apache-2.0): `camerax`, `compose-theming-styles`, `perfetto-sql`, `perfetto-trace-analysis`, `android-cli`, `play-billing-upgrade`, `android-intent-security`, `play-policy-insights`, `compose-adaptive`, `edge-to-edge`, `r8-analyzer`, `agp-9-upgrade`, `android-profiler`, `restore-credentials`, `verified-email`, plus the Navigation 3 recipes inside `navigation`.
- **[avdlee/swiftui-agent-skill](https://github.com/avdlee/swiftui-agent-skill)** (MIT): `swiftui-expert-skill`.
- **[ahmed3elshaer/everything-claude-code-mobile](https://github.com/ahmed3elshaer/everything-claude-code-mobile)** (MIT): the cross-platform and Android pattern skills. Substantially reworked here: every one was audited against official documentation by an independent verification pass, which replaced hallucinated and dead APIs, corrected component signatures and version gates, and fixed samples that could not compile.
- **[affaan-m/everything-claude-code](https://github.com/affaan-m/everything-claude-code)** (MIT): `swift-concurrency-6-2`, `swift-protocol-di-testing`, `ios-icon-gen`.
- **[getsentry/sentry-skills](https://github.com/getsentry/sentry-skills)** (Apache-2.0): `sentry-fix-issues`.

## License

[MIT](LICENSE) © Talisson Vitorino. Bundled third-party skills keep their original licenses, listed in [NOTICE.md](NOTICE.md).
