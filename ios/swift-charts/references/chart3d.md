# Chart3D & SurfacePlot (iOS 26)

3D charting added in the iOS 26 era. Available on iOS/iPadOS 26, Mac Catalyst 26,
macOS 26, visionOS 26 — **not** tvOS or watchOS. Always gate with `if #available(iOS 26, *)`.

## Container & axes

```swift
import Charts
import SwiftUI

Chart3D {
    // marks / plots with x, y, AND z
}
.chartXScale(domain: xRange)
.chartYScale(domain: yRange)
.chartZScale(domain: zRange)        // Z is the new third scale
```

- `Chart3D` accepts 3D-aware marks (`PointMark`, `RuleMark`, `RectangleMark` with a `z:`) and `SurfacePlot`.
- All three of `chartXScale` / `chartYScale` / `chartZScale` apply.

## SurfacePlot — z = f(x, y)

```swift
Chart3D {
    SurfacePlot(x: "X", y: "Y", z: "Z") { x, y in
        sin(x) * cos(y)                      // must return Double
    }
    .foregroundStyle(Chart3DSurfaceStyle.heightBased(yRange: -1...1))
    .roughness(0.3)                          // 0 = smooth/glossy, 1 = rough/matte
}
```

- The axis-name strings label the three axes; the trailing closure maps `(Double, Double) -> Double`.
- `Chart3DSurfaceStyle.heightBased(yRange:)` colors by height; a custom-gradient overload
  `Chart3DSurfaceStyle.heightBased(_ gradient:, yRange:)` is also available.
- `.foregroundStyle(Color)` applies a flat color instead of height shading.

## 3D scatter

```swift
Chart3D {
    ForEach(assets) { a in
        PointMark(
            x: .value("Risk", a.risk),
            y: .value("Return", a.expectedReturn),
            z: .value("Liquidity", a.liquidity)
        )
        .foregroundStyle(by: .value("Class", a.assetClass))
    }
}
```

## Pose & camera

```swift
@State private var pose: Chart3DPose = .default

Chart3D { /* ... */ }
    .chart3DPose($pose)                       // interactive: drag rotates and writes back
    // .chart3DPose(.front)                    // static preset, non-interactive
    .chart3DCameraProjection(.perspective)    // .automatic | .orthographic | .perspective
```

- `Chart3DPose` presets: `.default`, `.front`, `.back`, `.top`, `.bottom`, `.left`, `.right`.
- Custom pose: `Chart3DPose(azimuth: .degrees(45), inclination: .degrees(30))`.
- Bind (`$pose`) for user-rotatable charts; pass a value for a fixed viewpoint.
- `.orthographic` removes perspective foreshortening (good for reading exact positions);
  `.perspective` reads as more naturally 3D.

## Guidance

- 3D charts are hard to read precisely — use them for shape/trend intuition (a pricing or
  risk surface), and pair with a 2D slice or a value readout for exact numbers.
- Verify each symbol against the current SDK: the 3D API is new and evolving; some styling
  overloads may change between betas.
