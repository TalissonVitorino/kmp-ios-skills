---
name: widgetkit
description: "Build Home Screen, Lock Screen, StandBy, and Control Center widgets for iOS with WidgetKit — Widget/WidgetBundle @main, TimelineProvider vs AppIntentTimelineProvider, TimelineEntry + TimelineReloadPolicy, StaticConfiguration vs AppIntentConfiguration (WidgetConfigurationIntent), WidgetFamily layouts, containerBackground, interactive Button/Toggle backed by AppIntent/SetValueIntent (iOS 17+), ControlWidget / ControlWidgetButton / ControlWidgetToggle for Control Center (iOS 18), widgetURL deep links, Smart Stack relevance (TimelineEntryRelevance + App Intents RelevantContext), App Groups data sharing, WidgetCenter.reloadTimelines, WidgetKit push reloads, and the refresh budget. Use when creating a widget extension or configuring timelines, families, interactivity, or reloads. Sibling skills: `activitykit` (Live Activities / Dynamic Island), `app-intents` (the AppIntent / AppEntity / WidgetConfigurationIntent layer these widgets depend on), `deep-linking` (Universal Links the widgetURL opens), `push-notifications` (APNs plumbing behind push reloads), `swift-security` (shared-Keychain access group for tokens), `kmp-ios-integration` (feeding widget data from KMP shared code)."
---

# WidgetKit (iOS)

Timeline-driven glanceable UI for Home Screen, Lock Screen, StandBy, and Control
Center. Widgets are SwiftUI views rendered by a **separate extension process** from
snapshots your app supplies ahead of time — they are not live; you push data via
timelines and reloads. Grounded in Apple's WidgetKit, App Intents, and SwiftUI.

- **Related surfaces:** real-time updating UI (delivery, timers, scores) → `activitykit` (Live Activities / Dynamic Island). The intent/entity layer → `app-intents`.
- **KMP boundary:** the widget extension links the shared framework directly, or reads data the main app wrote to a shared App Group container. Keep formatting/money logic in `commonMain` and hand the extension plain values; see `kmp-ios-integration` and `kmp-money`.

## Contents

