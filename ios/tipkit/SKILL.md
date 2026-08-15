---
name: tipkit
description: "In-app tips and feature discovery on iOS/macOS with Apple's TipKit — the Tip protocol (title/message/image/actions/options/id), display via TipView, popoverTip(_:arrowEdge:action:), and UIKit TipUIView/TipUIPopoverViewController; eligibility with @Parameter + the #Rule macro and Event.donate(); Tips.configure (displayFrequency, datastoreLocation, cloudKitContainer); Tip.Action, invalidate(reason:) with InvalidationReason, status/statusUpdates; TipGroup + Priority (.ordered/.firstAvailable, iOS 18); reusable tip identifiers; CloudKit tip-state sync; and testing overrides (showAllTipsForTesting / hideTipsForTesting / resetDatastore). Use when adding onboarding hints, teachable moments, or feature callouts. For SwiftUI state see swiftui-observation; for CloudKit containers see cloudkit; for tip copy localization see localization-patterns; for VoiceOver/Dynamic Type see accessibility-patterns; for UI-test overrides see ios-testing. Not for Live Activities (activitykit), widgets (widgetkit), or Siri/Shortcuts actions (app-intents)."
---

# TipKit (iOS / macOS)

Contextual in-app tips for feature discovery. `import TipKit`. Base API **iOS 17+**;
`TipGroup`, CloudKit sync, and reusable identifiers are **iOS 18+**. Grounded in
Apple's TipKit and SwiftUI documentation.

- Tips are **declarative + rule-gated**: you describe a tip and the conditions to show it; TipKit owns *when* it appears and persists that state across launches.
- **In a fintech app:** use tips for discovery ("Set up Face ID unlock", "Move money faster with saved recipients") — never to disclose fees, rates, or legal terms. Tips are dismissible and frequency-throttled, so they must never carry information the user is required to see.

## Contents

