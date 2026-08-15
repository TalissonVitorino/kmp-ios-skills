# NOTICE

`kmp-ios-skills` is distributed under the [MIT License](LICENSE). It bundles skills adapted from several upstream projects, all under permissive licenses. Attribution follows, per skill.

## Apache License 2.0

Full license text: [`licenses/APACHE-2.0.txt`](licenses/APACHE-2.0.txt).

### [android/skills](https://github.com/android/skills) — Copyright Google LLC

Copied and, where noted in the skill body, adapted:

| Skill | Path |
|---|---|
| `agp-9-upgrade` | `android/agp-9-upgrade` |
| `android-cli` | `android/android-cli` |
| `android-intent-security` | `android/android-intent-security` |
| `camerax` | `android/camerax` |
| `compose-adaptive` | `android/compose-adaptive` |
| `compose-theming-styles` | `android/compose-theming-styles` |
| `edge-to-edge` | `android/edge-to-edge` |
| `perfetto-sql` | `android/perfetto-sql` |
| `perfetto-trace-analysis` | `android/perfetto-trace-analysis` |
| `play-billing-upgrade` | `android/play-billing-upgrade` |
| `play-policy-insights` | `android/play-policy-insights` |
| `r8-analyzer` | `android/r8-analyzer` |

The Navigation 3 section and the recipe tree under `cross-platform/navigation/references/` also derive from `android/skills`. That skill is a merge of three originals (Jetpack Navigation Compose, Navigation 3, and multiplatform navigation); only the Navigation 3 material is Google's.

Modified: two skills were renamed to avoid ambiguous identifiers inside a mixed library — the frontmatter `name` of `compose-theming-styles` was `styles`, and `play-billing-upgrade` was `play-billing-library-version-upgrade`. Content is otherwise unchanged.

Portions of the reference files reproduce documentation from developer.android.com, also under Apache 2.0 / CC BY 2.5 as published by Google.

### [getsentry/sentry-skills](https://github.com/getsentry/sentry-skills) — Copyright Functional Software, Inc. (Sentry)

| Skill | Path |
|---|---|
| `sentry-fix-issues` | `workflow/sentry-fix-issues` |

Modified: the parent-skill breadcrumb link and the `disable-model-invocation` flag were removed so the skill stands alone.

## MIT License

### [ahmed3elshaer/everything-claude-code-mobile](https://github.com/ahmed3elshaer/everything-claude-code-mobile)

The cross-platform and Android pattern skills derive from this project — among them `accessibility-patterns`, `analytics-patterns`, `android-patterns`, `app-lifecycle`, `ci-cd-patterns`, `combine-framework`, `core-data`, `coroutines-patterns`, `deep-linking`, `expect-actual`, `feature-builder`, `feature-flags`, `gradle-patterns`, `image-loading`, `jetpack-compose`, `kmp-build-setup`, `kmp-di`, `kmp-networking`, `kmp-repositories`, `koin-patterns`, `ktor-patterns`, `liquid-glass`, `localization-patterns`, `m3-expressive`, `mobile-checkpoint`, `mobile-security`, `mobile-testing`, `multiplatform-settings`, `mvi-architecture`, `offline-first`, `pagination-patterns`, `push-notifications`, `room-patterns`, `shared-coroutines`, `shared-models`, `sqldelight-patterns`, `swift-patterns`, `swiftui-patterns`.

Modified here: dependency versions updated and verified, dead APIs replaced (e.g. Firebase Dynamic Links, deprecated `EncryptedSharedPreferences` guidance), compile-blocking samples fixed, and descriptions rewritten to disambiguate overlapping skills. `feature-builder` was rewritten to drop an orchestration pipeline that referenced sub-agents and MCP servers not present here.

### [avdlee/swiftui-agent-skill](https://github.com/avdlee/swiftui-agent-skill) — Antoine van der Lee

| Skill | Path |
|---|---|
| `swiftui-expert-skill` | `ios/swiftui-expert-skill` |

### [affaan-m/everything-claude-code](https://github.com/affaan-m/everything-claude-code)

| Skill | Path |
|---|---|
| `ios-icon-gen` | `ios/ios-icon-gen` |
| `swift-concurrency-6-2` | `ios/swift-concurrency-6-2` |
| `swift-protocol-di-testing` | `ios/swift-protocol-di-testing` |

## Original work

Written from scratch for this library, grounded in the official Apple, Kotlin and Android documentation, then verified by an independent adversarial pass that checked every API symbol against those docs:

`activitykit`, `app-clips`, `app-intents`, `app-store-review`, `apple-on-device-ai`, `authentication`, `background-processing`, `callkit`, `cloudkit`, `contacts-framework`, `core-nfc`, `coreml`, `debugging-instruments`, `device-integrity`, `financekit`, `ios-simulator`, `mapkit`, `metrickit`, `natural-language`, `passkit`, `pdfkit`, `photokit`, `storekit`, `swift-api-design-guidelines`, `swift-architecture`, `swift-charts`, `swift-formatstyle`, `swift-security`, `swiftlint`, `swiftui-uikit-interop`, `swiftui-webkit`, `tipkit`, `vision-framework`, `widgetkit`, plus `kmp-money`, `kmp-tls-pinning`, `android-device-integrity`, `mobile-session-security`, `kmp-ios-integration`, `kmp-logging`, `compose-resources`, `error-handling-result`, `swift-concurrency`, `swiftui-observation`, `swift-package-manager`, `swiftdata`, `prepare-merge-request`.

Trademarks — Apple, Swift, SwiftUI, Xcode, Android, Kotlin, Gradle, Firebase and Sentry — belong to their respective owners. This project is not affiliated with, endorsed by, or sponsored by any of them.
