# TipKit — advanced rules, events, and UIKit

Depth companion to `../SKILL.md`. Grounded in Apple's TipKit documentation.
Symbol names flagged "verify" are shape-correct but should be confirmed against the
installed SDK (Xcode Quick Help / headers) before relying on the exact spelling.

## Combining rules

- Every entry in `rules` must pass for a tip to be eligible (logical AND).
- Mix parameter and event rules freely:

```swift
struct RoundUpTip: Tip {
    @Parameter static var hasSavingsGoal: Bool = false
    static let viewedTransactions = Event(id: "viewed_transactions")

    var rules: [Rule] {
        #Rule(Self.$hasSavingsGoal) { $0 == false }             // no goal yet
        #Rule(Self.viewedTransactions) { $0.donations.count >= 5 }  // engaged user
    }
    var title: Text { Text("Round up spare change") }
}
```

- There is no built-in OR across rules; model alternatives as separate tips (optionally in a `.firstAvailable` `TipGroup`).

## Events in depth

- `Event(id:)` — the id is the persisted key. Two `Event`s with the same id share a donation count; keep ids unique per logical action and stable across releases.
- `donate()` records one donation (has an `async` overload). Each donation carries a timestamp.
- The rule closure receives the event with a `donations` collection you query:
  - Count-based: `$0.donations.count >= N`.
  - Time-windowed: filter donations to a recent window via `Tips.DonationTimeRange` (e.g. donations within the last week) — **verify** the exact query method name/signature (`donatedWithin(_:)`-style) in the current SDK; `DonationTimeRange` is a confirmed nested type but the filtering call has changed across betas.
- Donate at the true moment of the action, not on view appear-and-disappear churn, or counts inflate.

## Parameters in depth

- `@Parameter static var name: T = default` — the value persists in the datastore and survives launches.
- Assign directly to update: `MyTip.name = newValue`. TipKit observes the change and re-evaluates eligibility.
- Reset with `Tips.resetDatastore()` (test/dev only).
- Only use small, non-sensitive value types (Bool, Int, enums). Never persist secrets, tokens, balances, or PII here — use the Keychain (`swift-security`) for anything sensitive.

## Options reference

| Option | Effect |
|---|---|
| `MaxDisplayCount(_:)` | Invalidate (`.displayCountExceeded`) after N appearances. |
| `IgnoresDisplayFrequency(true)` | Exempt from the app-wide `displayFrequency` throttle. |
| `MaxDisplayDuration(_:)` | Invalidate after a cumulative on-screen duration. |

- Options live in `var options: [any TipOption] { ... }` using the same result-builder style as `rules`/`actions`.

## UIKit integration

TipKit ships UIKit hosts for `TipView`-equivalent presentation. Drive show/hide from the tip's `statusUpdates` / a `TipGroup.currentTipUpdates` stream on the main actor.

- `TipUIView` — a `UIView` you add to your hierarchy:
  ```swift
  let tipView = TipUIView(tip, arrowEdge: .bottom) { action in
      // handle action.id
  }
  ```
- `TipUIPopoverViewController` — presents a tip as a popover anchored to a source view/bar button; present/dismiss it in response to eligibility changes.
- `TipUICollectionViewCell` / `TipUICollectionReusableView` — embed a tip inside a collection view as a cell or supplementary view.

Reactive presentation skeleton (UIKit):

```swift
@MainActor
func observe(_ tip: some Tip, in container: UIView) {
    Task {
        for await status in tip.statusUpdates {
            switch status {
            case .available:
                let v = TipUIView(tip) { _ in }
                container.addSubview(v)               // + constraints
            case .invalidated:
                container.subviews.compactMap { $0 as? TipUIView }.forEach { $0.removeFromSuperview() }
            case .pending:
                break
            @unknown default:
                break
            }
        }
    }
}
```

## Reusable tips inside a group

When the same tip type applies to many rows, give each instance a distinct `id` and let a `TipGroup` arbitrate one-at-a-time display:

```swift
struct CategorizeTip: Tip {
    let accountID: String
    var id: String { "categorize.\(accountID)" }
    var title: Text { Text("Swipe to categorize") }
}

// Per-account instances tracked independently:
let group = TipGroup(.firstAvailable) {
    CategorizeTip(accountID: "checking")
    CategorizeTip(accountID: "savings")
}
```

- Distinct ids mean invalidating the checking-account tip does not hide the savings-account one.
- Keep the prefix (`"categorize."`) stable so donation/display state carries across app updates.

## Gotchas

- Configure once; configuring twice or after a tip renders is unsupported.
- A tip that never appears usually has an unmet rule, an exhausted `MaxDisplayCount`, or is throttled by `displayFrequency` — use `Tips.showAllTipsForTesting()` to confirm the view wiring independently of eligibility.
- `invalidate(reason:)` is permanent until `resetDatastore()`; don't call it speculatively.
- CloudKit sync (`.cloudKitContainer`) is eventually consistent — don't assume instant cross-device dismissal.
- `Text`/`Image` come from SwiftUI even for UIKit hosts; import SwiftUI where you define tips.