- [Extension setup & App Groups](#setup)
- [Widget & WidgetBundle (`@main`)](#widget-bundle)
- [Providers: TimelineProvider vs AppIntentTimelineProvider](#providers)
- [TimelineEntry & reload policy](#entry)
- [WidgetFamily layouts & container background](#families)
- [Deep links (widgetURL / Link)](#deeplinks)
- [Interactive widgets (iOS 17+)](#interactive)
- [Control Center controls (iOS 18)](#controls)
- [Lock Screen / StandBy / rendering modes](#lockscreen)
- [Smart Stack relevance](#relevance)
- [Reloads: WidgetCenter, push, refresh budget](#reloads)
- [iOS 26 surfaces](#ios26)
- [Correctness checklist](#checklist)
- References: `references/timelines.md`, `references/controls.md`, `references/reloads.md`

<a id="setup"></a>
## Extension setup & App Groups

- Add a **Widget Extension** target (File ▸ New ▸ Target ▸ Widget Extension). It ships as an app extension inside your app bundle; it runs in its own sandboxed process with a tight memory limit.
- The widget process **cannot** reach your app's in-memory state or its private container. Share data through an **App Group**:
  - Enable the *App Groups* capability on **both** the app and the extension targets with the same `group.<reverse-dns>` id.
  - `UserDefaults(suiteName: "group.com.acme.app")` for small values, or the shared file container:

```swift
let shared = FileManager.default
    .containerURL(forSecurityApplicationGroupIdentifier: "group.com.acme.app")!
```

- **Secrets (tokens, PANs) do not belong in App Group `UserDefaults` or plist** — it is readable in backups. If the widget must call an authenticated API, share the token via a **Keychain access group** instead; see `swift-security`.
- The extension can link your KMP XCFramework directly, or (simpler, lower memory) let the app precompute display values and write them to the group. Prefer the latter for anything heavy.

<a id="widget-bundle"></a>
## Widget & WidgetBundle (`@main`)

A `Widget` binds a *kind* string to a configuration + SwiftUI view. A `WidgetBundle`
is the extension's `@main` entry point when you ship more than one widget or a control.

```swift
import WidgetKit
import SwiftUI

@main
struct AcmeWidgets: WidgetBundle {
    var body: some Widget {
        BalanceWidget()            // StaticConfiguration
        WatchlistWidget()          // AppIntentConfiguration (user-configurable)
        if #available(iOS 18.0, *) {
            QuickPayControl()      // ControlWidget (Control Center)
        }
    }
}
```

- With a **single** widget and no control, mark the `Widget` itself `@main` and omit the bundle.
- `kind` is a stable string you also pass to `WidgetCenter` reloads — treat it as an API identifier, never change it.

<a id="providers"></a>
## Providers: TimelineProvider vs AppIntentTimelineProvider

Two configuration/provider pairs. Pick by whether the **user** configures the widget in the edit sheet.

| | `StaticConfiguration` + `TimelineProvider` | `AppIntentConfiguration` + `AppIntentTimelineProvider` |
|---|---|---|
| User-configurable | No | Yes — edited via a `WidgetConfigurationIntent` |
| Provider callbacks | completion-handler | `async` |
| Use when | fixed content (account balance) | per-instance choices (which account, which symbol) |

### Static (non-configurable)

```swift
struct BalanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> BalanceEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (BalanceEntry) -> Void) {
        completion(BalanceStore.shared.currentEntry())   // fast; may run for the gallery
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BalanceEntry>) -> Void) {
        let entry = BalanceStore.shared.currentEntry()
        // Ask WidgetKit to refresh ~30 min from now (subject to the budget).
        let next = Date.now.addingTimeInterval(30 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct BalanceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AccountBalance", provider: BalanceProvider()) { entry in
            BalanceView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Balance")
        .description("Your available balance at a glance.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}
```

### Configurable (App Intents)

`WidgetConfigurationIntent` lives in the **App Intents** layer — its `@Parameter`s become
the widget's edit controls, and a dynamic `AppEntity` + `EntityQuery` populates a picker.
See `app-intents` for the entity/query mechanics.

```swift
import AppIntents

struct SelectAccountIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Select Account"
    @Parameter(title: "Account") var account: AccountEntity?
}

struct WatchlistProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> WatchlistEntry { .placeholder }

    func snapshot(for configuration: SelectAccountIntent,
                  in context: Context) async -> WatchlistEntry {
        await WatchlistEntry.load(configuration.account)
    }

    func timeline(for configuration: SelectAccountIntent,
                  in context: Context) async -> Timeline<WatchlistEntry> {
        let entry = await WatchlistEntry.load(configuration.account)
        return Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60)))
    }
}

struct WatchlistWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "Watchlist",
                               intent: SelectAccountIntent.self,
                               provider: WatchlistProvider()) { entry in
            WatchlistView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
```

- Migrating an old SiriKit `INIntent`-configured widget? `IntentConfiguration` is the legacy path; new work uses `AppIntentConfiguration`.

<a id="entry"></a>
## TimelineEntry & reload policy

Every entry is a value type with a `date` (when it becomes current) plus your view's data.

```swift
struct BalanceEntry: TimelineEntry {
    let date: Date
    let amount: Decimal
    let currencyCode: String
    var relevance: TimelineEntryRelevance? = nil   // optional; drives Smart Stack rotation

    static let placeholder = BalanceEntry(date: .now, amount: 0, currencyCode: "USD")
}
```

- A `Timeline` is a **list of pre-rendered future states** plus a `TimelineReloadPolicy` telling WidgetKit when to ask for a new timeline:
  - `.atEnd` — reload after the last entry's date.
  - `.after(Date)` — reload no earlier than a specific date.
  - `.never` — never on a schedule; only app- or push-driven `WidgetCenter` reloads update it.
- Provide **multiple future entries** for content that changes on a known schedule (a countdown, market-open time) so the widget updates without spending a reload — WidgetKit walks the entries locally. Reserve reloads for *new data you couldn't predict*.
- `placeholder(in:)` must be **synchronous and instant** — it renders redacted while the real snapshot loads and in the gallery.
- `context.isPreview` is true in the gallery; return canned data fast.
- Never format money with `Double`; carry `Decimal`/minor units and format in the view (see `kmp-money`, `swift-formatstyle`).

<a id="families"></a>
## WidgetFamily layouts & container background

Declare only families you actually design for via `.supportedFamilies([...])`.

- **Home Screen / StandBy:** `.systemSmall`, `.systemMedium`, `.systemLarge`, `.systemExtraLarge` (iPad, and Mac).
- **Lock Screen / watch complications:** `.accessoryCircular`, `.accessoryRectangular`, `.accessoryInline`.
- Branch on family with the environment value:

```swift
@Environment(\.widgetFamily) private var family

var body: some View {
    switch family {
    case .accessoryInline:   Text("\(amount, format: .currency(code: code))")
    case .accessoryCircular: Gauge(...) { }.gaugeStyle(.accessoryCircular)
    case .systemSmall:       SmallBalance(entry: entry)
    default:                 WideBalance(entry: entry)
    }
}
```

- **`containerBackground(_:for: .widget)` is required (iOS 17+).** Without it the widget shows no background on the Home Screen and is removed from StandBy/Lock Screen contexts. The system may hide the background (e.g. StandBy) — don't paint content-critical info onto it.
- Default content margins keep content clear of the rounded corners. Opt out with `.contentMarginsDisabled()` on the configuration when you draw edge-to-edge, then reapply padding yourself.
- Widgets are **static SwiftUI** — no scrolling, no `TabView`, no gestures. The only interactivity is `Button`/`Toggle` backed by an `AppIntent` (below) and tap-to-open via `widgetURL`/`Link`.

<a id="deeplinks"></a>
## Deep links (widgetURL / Link)

- **Whole-widget tap target:** `.widgetURL(URL)` on the root view. Small/accessory families support exactly one; the tap opens your app with that URL.
- **Multiple targets** (medium/large only): wrap regions in `Link(destination:)`. `Link` and `widgetURL` coexist; `Link` wins for its subview, `widgetURL` catches the rest.
- Handle the URL in the app via `.onOpenURL` (SwiftUI) / `scene(_:openURLContexts:)`. Route to a real screen — see `deep-linking` for Universal Link handling.

```swift
BalanceView(entry: entry)
    .widgetURL(URL(string: "acme://account/\(entry.accountID)"))
```

<a id="interactive"></a>
## Interactive widgets (iOS 17+)

A `Button` or `Toggle` inside a widget must take an **`AppIntent`** (or `SetValueIntent`)
— it runs the intent in your app process, then WidgetKit reloads the timeline. No other
controls are interactive.

```swift
import AppIntents

struct ToggleWatchIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Watch"
    @Parameter(title: "Symbol") var symbol: String

    init() {}
    init(symbol: String) { self.symbol = symbol }

    func perform() async throws -> some IntentResult {
        await WatchStore.shared.toggle(symbol)   // mutate shared state
        return .result()
    }
}

// In the widget view:
Button(intent: ToggleWatchIntent(symbol: entry.symbol)) {
    Image(systemName: entry.isWatched ? "star.fill" : "star")
}
.buttonStyle(.plain)
```

- The intent runs **out of process from the widget**, in the app's extension-hosted execution; keep `perform()` fast and side-effect-focused. Write results where the next timeline read will see them (App Group / shared store), then WidgetKit re-renders.
- For an on/off control use `Toggle(isOn:intent:)` with a `SetValueIntent`; WidgetKit assigns `value` before calling `perform()`.
- **Optimistic UI:** WidgetKit re-renders the view immediately reflecting your state mutation, before the full reload completes — mutate the shared store synchronously inside `perform()` so the redraw is correct.
- Same `AppIntent` type is reusable from Siri/Shortcuts/Spotlight; define it once in `app-intents`.

<a id="controls"></a>
## Control Center controls (iOS 18)

A `ControlWidget` surfaces one action or toggle in **Control Center, the Lock Screen,
and the Action button**. Add it to the same `WidgetBundle`. Two configurations mirror the
widget ones:

- `StaticControlConfiguration` — one fixed control (a single global toggle/button).
- `AppIntentControlConfiguration` — user adds multiple instances, each configured by a `ControlConfigurationIntent` (e.g. one control per account).

```swift
import WidgetKit
import AppIntents
import SwiftUI

@available(iOS 18.0, *)
struct QuickPayControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.acme.quickpay") {
            ControlWidgetButton(action: OpenQuickPayIntent()) {
                Label("Quick Pay", systemImage: "creditcard")
            }
        }
        .displayName("Quick Pay")
    }
}
```

- **Button** (`ControlWidgetButton`) → discrete action. To open the app, set `static var openAppWhenRun = true` on the intent (or conform to `OpenIntent`).
- **Toggle** (`ControlWidgetToggle`) → boolean state; its action intent must conform to **`SetValueIntent`** (`@Parameter var value: Bool`). WidgetKit writes `value` then calls `perform()`.
- For a configurable, stateful toggle use `AppIntentControlConfiguration` with a value provider that reads current state so the toggle renders correctly after a system relaunch:

```swift
AppIntentControlConfiguration(kind: "com.acme.roundup",
                              provider: RoundUpProvider()) { value in
    ControlWidgetToggle("Round-Up Savings",
                        isOn: value.isEnabled,
                        action: SetRoundUpIntent(account: value.account)) { isOn in
        Label(isOn ? "On" : "Off", systemImage: "arrow.up.forward")
    }
}
```

- Controls reload via `ControlCenter.shared.reloadControls(ofKind:)` (analogous to `WidgetCenter`). Full provider + `SetValueIntent` example in `references/controls.md`.
- **Financial guardrail:** a control can *open* a payment flow, but must not *move money* headlessly — require the app + user confirmation for any transfer.

<a id="lockscreen"></a>
## Lock Screen / StandBy / rendering modes

- Lock Screen widgets use the **accessory** families and render **monochrome/vibrant** — the system desaturates them. Design for shape and legibility, not color.
- `@Environment(\.widgetRenderingMode)` reports the active mode: `.fullColor` (Home Screen), `.accented` (tinted Home Screen, StandBy night), `.vibrant` (Lock Screen). Adapt where needed.
- In **accented** mode the system splits your view into a default group and an accented group; mark views to be tinted with `.widgetAccentable()`.
- **StandBy** (iPhone charging, landscape) shows `.systemSmall` enlarged — verify your small layout scales and that the container background can be dropped.
- `.privacySensitive()` redacts content when the device is locked; use it for balances/PII on Lock Screen widgets. `.invalidatableContent()` marks content that may be stale during a reload.

<a id="relevance"></a>
## Smart Stack relevance

Two independent mechanisms feed the system's rotation of a stacked widget to the top:

- **Per-entry relevance:** attach `TimelineEntryRelevance(score:duration:)` to entries. Higher `score` = more likely to auto-rotate to the top of a Smart Stack for `duration`. Score is relative to your own widget's other entries.

```swift
BalanceEntry(date: payday, amount: amt, currencyCode: code,
             relevance: TimelineEntryRelevance(score: 90, duration: 3600))
```

- **App Intents `RelevantContext`:** tell the system *when* a configuration matters (a date range, a location, workout/sleep cues) via `RelevantIntentManager.shared.updateRelevantIntents(...)`, so a configurable widget surfaces in the right situation even without a fresh timeline. Details and a full call in `references/timelines.md`.
- `recommendations()` on `AppIntentTimelineProvider` supplies pre-baked configurations the system can offer when adding the widget to a stack.

<a id="reloads"></a>
## Reloads: WidgetCenter, push, refresh budget

From the **app** (or an interactive intent), ask WidgetKit to refresh:

```swift
import WidgetKit

WidgetCenter.shared.reloadTimelines(ofKind: "AccountBalance")  // one kind — preferred
WidgetCenter.shared.reloadAllTimelines()                       // everything you own

// Inspect what the user actually placed (don't reload kinds nobody added):
let infos = try await WidgetCenter.shared.currentConfigurations()
```

- Prefer `reloadTimelines(ofKind:)` — targeted reloads are cheaper and clearer than `reloadAllTimelines()`.
- Reload after the app changes data the widget shows (new balance, toggled setting). Interactive intents reload automatically after `perform()`.

### Push-driven reloads

- WidgetKit can be reloaded by an **APNs push** so the widget refreshes without the app running (see Apple's *Updating widgets with WidgetKit push notifications*). The app obtains a per-widget push token and forwards it to your server; the server sends a push that triggers a timeline reload. Wire the APNs side with `push-notifications`.
- Pushes are **budgeted** like scheduled reloads — they are for occasional, meaningful updates, not a live stream. For genuinely real-time UI use a **Live Activity** (`activitykit`) instead.

### Refresh budget

- WidgetKit **rations background reloads** — for a frequently visible widget roughly 40–70 per day (about one every 15–60 min); the exact allowance is system-decided and varies with usage. Over budget, your `.after(_:)` dates are honored *late*.
- **Direct `WidgetCenter` reloads from the foreground app do not draw down the timeline budget** the way scheduled/push reloads do — refresh on app state changes freely; lean on scheduled reloads sparingly.
- Do network work in the provider off the main actor, keep it under the extension's memory limit, and cache the last-good entry so a failed fetch still renders. Budget-management patterns in `references/reloads.md`.

<a id="ios26"></a>
## iOS 26 surfaces (WWDC25)

- Widgets now appear on **CarPlay** (and continue to render as-is — supply a compact layout), **macOS 26**, and **visionOS** as spatial 3D widgets. Live Activities also reach CarPlay and macOS 26.
- **visionOS** adds `levelOfDetail` so a widget adapts its content by viewing distance, plus wall/table mounting. Gate visionOS-only APIs behind availability and keep the phone layout intact.
- No breaking change to the core timeline model — the same `Widget`/provider code carries forward; you opt into new surfaces per family/platform.

<a id="checklist"></a>
## Correctness checklist

- [ ] One `WidgetBundle` `@main` (or a single `@main` `Widget`); each `kind` stable and unique.
- [ ] Chose `StaticConfiguration` vs `AppIntentConfiguration` by whether the user configures it; legacy `IntentConfiguration` only for existing SiriKit widgets.
- [ ] `placeholder(in:)` is synchronous and instant; `context.isPreview` returns canned data fast.
- [ ] `.containerBackground(_:for: .widget)` set on every family; `.contentMarginsDisabled()` only when drawing edge-to-edge.
- [ ] `.supportedFamilies` lists only designed families; layout branches on `\.widgetFamily`.
- [ ] Multiple future entries used for predictable changes; reloads reserved for unpredictable new data.
- [ ] Reload policy chosen deliberately (`.after`/`.atEnd`/`.never`); no tight reload loop fighting the budget.
- [ ] Interactive `Button`/`Toggle` backed by an `AppIntent`/`SetValueIntent`; `perform()` mutates shared state synchronously for correct optimistic redraw (iOS 17+).
- [ ] Control Center `ControlWidget` gated `@available(iOS 18.0, *)`; toggle intent conforms to `SetValueIntent`; controls never move money headlessly.
- [ ] Data shared via App Group; **secrets via Keychain access group**, never App Group `UserDefaults`/plist (`swift-security`).
- [ ] `.privacySensitive()` on Lock Screen balances/PII; accessory layouts legible in `.vibrant`/`.accented` rendering.
- [ ] `reloadTimelines(ofKind:)` preferred over `reloadAllTimelines()`; push reloads treated as occasional, not real-time (use `activitykit` for live).
- [ ] Provider network work off the main actor, under the memory limit, with a cached last-good entry; money carried as `Decimal`/minor units, never `Double`.
