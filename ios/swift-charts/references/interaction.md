# Interaction: selection, scrolling, tooltips

Selection and scrolling require iOS 17+. Gate with `if #available(iOS 17, *)`.

## Tap/drag selection → tooltip

Bind a `Plottable` value, match it back to a data row, and overlay a `RuleMark` +
`.annotation` tooltip.

```swift
struct BalanceChart: View {
    let points: [BalancePoint]                 // has .day: Date, .balanceDouble: Double, .balance: Decimal
    @State private var selectedDay: Date?

    private var selected: BalancePoint? {
        guard let selectedDay else { return nil }
        return points.min(by: {
            abs($0.day.timeIntervalSince(selectedDay)) < abs($1.day.timeIntervalSince(selectedDay))
        })
    }

    var body: some View {
        Chart {
            ForEach(points) { p in
                LineMark(x: .value("Day", p.day), y: .value("Balance", p.balanceDouble))
                    .interpolationMethod(.monotone)
            }
            if let selected {
                RuleMark(x: .value("Day", selected.day))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .annotation(position: .top,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading) {
                            Text(selected.day, format: .dateTime.month().day())
                            Text(selected.balance, format: .currency(code: "USD"))
                                .font(.headline)
                        }
                        .padding(6)
                        .background(.regularMaterial, in: .rect(cornerRadius: 8))
                    }
            }
        }
        .chartXSelection(value: $selectedDay)
    }
}
```

- The selection binding reports the **nearest domain value**, not an index — always resolve it against the data (`min(by:)`/`first(where:)`).
- `chartXSelection(value:)`, `chartYSelection(value:)`, `chartAngleSelection(value:)` (sectors), and range variants `chartXSelection(range: Binding<ClosedRange<P>?>)`.
- Clear on tap-away: the binding goes `nil` automatically when the user taps empty plot area.

## Programmatic hit-testing with ChartProxy

When you need finer control (e.g. hover on macOS, custom drag), read positions from a
`ChartProxy` inside `chartOverlay`:

```swift
.chartOverlay { proxy in
    GeometryReader { geo in
        Rectangle().fill(.clear).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                guard let plotFrame = proxy.plotFrame else { return }
                let x = drag.location.x - geo[plotFrame].origin.x
                if let day: Date = proxy.value(atX: x) { selectedDay = day }
            })
    }
}
```

## Scrolling details

```swift
.chartScrollableAxes(.horizontal)
.chartXVisibleDomain(length: 3600 * 24 * 30)     // Date axis → seconds; number axis → value units
.chartScrollPosition(x: $scrollX)                // two-way; also .chartScrollPosition(initialX:)
.chartScrollTargetBehavior(.valueAligned(matching: DateComponents(hour: 0),
                                          majorAlignment: .page))
```

- `.valueAligned(matching:majorAlignment:)` snaps to matching calendar/value units; `majorAlignment` = `.page`, `.unit`, `.matching(_)`, `.value(_)` decides the coarse snap.
- `.valueAligned(unit: 2)` snaps every 2 value-units on a numeric axis; `.paging` snaps a full page.
- Keep the scroll position in observable state to drive/read the visible window (e.g. sync a date picker).

## Known pitfalls

- **Annotations clip while scrolling** — Apple's `chartScrollableAxes` + `.annotation` has long-standing clipping at plot edges; constrain with `overflowResolution:` or draw the callout via `chartOverlay` instead.
- **`chartXVisibleDomain` fights `chartScrollPosition`** — setting a new visible-domain length can reset the scroll position; update them together.
- Selection + scrolling on the same axis can conflict with the scroll gesture; test on device, and prefer a long-press or a separate overlay gesture when both are needed.
