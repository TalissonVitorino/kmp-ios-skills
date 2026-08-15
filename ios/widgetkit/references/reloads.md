# Reloads, push & refresh budget — depth

Companion to `../SKILL.md`. Getting fresh data into a widget within the budget.

## Three ways a widget gets new data

1. **Timeline advance (free):** WidgetKit walks pre-rendered future entries locally. No reload spent. Shape timelines to cover predictable change (see `timelines.md`).
2. **`WidgetCenter` reload (app-driven):** the app calls a reload when data changes.
3. **APNs push reload (server-driven):** a push wakes WidgetKit to fetch a new timeline while the app is not running.

## WidgetCenter

```swift
import WidgetKit

// Targeted — cheapest and clearest. Match the Widget's `kind`.
WidgetCenter.shared.reloadTimelines(ofKind: "AccountBalance")

// Everything you own.
WidgetCenter.shared.reloadAllTimelines()

// Only reload kinds the user actually placed.
let infos = try await WidgetCenter.shared.currentConfigurations()
for info in infos where info.kind == "AccountBalance" {
    // info.family, info.configuration (the decoded intent) available here
}
```

- Call on any meaningful data change (balance updated, setting toggled, sign-out → clear).
- Interactive `AppIntent`s reload their widget automatically after `perform()`; you don't double-reload.
- Reloading a kind nobody added is wasted work — filter with `currentConfigurations()` when in doubt.

## Push reloads

WidgetKit can refresh from an APNs push without the app running — Apple's guide
*Updating widgets with WidgetKit push notifications* is the reference. Shape:

- The app obtains a **per-widget push token** and forwards it (plus the widget kind) to your server.
- The server sends an APNs push targeting that widget; WidgetKit requests a fresh timeline.
- APNs registration, certificates/keys, and delivery are standard push plumbing — see the `push-notifications` skill.

Constraints:

- Push reloads draw on the **same refresh budget** as scheduled reloads — they are for occasional, meaningful updates, not a live feed.
- For continuously updating UI (delivery ETA, live score, running timer), use a **Live Activity** (`activitykit`) with push-to-update, not widget pushes.
- The exact token-retrieval API for widget push has moved across releases; verify the current symbol against the linked Apple doc for your deployment target before wiring it.

## The refresh budget

- WidgetKit **rations background timeline reloads** for each widget. For a widget the user keeps visible, the practical allowance is roughly **40–70 reloads/day** (about one every 15–60 minutes). The number is system-decided and varies with how the user engages the widget; treat it as "a few dozen," not a contract.
- Over budget, your `.after(date)` requests are honored **late** — plan for it; never assume second-precision scheduling from the background.
- **Foreground app reloads via `WidgetCenter` are the escape hatch** — reloading because the app just changed data is not throttled the way blind background scheduling is. Push data from the app when you have it rather than polling from the provider.
- Practical provider hygiene:
  - Do I/O off the main actor; keep peak memory well under the extension limit (decode images to `context.displaySize`).
  - Cache the last successful entry in the App Group; on fetch failure, render the cache with `.invalidatableContent()` rather than a blank/placeholder.
  - Return a sensible `.after`/`.atEnd` policy even on failure so the widget retries later.
  - Don't loop: a timeline whose only entry reloads immediately burns the budget and still shows stale data.
