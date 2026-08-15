---
name: swift-charts
description: "Build data visualizations in SwiftUI with Apple's Swift Charts for a fintech iOS app — Chart with BarMark/LineMark/AreaMark/PointMark/RuleMark/RectangleMark/SectorMark, series styling via foregroundStyle(by:)/position(by:)/symbol(by:), axis control (chartXAxis/chartYAxis + AxisMarks/AxisValueLabel/AxisGridLine), domains (chartXScale/chartYScale), interactive selection (chartXSelection/chartYSelection, iOS 17), scrolling (chartScrollableAxes + chartScrollPosition + chartScrollTargetBehavior + chartXVisibleDomain), .annotation, pie/donut via SectorMark, iOS 18 vectorized/function plots (LinePlot/AreaPlot/PointPlot/BarPlot), and iOS 26 Chart3D + SurfacePlot. Use when rendering balance/spend/portfolio charts, sparklines, candlestick-style ranges, category breakdowns, or 3D surfaces. For currency/number axis formatting use `swift-formatstyle`; for Money values feeding a chart see `kmp-money`; for SwiftUI state driving a chart see `swiftui-observation`; the Compose/Android counterpart is `jetpack-compose`."
---

# Swift Charts (SwiftUI)

Declarative charts for iOS/macOS. A `Chart` contains **marks** (each row of data → one
mark); modifiers on the marks encode data into position/color/symbol; modifiers on the
`Chart` control axes, scales, scrolling, and selection. Grounded in Apple's Charts framework.

- `import Charts` (plus `SwiftUI`). Base API iOS 16; selection & scrolling iOS 17; vectorized/function plots iOS 18; `Chart3D`/`SurfacePlot` iOS 26.
- **Sibling skills:** axis/value formatting → `swift-formatstyle`; `Money`/`Decimal` sources → `kmp-money`; observable view state → `swiftui-observation`; accessibility (audio graphs, labels) → `accessibility-patterns`; Android/Compose charts → `jetpack-compose`.

## Contents