- [Configure at launch](#configure)
- [Define a tip](#define)
- [Display a tip (SwiftUI / UIKit)](#display)
- [Actions](#actions)
- [Rules: parameters & events](#rules)
- [Options (display count / duration / frequency)](#options)
- [Lifecycle: invalidate & status](#lifecycle)
- [TipGroup + priority (iOS 18)](#groups)
- [Reusable identifiers (iOS 18)](#reusable)
- [CloudKit sync (iOS 18)](#cloudkit)
- [Testing overrides](#testing)
- [Correctness checklist](#checklist)
- References: `references/rules-events-uikit.md`

<a id="configure"></a>
## Configure at launch

Call **`Tips.configure`** exactly once, early (App init / `application(_:didFinishLaunchingWithOptions:)`), before any tip is shown. It `throws` and loads the persistent tip datastore.

```swift
import TipKit
import SwiftUI

@main
struct BankApp: App {
    init() {
        try? Tips.configure([
            .displayFrequency(.immediate),           // how often *any* tip may appear
            .datastoreLocation(.applicationDefault),
        ])
    }
    var body: some Scene { WindowGroup { RootView() } }
}
```

- **`.displayFrequency(_:)`** — throttles the whole app's tips: `.immediate` (no throttle), `.hourly`, `.daily`, `.weekly`. A tip may bypass this with the `IgnoresDisplayFrequency` option (below).
- **`.datastoreLocation(_:)`** — where display state persists:
  - `.applicationDefault` — app sandbox (default).
  - `.groupContainer(identifier: "group.com.bank.app")` — an **App Group**, so an app extension (widget, notification service) shares tip state with the app.
  - `.url(_:)` — a custom directory URL you manage.
- **`.cloudKitContainer(_:)`** — opt into cross-device sync (iOS 18+); see [CloudKit sync](#cloudkit).
- Configure **once**. Re-configuring or configuring after tips render is unsupported.

<a id="define"></a>
## Define a tip

Conform to **`Tip`** (which refines `Identifiable` + `Sendable`). Only `title` is required; everything else has a default empty implementation.

```swift
struct SavedRecipientsTip: Tip {
    var title: Text {
        Text("Send money faster")
    }
    var message: Text? {
        Text("Save a recipient to skip re-entering their details next time.")
    }
    var image: Image? {
        Image(systemName: "person.crop.circle.badge.plus")
    }
}
```

- `title: Text`, `message: Text?`, `image: Image?` — SwiftUI `Text`/`Image` (works in UIKit hosts too). Keep `title` a few words; `message` one or two sentences.
- Use `Text("…")` string keys (or `LocalizedStringKey`) so copy localizes — see `localization-patterns`. Don't hardcode currency/amount formatting in tips; format with `swift-formatstyle` if you must interpolate.
- `id` (from `Identifiable`) defaults to the type name. Override it for **reusable** tips ([below](#reusable)).
- `actions`, `rules`, `options` are covered in the following sections.

<a id="display"></a>
## Display a tip

### SwiftUI — inline (`TipView`)

Renders the tip as a banner in the layout flow. Good for list headers and settings rows.

```swift
struct TransferView: View {
    private let tip = SavedRecipientsTip()
    var body: some View {
        VStack {
            TipView(tip, arrowEdge: .bottom) { action in
                // handle a tapped Tip.Action by its id (see Actions)
            }
            RecipientList()
        }
    }
}
```

- `init(_ tip: (any Tip)?, arrowEdge: Edge? = nil, action: (Tips.Action) -> Void = { _ in })`.
- Overloads add `isPresented: Binding<Bool>?` and an `anchorID:` for custom anchoring.

### SwiftUI — popover (`popoverTip`)

Floats a callout over a control, pointing at it. Good for toolbar buttons and icons.

```swift
Button { addRecipient() } label: { Image(systemName: "plus") }
    .popoverTip(tip, arrowEdge: .top) { action in /* handle action */ }
```

- `func popoverTip(_ tip: (any Tip)?, arrowEdge: Edge? = nil, action: @escaping (Tips.Action) -> Void = { _ in }) -> some View`.
- The popover auto-dismisses when the tip invalidates; you don't manage its presentation.

### UIKit

- `TipUIView` (a `UIView`), `TipUIPopoverViewController`, and cell types `TipUICollectionViewCell` / `TipUICollectionReusableView`. Signatures and an `AsyncSequence`-driven show/hide pattern in `references/rules-events-uikit.md`.

<a id="actions"></a>
## Actions

Buttons rendered inside the tip. Declare them in `actions`; handle taps in the display closure by matching `id`.

```swift
struct FaceIDUnlockTip: Tip {
    var title: Text { Text("Unlock with Face ID") }
    var message: Text? { Text("Skip typing your passcode every time.") }

    var actions: [Action] {
        Action(id: "enable", title: "Turn On")
        Action(id: "later", title: "Not Now")
    }
}

// At the display site:
TipView(tip) { action in
    switch action.id {
    case "enable": presentBiometricSetup()          // see `swift-security`
    case "later":  tip.invalidate(reason: .tipClosed)
    default: break
    }
}
```

- `Tip.Action` carries an `id` and a `title` (`String` or a `Text` builder: `Action(id: "learn") { Text("Learn More") }`).
- The closure receives the tapped `Tips.Action`; branch on `action.id`. Tapping an action does **not** auto-invalidate — call `invalidate(reason:)` yourself when the action fulfills the tip's purpose.

<a id="rules"></a>
## Rules: parameters & events

`rules` gate eligibility. TipKit has two rule kinds, combined with the **`#Rule`** macro. All rules must pass for a tip to be eligible.

### `@Parameter` — boolean/state conditions

```swift
struct SavedRecipientsTip: Tip {
    @Parameter static var hasSentMoney: Bool = false
    @Parameter static var recipientCount: Int = 0

    var rules: [Rule] {
        #Rule(Self.$hasSentMoney) { $0 == true }
        #Rule(Self.$recipientCount) { $0 == 0 }      // show only before they save one
    }
    var title: Text { Text("Send money faster") }
}

// Update parameters as app state changes; TipKit persists them:
SavedRecipientsTip.hasSentMoney = true
```

- `@Parameter` values **persist** in the datastore (reset with `Tips.resetDatastore()`), so a rule can reflect long-lived state without you re-deriving it each launch.
- Pass the projected value (`Self.$param`) to `#Rule`; the trailing closure returns `Bool`.
- Keep parameters non-sensitive. Don't store balances, PANs, or tokens as `@Parameter` — the datastore is not a secure store (see `swift-security`).

### `Event` — "user did X, N times"

```swift
struct BudgetInsightsTip: Tip {
    static let openedTransactions = Event(id: "opened_transactions")

    var rules: [Rule] {
        // Eligible after the user opens the transactions screen 3+ times.
        #Rule(Self.openedTransactions) { $0.donations.count >= 3 }
    }
    var title: Text { Text("Track your spending") }
}

// Each time the action happens, donate once:
BudgetInsightsTip.openedTransactions.donate()
```

- `Event(id:)` — give a **stable string id** so donation counts survive app updates.
- `.donate()` increments the count (there is also an `async` form). Donate at the real moment the action occurs.
- The closure inspects `$0.donations` (a queryable collection). Time-windowed queries (e.g. "3 times this week") use `Tips.DonationTimeRange`; exact query API is in `references/rules-events-uikit.md` (verify against current SDK before relying on a specific method name).

<a id="options"></a>
## Options

`options` cap or exempt a tip independently of rules.

```swift
var options: [any TipOption] {
    MaxDisplayCount(3)          // auto-invalidate after showing 3 times
    IgnoresDisplayFrequency(true)   // bypass the app-wide displayFrequency throttle
    // MaxDisplayDuration(...)   // auto-invalidate after a cumulative on-screen duration
}
```

- `MaxDisplayCount(_:)` — hard ceiling on appearances; the tip invalidates with `.displayCountExceeded` after the limit.
- `IgnoresDisplayFrequency(true)` — let a high-priority onboarding tip appear even if another tip showed recently. Use sparingly.
- `MaxDisplayDuration(_:)` — invalidate after a total displayed time.

<a id="lifecycle"></a>
## Lifecycle: invalidate & status

Once a tip's job is done, **invalidate it** so it never returns.

```swift
tip.invalidate(reason: .actionPerformed)
```

- `InvalidationReason` cases: `.actionPerformed` (user did the thing the tip suggested), `.tipClosed` (user dismissed via the close button — TipKit sets this automatically), `.displayCountExceeded` (hit `MaxDisplayCount`).
- Invalidation is **permanent** until `Tips.resetDatastore()`; it's the normal way to retire a tip after the user acts.
- Observe eligibility reactively:

```swift
var status: Tips.Status { get }            // .available / .invalidated(reason) / .pending
for await status in tip.statusUpdates {    // AsyncSequence — hop to @MainActor for UI
    // react to a tip becoming available or invalidated
}
```

- Prefer letting `TipView`/`popoverTip` react automatically; use `statusUpdates` only for custom (e.g. UIKit) presentation. `@Observable` view models pair well here — see `swiftui-observation`.

<a id="groups"></a>
## TipGroup + priority (iOS 18)

`TipGroup` shows **one tip at a time** from an ordered set — ideal for onboarding sequences.

```swift
@State private var onboarding = TipGroup(.ordered) {
    SavedRecipientsTip()
    FaceIDUnlockTip()
    BudgetInsightsTip()
}

var body: some View {
    VStack {
        // Present whichever tip the group currently surfaces:
        TipView(onboarding.currentTip)
        // …
    }
}
```

- `init(_ priority: TipGroup.Priority, _ builder: () -> [any Tip])`.
- `Priority`:
  - `.ordered` — strict sequence: the next tip appears only after the current one **invalidates** (acted on, dismissed, or count exceeded). Use for step-by-step onboarding.
  - `.firstAvailable` — shows the first tip whose rules currently pass; use when several unrelated tips compete for one spot and you want only one visible.
- `currentTip: (any Tip)?` is the tip to display now; `currentTipUpdates` is an `AsyncSequence` of changes.
- iOS 18+ only. On iOS 17, fall back to per-tip rules and manual sequencing.

<a id="reusable"></a>
## Reusable identifiers (iOS 18)

One tip type shown against multiple instances (e.g. the same "swipe to categorize" hint per account) needs **distinct persisted identities**, or invalidating it for one instance hides it everywhere.

- Override `id` to fold in the instance key, so each context tracks its own display/invalidation state:

```swift
struct CategorizeTip: Tip {
    let accountID: String
    var id: String { "categorize.\(accountID)" }
    var title: Text { Text("Swipe to categorize") }
}
```

- Give the base a stable prefix so counts survive updates. See `references/rules-events-uikit.md` for the group-with-reusable-ids pattern.

<a id="cloudkit"></a>
## CloudKit sync (iOS 18)

Sync tip display/invalidation state across a user's devices so a dismissed tip stays dismissed everywhere.

```swift
try? Tips.configure([
    .displayFrequency(.immediate),
    .cloudKitContainer(.automatic),   // first entitlement container ending in ".tips"
    // .cloudKitContainer(.named("iCloud.com.bank.app.tips"))  // explicit container
])
```

- Requires a CloudKit container in the app's iCloud entitlements. `.automatic` picks the container whose id ends in `.tips`; `.named(_:)` selects one explicitly.
- Syncs only **tip metadata** (which tips were shown/invalidated) — not user data. It stores nothing sensitive, but treat it like any iCloud dependency: it's best-effort and eventually-consistent. For container setup and account-status handling, see `cloudkit`.
- iOS 18+. Without it, tip state is per-device.

<a id="testing"></a>
## Testing overrides

TipKit's rules and throttling make tips hard to trigger on demand. Use the testing hooks (call after `Tips.configure`, e.g. behind a launch argument) — never ship them in a release path.

```swift
// UI tests: force every tip visible regardless of rules/frequency.
Tips.showAllTipsForTesting()
Tips.showTipsForTesting([SavedRecipientsTip.self, FaceIDUnlockTip.self])

// Force tips hidden (e.g. to test screens without tip chrome).
Tips.hideAllTipsForTesting()
Tips.hideTipsForTesting([BudgetInsightsTip.self])

// Wipe persisted state (parameters, event donations, invalidations) between runs.
try? Tips.resetDatastore()   // throws; must run before configure/first display
```

- Gate with a launch arg: `if ProcessInfo.processInfo.arguments.contains("-ResetTips") { try? Tips.resetDatastore() }`, set from your XCUITest — see `ios-testing`.
- `resetDatastore()` must run **before** `configure`/first display in that launch to take effect cleanly.
- These overrides are for tests and previews only. `#if DEBUG`-fence them out of production builds.

<a id="checklist"></a>
## Correctness checklist

- [ ] `Tips.configure` called exactly once at launch, before any tip renders; result `try?`/handled.
- [ ] Tips carry only **discoverable** UI hints — never fees, rates, legal terms, or anything the user must see (tips are dismissible + throttled).
- [ ] `title` short; `message` optional and brief; copy uses localizable `Text` keys, not hardcoded strings.
- [ ] No secrets/PII/balances in `@Parameter` or `Event` ids — the datastore is not secure storage (`swift-security`).
- [ ] `Event(id:)` and reusable `id` values are **stable strings** so counts/state survive app updates.
- [ ] `.donate()` fires at the real moment the action happens; parameters updated when state changes.
- [ ] Tip `invalidate(reason:)`d after its action is completed (`.actionPerformed`) so it doesn't recur.
- [ ] `MaxDisplayCount` / `IgnoresDisplayFrequency` used deliberately; frequency-bypass reserved for key onboarding.
- [ ] `TipGroup(.ordered)`, CloudKit sync, and reusable-id grouping gated to iOS 18+, with an iOS 17 fallback.
- [ ] `.cloudKitContainer` matches a real iCloud entitlement container; account-status handled (`cloudkit`).
- [ ] `showAllTipsForTesting` / `hideTipsForTesting` / `resetDatastore` are test/preview-only and `#if DEBUG`-fenced.
- [ ] Tips verified with VoiceOver and Dynamic Type; actions reachable and labeled (`accessibility-patterns`).
