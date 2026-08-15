# Axes, scales, legends, and plot styling

Deep reference for customizing the frame of a `Chart`. Base API iOS 16+.

## AxisMarks anatomy

```swift
.chartYAxis {
    AxisMarks(preset: .aligned, position: .leading, values: .automatic(desiredCount: 5)) { value in
        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
        AxisTick(length: 4, stroke: StrokeStyle(lineWidth: 1))
        AxisValueLabel {
            if let v = value.as(Double.self) {
                Text(v, format: .currency(code: "USD").notation(.compactName))
            }
        }
    }
}
```

- `AxisMarks` params: `preset:` (`.automatic`/`.aligned`/`.extended`/`.inset`), `position:`, `values:`, and a content closure receiving an `AxisValue`.
- `values:` options:
  - `.automatic` / `.automatic(desiredCount:roundLowerBound:roundUpperBound:)`
  - `.stride(by: .day, count: 7)` for `Date`; `.stride(by: 100)` for numbers
  - an explicit `[Double]` / `[Date]` array
- Recover the value inside the closure with `value.as(Double.self)`, `value.as(Date.self)`, `value.as(String.self)`; returns `Optional`.
- `AxisValueLabel(_:)` accepts a `String`, a `format:` `FormatStyle`, or a `@ViewBuilder` (as above) for conditional/rich labels.
- Multiple `AxisMarks` in one builder: e.g. one set for major gridlines, another for minor ticks, filtered by `value.index` / `value.count`.

## Conditional gridlines / labels

```swift
.chartXAxis {
    AxisMarks(values: .stride(by: .month)) { value in
        if let date = value.as(Date.self), Calendar.current.component(.month, from: date) == 1 {
            AxisGridLine().foregroundStyle(.primary)     // emphasize January
            AxisValueLabel(format: .dateTime.year())
        } else {
            AxisGridLine()
            AxisValueLabel(format: .dateTime.month(.narrow))
        }
    }
}
```

## Scales

| Modifier | Purpose |
|---|---|
| `chartXScale(domain:)` / `chartYScale(domain:)` | Fix the visible domain (`ClosedRange`, partial range, or `[category]` array) |
| `chartXScale(domain:type:)` | `type:` = `.linear`, `.log`, `.symmetricLog`, `.squareRoot`, `.date`, `.category` |
| `chartXScale(range:)` | Screen extent; `.reversed()` to flip an axis |
| `chartZScale(domain:)` | Z domain in `Chart3D` (iOS 26) |

- Categorical string domain: `.chartXScale(domain: ["Mon","Tue","Wed"])` forces order and includes empty categories.
- `.log`/`.symmetricLog` need a strictly positive domain (log) — symmetric-log tolerates zero/negatives.

## Legend

```swift
.chartLegend(position: .bottom, alignment: .center, spacing: 8)
.chartLegend(.hidden)                       // suppress entirely
```

- Position: `.automatic`/`.top`/`.bottom`/`.leading`/`.trailing`/`.overlay`.
- Legend content follows the `by:`-value scales (`chartForegroundStyleScale`, `chartSymbolScale`).

## Plot area & background

```swift
.chartPlotStyle { plot in
    plot.frame(height: 220)
        .background(.quaternary.opacity(0.15))
        .border(.quaternary)
}
.chartBackground { proxy in                 // draw behind marks, e.g. donut-hole total
    GeometryReader { geo in
        if let plotFrame = proxy.plotFrame {
            let rect = geo[plotFrame]
            Text("Total").position(x: rect.midX, y: rect.midY)
        }
    }
}
.chartOverlay { proxy in ... }              // draw above marks; also used for custom gestures
```

- `ChartProxy` (from `chartOverlay`/`chartBackground`) exposes `position(forX:)`, `value(atX:)`, `plotFrame` to map between screen points and domain values — the basis of custom hit-testing.
