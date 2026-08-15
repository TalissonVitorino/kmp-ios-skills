# Timelines, entries & Smart Stack relevance (depth)

Companion to `../SKILL.md`. Provider mechanics, timeline shaping, and relevance.

## Provider callback contract

`AppIntentTimelineProvider` (async) requirements:

```swift
struct P: AppIntentTimelineProvider {
    // 1. Instant, synchronous, redactable stand-in. Runs while the real snapshot loads
    //    and for the widget gallery. No I/O.
    func placeholder(in context: Context) -> Entry { .placeholder }

    // 2. A single representative entry. Used in the gallery/transitions.
    //    `context.isPreview == true` means "gallery" — return canned data fast.
    func snapshot(for configuration: MyIntent, in context: Context) async -> Entry {
        if context.isPreview { return .sample }
        return await load(configuration)
    }

    // 3. The real thing: current + future entries and a reload policy.
    func timeline(for configuration: MyIntent, in context: Context) async -> Timeline<Entry> {
        let entries = await buildEntries(configuration)
        return Timeline(entries: entries, policy: .atEnd)
    }

    // 4. Optional: pre-baked configurations offered when adding to a Smart Stack.
    func recommendations() -> [AppIntentRecommendation<MyIntent>] { [] }
}
```

`TimelineProvider` (completion-handler) is the same shape without configuration:
`placeholder(in:)`, `getSnapshot(in:completion:)`, `getTimeline(in:completion:)`.

- `context` exposes `family`, `displaySize`, `isPreview`, and environment variants. Size your fetch to the family — a small widget need not load a full list.
- The extension has a hard memory ceiling. Decode images to the display size; never hold large arrays.

## Shaping timelines to avoid reloads

The timeline is a **schedule of pre-rendered states**. WidgetKit advances through entries
locally at each entry's `date` with no reload. Spend a reload only for data you can't predict.

```swift
// A one-hour countdown to market open, one entry per minute, no reloads in between.
func buildEntries(_ c: MyIntent) async -> [Entry] {
    let open = nextMarketOpen()
    return stride(from: 0, through: 60, by: 1).map { minute in
        let date = open.addingTimeInterval(Double(-minute) * 60).reversedIfNeeded()
        return Entry(date: date, minutesToOpen: minute)
    }
}
```

- Prefer SwiftUI's self-updating text over minute-by-minute entries where possible:
  - `Text(entry.date, style: .relative)` / `.timer` / `.offset` update on-screen **without** new entries.
  - `Text(targetDate, style: .timer)` renders a live countdown from a single entry.
- Use `.after(date)` when the *next data* arrives at a known time; `.atEnd` when the last entry is your best guess; `.never` when only app/push reloads should update it.

## Relevance for the Smart Stack

### Per-entry relevance

```swift
struct Entry: TimelineEntry {
    let date: Date
    let payload: Payload
    var relevance: TimelineEntryRelevance?
}

// score is relative to your own widget's entries; duration is how long it stays elevated.
Entry(date: payday, payload: p,
      relevance: TimelineEntryRelevance(score: 100, duration: 4 * 3600))
```

The system uses `score` to decide when to rotate this widget to the top of a stack it's in.
Reserve high scores for genuinely time-critical moments (bill due, payday) — inflating every
entry defeats the ranking.

### App Intents `RelevantContext` (situational)

For configurable widgets, tell the system *when* a configuration is relevant so it can surface
even without a fresh timeline. Contexts include date intervals, location, and daily routine cues.

```swift
import AppIntents

func publishRelevance() async throws {
    let intents: [RelevantIntent] = accounts.map { acct in
        RelevantIntent(SelectAccountIntent(account: acct.entity),
                       widgetKind: "Watchlist",
                       relevance: .date(from: acct.payday, to: acct.payday.addingTimeInterval(86_400)))
    }
    try await RelevantIntentManager.shared.updateRelevantIntents(intents)
}
```

- Call after data changes that shift relevance (schedule, location); the manager replaces the set.
- `recommendations()` (above) is the complementary "what to offer when adding" list.
