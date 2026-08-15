# Dynamic Island — presentations & region layout

The `dynamicIsland:` closure of `ActivityConfiguration` returns a `DynamicIsland`
with four presentations. The system picks one based on device, activity count, and
user interaction. All read from the same `ActivityViewContext` (`context.state`,
`context.attributes`, `context.isStale`).

## The four presentations

| Presentation | Shown when | Space | Put here |
|---|---|---|---|
| **compactLeading** | only your activity is active | ~1 glyph left of the sensor | app glyph / status icon |
| **compactTrailing** | only your activity is active | ~1 glyph right of the sensor | a number: ETA, count, timer |
| **minimal** | multiple apps have activities (system may show just one) | a single circular slot | one glyph or tiny number |
| **expanded** | user long-presses, or a high-priority update | full drop-down area | rich multi-region layout |

- Compact leading + trailing render together, wrapping the TrueDepth sensor.
- Keep compact/minimal to **one glyph or a short number** — anything longer is truncated. `.frame(maxWidth:)` on a timer keeps it from pushing layout around.

## Expanded regions

```swift
DynamicIsland {
    DynamicIslandExpandedRegion(.leading)  { /* icon / short label */ }
    DynamicIslandExpandedRegion(.trailing) { /* status / timer */ }
    DynamicIslandExpandedRegion(.center)   { /* optional headline above leading/trailing */ }
    DynamicIslandExpandedRegion(.bottom)   { /* progress bar, wide content, actions */ }
} compactLeading: { … } compactTrailing: { … } minimal: { … }
```

- **`.leading` / `.trailing`** sit at the top, flanking the sensor; **`.center`** sits between them; **`.bottom`** spans full width beneath. Use `.bottom` for progress bars and any wide element.
- **Priority when space is tight:** set `.dynamicIsland(verticalPlacement:)` / region `priority` and expect the system to drop lower-priority regions on smaller layouts. Design so the activity still reads with only leading + trailing + bottom.
- Modifiers on the `DynamicIsland`: `.keylineTint(_)` (accent ring around compact), `.widgetURL(_)` (tap target / deep link), `.contentMargins(_)`.

## Lock Screen presentation

- The first `ActivityConfiguration` closure is the Lock Screen + Home Screen banner (devices without a Dynamic Island show this for everything).
- Style with `.activityBackgroundTint(_)` and `.activitySystemActionForegroundColor(_)`.
- Keep it a compact card: title, one line of status, a progress indicator. It also feeds the Apple Watch Smart Stack (see `.supplementalActivityFamilies`).

## Staleness & live values

- When `context.isStale` is true (past `staleDate`), mute the UI (`.foregroundStyle(.secondary)`) or show "Updating…" — don't present stale numbers as current.
- Prefer system-driven live text so you don't push every tick:
  - `Text(endDate, style: .timer)` — counts down/up automatically.
  - `Text(date, style: .relative)` / `.offset` — relative time.
  - `ProgressView(timerInterval: start...end)` — a self-advancing bar.

## Design pitfalls

- Compact and expanded disagreeing because they read different fields → always derive from `context.state`.
- Overflowing compact slots with long text → truncation; use glyphs + short numbers.
- Assuming all regions always render → they don't on constrained layouts; keep the essential signal in leading/trailing/bottom.
- Hardcoding a light-mode color → the Island is always dark; use system colors and test contrast.