- [Marks & the plotting model](#marks)
- [Encoding data: by-value styling](#encoding)
- [Axes](#axes)
- [Scales & domains](#scales)
- [Annotations](#annotations)
- [Selection (iOS 17)](#selection)
- [Scrolling (iOS 17)](#scrolling)
- [Pie / donut — SectorMark](#sector)
- [Vectorized & function plots (iOS 18)](#plots)
- [Chart3D & SurfacePlot (iOS 26)](#chart3d)
- [Fintech recipes](#fintech)
- [Correctness checklist](#checklist)
- References: `references/axes-scales.md`, `references/interaction.md`, `references/chart3d.md`

<a id="marks"></a>
## Marks & the plotting model

One element in the data collection produces one mark. `.value("Label", keyPath)` binds a
data field to a positional (or other) encoding; the `"Label"` names the axis/legend.

```swift
import SwiftUI
import Charts

struct DailySpend: Identifiable {
    let id = UUID()
    let day: Date
    let amount: Decimal
    let category: String
}

Chart(spend) { row in
    BarMark(
        x: .value("Day", row.day, unit: .day),   // date bins by calendar unit
        y: .value("Amount", row.amount)
    )
}
```

- Mark types: `BarMark`, `LineMark`, `AreaMark`, `PointMark`, `RuleMark`, `RectangleMark`, `SectorMark` (iOS 17).
- Positional values accept `Plottable` types: numbers, `Date`, `String`, and your own `Plottable` conformances. `Decimal` is **not** `Plottable` — map to `Double` at the encoding boundary (keep the `Decimal` as the source of truth; see [fintech recipes](#fintech)).
- `x:` / `y:` can be a single `.value(...)` or a **range** `.value(_,_ )` with two endpoints (e.g. `BarMark(x:.value(...), yStart:.value(...), yEnd:.value(...))` for floating bars / candlestick-style hi-lo).
- Combine multiple mark statements in one `Chart` (e.g. `LineMark` + `PointMark` + `RuleMark` overlay). Order = z-order (later draws on top).
- Common per-mark modifiers: `.foregroundStyle(_:)`, `.opacity(_:)`, `.lineStyle(StrokeStyle(...))`, `.interpolationMethod(.catmullRom | .linear | .monotone | .stepStart | ...)`, `.symbol(_:)`, `.symbolSize(_:)`, `.cornerRadius(_:)`, `.offset(...)`, `.zIndex(_:)`, `.mask { }`.
- `RuleMark(y: .value("Target", target))` draws a full-width reference line (threshold, average, budget). `RuleMark(x:yStart:yEnd:)` for a vertical segment.

<a id="encoding"></a>
## Encoding data: by-value styling

Split one dataset into **series** by mapping a categorical field to color, stacking, or
symbol. This also produces the legend automatically.

```swift
Chart(spend) { row in
    BarMark(
        x: .value("Month", row.day, unit: .month),
        y: .value("Amount", row.amount)
    )
    .foregroundStyle(by: .value("Category", row.category))  // color + legend + stacking
    .position(by: .value("Category", row.category))         // side-by-side instead of stacked
}
.chartForegroundStyleScale([                                // pin domain → colors
    "Groceries": Color.green, "Rent": .blue, "Fun": .orange
])
```

- `foregroundStyle(by:)` — color per category; **stacks** bars/areas by default.
- `position(by:)` — dodge/group marks side-by-side (grouped bar chart). Add `axis:` and `span:` to tune.
- `symbol(by:)` / `lineStyle(by:)` — differentiate line/point series by shape or dash.
- `chartForegroundStyleScale(_:)` maps the category domain to explicit `Color`s (KeyValuePairs or a `ShapeStyle` array) — do this for brand/semantic colors instead of relying on the default palette.
- Static style vs by-value: `.foregroundStyle(.blue)` sets one color; `.foregroundStyle(by:)` derives it from data. Use a `Gradient`/`LinearGradient` as a `ShapeStyle` for area fills.

<a id="axes"></a>
## Axes

`chartXAxis` / `chartYAxis` replace or augment the default axis. Build ticks with
`AxisMarks`, and per-tick content with `AxisGridLine`, `AxisTick`, `AxisValueLabel`.

```swift
Chart(spend) { row in
    LineMark(x: .value("Day", row.day), y: .value("Balance", row.balanceDouble))
}
.chartXAxis {
    AxisMarks(values: .stride(by: .day, count: 7)) { value in
        AxisGridLine()
        AxisTick()
        AxisValueLabel(format: .dateTime.month().day())     // FormatStyle on the label
    }
}
.chartYAxis {
    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
        AxisGridLine()
        AxisValueLabel {
            if let amount = value.as(Double.self) {
                Text(amount, format: .currency(code: "USD").notation(.compactName))
            }
        }
    }
}
```

- `AxisMarks(preset:position:values:)` — `values:` accepts `.automatic`, `.automatic(desiredCount:)`, `.stride(by:count:)`, or an explicit array. `position:` is `.leading`/`.trailing`/`.bottom`/`.top`.
- Inside the builder, `value.as(Double.self)` / `value.as(Date.self)` recovers the tick value to format conditionally.
- `AxisValueLabel(format:)` takes any matching `FormatStyle` (`.dateTime…`, `.currency(code:)`, `.percent`) — see `swift-formatstyle` for locale-correct currency/number/date styles.
- Hide an axis entirely: `.chartXAxis(.hidden)`. Move/format the legend with `.chartLegend(position:)` / `.chartLegend(.hidden)`.
- `.chartPlotStyle { plot in plot.frame(height: …) }` sizes the plot area itself.
- More: `references/axes-scales.md`.

<a id="scales"></a>
## Scales & domains

By default the domain is inferred from the data. Pin it to keep a stable, honest axis.

```swift
.chartYScale(domain: 0...maxBalance)          // never start a value axis mid-range implicitly
.chartXScale(domain: startDate...endDate)
.chartYScale(domain: 1...100_000, type: .log) // log/symmetric-log for wide dynamic range
```

- `chartXScale(domain:)` / `chartYScale(domain:)` accept a `ClosedRange`, an unbounded range, or an explicit array (for categorical/string domains).
- `type:` supports `.linear`, `.log`, `.symmetricLog`, `.squareRoot`, `.date`, `.category` (via `ScaleType`).
- **Bar charts must include zero in the domain** — a truncated bar axis misrepresents magnitude. Line charts may zoom the y-domain, but label it clearly.
- `range:` controls the pixel/screen extent (rarely needed; e.g. reverse an axis with `.reversed()` on the range).

<a id="annotations"></a>
## Annotations

Attach SwiftUI views to a mark without leaving the data coordinate space.

```swift
PointMark(x: .value("Day", peak.day), y: .value("Balance", peak.balanceDouble))
    .annotation(position: .top, alignment: .center, spacing: 4) {
        Text(peak.balance, format: .currency(code: "USD"))
            .font(.caption).bold()
    }
```

- `position:` — `.top`/`.bottom`/`.leading`/`.trailing`/`.overlay`/`.automatic` (and `.topLeading`, etc.).
- `overflowResolution:` (iOS 17) keeps the annotation inside the plot: `.annotation(position:overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart)))`.
- Use annotations for value callouts, selection tooltips, and target labels on `RuleMark`s.

<a id="selection"></a>
## Selection (iOS 17)

Bind a `Plottable` value to read what the user taps/drags to. The framework maps the
gesture location to the nearest domain value.

```swift
@State private var selectedDay: Date?

Chart(spend) { row in
    BarMark(x: .value("Day", row.day, unit: .day),
            y: .value("Amount", row.amountDouble))
}
.chartXSelection(value: $selectedDay)          // single value; also chartYSelection, chartAngleSelection (pie)
// range drag: .chartXSelection(range: $dateRange)  // Binding<ClosedRange<P>?>
```

- Signature: `chartXSelection<P: Plottable>(value: Binding<P?>)` (iOS 17+); `chartYSelection` and `chartXSelection(range:)` mirror it. `chartAngleSelection(value:)` selects a `SectorMark`.
- The binding is `Optional` — `nil` means nothing selected (tap outside clears it).
- Render selection UI by overlaying a `RuleMark` at `selectedDay` with an `.annotation`, or by looking up the row and drawing a highlight (see `references/interaction.md`).
- Selection reports a **domain value**, not an index — match it back to your data (`first(where:)`) rather than assuming positions.

<a id="scrolling"></a>
## Scrolling (iOS 17)

Make a chart wider than the screen and scroll it; optionally snap and track position.

```swift
@State private var scrollX: Date = .now

Chart(spend) { row in
    BarMark(x: .value("Day", row.day, unit: .day),
            y: .value("Amount", row.amountDouble))
}
.chartScrollableAxes(.horizontal)
.chartXVisibleDomain(length: 3600 * 24 * 30)              // ~30 days visible (seconds for a Date axis)
.chartScrollPosition(x: $scrollX)                         // read/write the leading edge
.chartScrollTargetBehavior(
    .valueAligned(matching: DateComponents(hour: 0), majorAlignment: .page)
)
```

- `chartScrollableAxes(_:)` — `.horizontal` and/or `.vertical`.
- `chartXVisibleDomain(length:)` sets how much of the domain is on screen (units match the axis: seconds for `Date`, value units for numbers). `chartYVisibleDomain` for vertical.
- `chartScrollPosition(x:)` / `(y:)` — two-way binding to the visible region's leading edge; also `.chartScrollPosition(initialX:)` for a one-time start.
- `chartScrollTargetBehavior(_:)` — `.valueAligned(matching:majorAlignment:)` snaps to calendar/value units, `.valueAligned(unit:)` snaps every N units; `.paging` snaps by page.
- **Annotations can clip** when scrolling — constrain with `overflowResolution` (see [annotations](#annotations)) or the known-issue notes in `references/interaction.md`.

<a id="sector"></a>
## Pie / donut — SectorMark (iOS 17)

`SectorMark` encodes a value as **angular size**; `innerRadius` turns a pie into a donut.

```swift
Chart(byCategory) { slice in
    SectorMark(
        angle: .value("Total", slice.totalDouble),
        innerRadius: .ratio(0.62),        // 0 = pie, >0 = donut
        angularInset: 1.5                 // gap between slices (points)
    )
    .foregroundStyle(by: .value("Category", slice.category))
    .cornerRadius(4)
    .annotation(position: .overlay) { Text(slice.category).font(.caption2) }
}
.chartAngleSelection(value: $selectedAngle)   // iOS 17 selection for sectors
```

- `angle:` is a **magnitude**, not degrees — Charts normalizes each sector proportionally to the total.
- `innerRadius`/`outerRadius` take `.ratio(_)` (0…1 of available radius) or `.fixed(_)`; `angularInset` adds slice spacing.
- Put a total/label in the donut hole with a SwiftUI `.overlay` on the `Chart`, or use `.chartBackground { }`.
- Pie/donut hide magnitude comparisons poorly beyond a few slices — prefer a bar chart for >5 categories.

<a id="plots"></a>
## Vectorized & function plots (iOS 18)

For large datasets, **plot** types (`BarPlot`, `LinePlot`, `PointPlot`, `AreaPlot`,
`RectanglePlot`, `SectorPlot`, `RulePlot`) take the whole collection at once — far faster
than one mark per row — and `LinePlot`/`AreaPlot` also accept a **math function**.

```swift
// Vectorized: one plot for the entire series (KeyPath-based encoding)
Chart {
    LinePlot(spend, x: .value("Day", \.day), y: .value("Balance", \.balanceDouble))
        .foregroundStyle(.blue)
}

// Function plot: y = f(x) over a domain, no data array
Chart {
    LinePlot(x: "x", y: "y") { x in sin(x) }          // trailing closure (Double) -> Double
        .foregroundStyle(.purple)
}
.chartXScale(domain: -.pi ... .pi)

// Parametric form is also available: LinePlot(x:y:t:) driving both x and y from t.
```

- Prefer vectorized plots when a per-row `BarMark`/`LineMark` chart scrolls or renders slowly with thousands of points.
- Function plots are ideal for reference curves (interest/amortization models, break-even), overlaid on real data.
- `AreaPlot(x:y:)` supports a function too; `PointPlot`/`BarPlot` are the vectorized scatter/bar equivalents.

<a id="chart3d"></a>
## Chart3D & SurfacePlot (iOS 26)

`Chart3D` adds a Z axis. `SurfacePlot` renders a mathematical surface `z = f(x, y)`;
`PointMark`/`RuleMark`/`RectangleMark` gain a `z:` for 3D scatter.

```swift
import Charts
import SwiftUI

@State private var pose: Chart3DPose = .default

Chart3D {
    SurfacePlot(x: "Rate", y: "Term", z: "Payment") { rate, term in
        // return Double — e.g. a pricing surface
        monthlyPayment(rate: rate, term: term)
    }
    .foregroundStyle(Chart3DSurfaceStyle.heightBased(yRange: -1...1))
}
.chart3DPose($pose)                          // interactive drag when bound; .front/.top/... presets
.chart3DCameraProjection(.perspective)       // or .orthographic / .automatic
.chartXScale(domain: 0...0.2)
.chartYScale(domain: 12...360)
.chartZScale(domain: 0...5000)
```

- `Chart3D` is available on iOS/iPadOS/macOS/visionOS 26 — **not** tvOS/watchOS. Gate with `if #available(iOS 26, *)`.
- 3D scatter: `PointMark(x:y:z:)` inside `Chart3D`, styled with `foregroundStyle(by:)`.
- `SurfacePlot.roughness(_)` (0…1) and `Chart3DSurfaceStyle.heightBased(_:yRange:)` control surface shading.
- Full pose/camera/styling reference: `references/chart3d.md`.

<a id="fintech"></a>
## Fintech recipes

- **Decimal → Double at the edge only.** `Decimal`/KMP `Money` aren't `Plottable`; expose a `var amountDouble: Double { (amount as NSDecimalNumber).doubleValue }` (or from a KMP `Decimal`) purely for plotting. Keep the `Decimal` for any displayed/aggregated number and format it with `.currency(code:)` (see `swift-formatstyle`) — never do money math in `Double`.
- **Currency axis labels:** format `AxisValueLabel` and annotations with `.currency(code:).notation(.compactName)` so `$12,000` reads as `$12K`.
- **Balance-over-time:** `LineMark` + `.interpolationMethod(.monotone)` + a `RuleMark(y:)` budget line; pin `chartYScale(domain:)` to include 0 and the running max.
- **Sparkline** (list rows): a tiny `Chart` with `.chartXAxis(.hidden)`, `.chartYAxis(.hidden)`, `.chartLegend(.hidden)`, fixed frame.
- **Category breakdown:** `SectorMark` donut with a total in the hole, or a grouped/stacked `BarMark` via `foregroundStyle(by:)`.
- **Hi-lo / range:** `BarMark(x:, yStart:.value("Low", low), yEnd:.value("High", high))` for daily price ranges.
- **Accessibility:** set `.accessibilityLabel`/`.accessibilityValue` per mark and enable the Audio Graph via `.chartOverlay`/system support; see `accessibility-patterns`.

<a id="checklist"></a>
## Correctness checklist

- [ ] `import Charts`; version-gate selection/scrolling (iOS 17), function/vectorized plots (iOS 18), `Chart3D`/`SurfacePlot` (iOS 26) with `#available`.
- [ ] Money kept as `Decimal`/`Money`; converted to `Double` only inside `.value(...)`, never for arithmetic or display.
- [ ] Bar/area value axes include 0 (`chartYScale(domain:)`); no implicitly truncated magnitude axes.
- [ ] Series split with `foregroundStyle(by:)`/`position(by:)`; brand colors pinned via `chartForegroundStyleScale`.
- [ ] Axis labels formatted with a `FormatStyle` (`.currency`/`.dateTime`/`.percent`), not string interpolation.
- [ ] Selection bindings are `Optional` and matched back to data by value (`first(where:)`), not by index.
- [ ] Scrollable charts set `chartXVisibleDomain(length:)`; annotations use `overflowResolution` to avoid clipping.
- [ ] `SectorMark.angle` treated as a magnitude (proportional), not degrees; donut via `innerRadius`.
- [ ] Large series use vectorized plots (`LinePlot`/`BarPlot`/…) instead of per-row marks.
- [ ] `Chart3D` guarded off tvOS/watchOS; `SurfacePlot` closure returns `Double`.
- [ ] Charts have accessibility labels/values; consider Audio Graphs for VoiceOver.
