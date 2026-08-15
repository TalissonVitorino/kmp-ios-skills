---
name: metrickit
description: "On-device production telemetry for an iOS/fintech app with MetricKit — subscribe via MXMetricManager.shared.add(_:) and MXMetricManagerSubscriber didReceive(_:) for MXMetricPayload (applicationLaunch/responsiveness-hang/memory/cpu/disk/animation/cellularCondition/appExit) and MXDiagnosticPayload (MXCrashDiagnostic/MXHangDiagnostic/MXCPUExceptionDiagnostic/MXDiskWriteExceptionDiagnostic/MXAppLaunchDiagnostic + MXCallStackTree), custom mxSignpost metrics, durable JSON export/upload of daily payloads, and the new async MetricManager reports API (iOS 27 / WWDC26). Use for field crash/hang/launch/battery diagnostics and release-over-release regression monitoring. For local Instruments/LLDB profiling use debugging-instruments; to fan payloads into an event pipeline use analytics-patterns; to bridge telemetry into shared code use kmp-logging; for the privacy manifest at submission use app-store-review."
---

# MetricKit (iOS production telemetry)

Field-collected power/performance metrics and crash/hang/exception diagnostics,
aggregated **on-device** by the system and delivered to your app — no third-party
SDK, no per-event network cost. Grounded in Apple's MetricKit framework.

- **On-device & privacy-preserving:** the OS aggregates over a 24h window and hands you a payload; nothing leaves the device until *you* upload it. No PII, no user identifiers — safe for a fintech privacy posture. Still declare any upload/collection in the privacy manifest (see `app-store-review`).
- **Delivery cadence:** subscriber callbacks fire **at most once per day**, on a **background queue**, and only when the app has been foregrounded since the last delivery. Diagnostics can also arrive right after the next launch following a crash/hang.
- **Two APIs:** the stable delegate-based **`MXMetricManager`** (iOS 13+, crashes/diagnostics iOS 14+) — the default for the iOS 26 era — and the new async **`MetricManager`** (iOS 27, WWDC26) covered in `references/new-metricmanager.md`.
- **Not a profiler.** MetricKit tells you *what regressed in the field, aggregated*; to root-cause locally with call trees and allocations use `debugging-instruments`.

## Contents

- [Subscribe](#subscribe)
- [MXMetricPayload — the metrics](#metrics)
- [Custom metrics with mxSignpost](#signpost)
- [MXDiagnosticPayload — crashes/hangs/exceptions](#diagnostics)
- [Extended launch diagnostics](#launch)
- [Durable export & upload](#export)
- [Testing / simulating payloads](#testing)
- [KMP boundary](#kmp)
- [New async MetricManager (iOS 27)](#ios27)
- [Correctness checklist](#checklist)
- References: `references/payload-fields.md`, `references/new-metricmanager.md`

<a id="subscribe"></a>
## Subscribe

Register **one long-lived subscriber at launch** — a payload delivered before you
subscribe is lost. A singleton owned by the app delegate / `App` is the right scope.

```swift
import MetricKit

final class TelemetrySubscriber: NSObject, MXMetricManagerSubscriber {
    static let shared = TelemetrySubscriber()

    func start() { MXMetricManager.shared.add(self) }   // idempotent-safe to guard yourself
    func stop()  { MXMetricManager.shared.remove(self) }

    // Called on a BACKGROUND queue, ~once/day. Both methods are optional.
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads { PayloadStore.persist(payload.jsonRepresentation()) }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {   // iOS 14+
        for payload in payloads { PayloadStore.persist(payload.jsonRepresentation()) }
    }
}
```

- `MXMetricManager.shared` is the singleton; `add(_:)` / `remove(_:)` manage subscribers.
- Register early (`application(_:didFinishLaunchingWithOptions:)` or `App.init`) — **not** in a view that appears later.
- **Do the minimum on the callback thread:** persist the raw `jsonRepresentation()` immediately, then process/upload off the critical path. Never touch UIKit here without hopping to `@MainActor`.
- Catch-up: `MXMetricManager.shared.pastPayloads: [MXMetricPayload]` and `pastDiagnosticPayloads: [MXDiagnosticPayload]` hold recent payloads the system already generated — read them at launch so nothing is missed across app updates.

<a id="metrics"></a>
## MXMetricPayload — the metrics

Every metric group is **optional** (`nil` when the OS collected nothing for it that
day). Each metric bundles histograms / averages, not single samples. Exact types
(verified against the SDK headers):

| Property | Type | What it covers |
|---|---|---|
| `applicationLaunchMetrics` | `MXAppLaunchMetric?` | time-to-first-draw, resume time, optimized launch |
| `applicationResponsivenessMetrics` | `MXAppResponsivenessMetric?` | **hang time** histogram (main-thread unresponsiveness) |
| `applicationTimeMetrics` | `MXAppRunTimeMetric?` | foreground/background/audio time |
| `memoryMetrics` | `MXMemoryMetric?` | peak & suspended memory |
| `cpuMetrics` | `MXCPUMetric?` | cumulative CPU time / instructions |
| `gpuMetrics` | `MXGPUMetric?` | cumulative GPU time |
| `diskIOMetrics` | `MXDiskIOMetric?` | logical writes |
| `displayMetrics` | `MXDisplayMetric?` | average pixel luminance (APL) |
| `animationMetrics` | `MXAnimationMetric?` | scroll **hitch** time ratio |
| `applicationExitMetrics` | `MXAppExitMetric?` | normal vs abnormal fg/bg exit counts (watchdog, OOM, etc.) |
| `cellularConditionMetrics` | `MXCellularConditionMetric?` | time spent on each cellular condition bar |
| `locationActivityMetrics` | `MXLocationActivityMetric?` | time at each location accuracy |
| `networkTransferMetrics` | `MXNetworkTransferMetric?` | wifi/cell up/down bytes |
| `signpostMetrics` | `[MXSignpostMetric]?` | your custom intervals (see below) |
| `metaData` | `MXMetaData?` | device/OS/region, app build |

- There is **no** `applicationHangTimeMetrics` property — hang data lives in `applicationResponsivenessMetrics.histogrammedApplicationHangTime`.
- Histograms are `MXHistogram<UnitType>`; enumerate `.bucketEnumerator` for `MXHistogramBucket` (`bucketStart` / `bucketEnd` / `bucketCount`). Values are typed `Measurement`s (e.g. `Measurement<UnitDuration>`, `Measurement<UnitInformationStorage>`).
- `metaData` carries `regionFormat`, `osVersion`, `deviceType`, `applicationBuildVersion`, `platformArchitecture` — key for **release-over-release** comparison. Always segment metrics by build.

```swift
let peak = payload.memoryMetrics?.peakMemoryUsage                 // Measurement<UnitInformationStorage>
let cpu  = payload.cpuMetrics?.cumulativeCPUTime                  // Measurement<UnitDuration>
let ttfd = payload.applicationLaunchMetrics?.histogrammedTimeToFirstDraw   // MXHistogram<UnitDuration>
let hitch = payload.animationMetrics?.scrollHitchTimeRatio       // Double-like ratio
let build = payload.metaData?.applicationBuildVersion
```

Full field-by-field breakdown per metric type is in `references/payload-fields.md`.

<a id="signpost"></a>
## Custom metrics with mxSignpost

Instrument a critical span (payment authorization, ledger sync, chart render) and
MetricKit returns **aggregated** duration / CPU / memory / logical-writes / hitch
telemetry for it in the daily payload — no per-run event to store.

```swift
import MetricKit
import os

// One reusable OSLog handle per subsystem category.
let payLog = MXMetricManager.makeLogHandle(category: "payment")

func authorize() {
    mxSignpost(.begin, log: payLog, name: "authorizeCharge")
    defer { mxSignpost(.end, log: payLog, name: "authorizeCharge") }
    // ... work whose field cost you want measured ...
}
```

- `MXMetricManager.makeLogHandle(category:) -> OSLog` — use this handle, **not** a plain `OSLog`, so the interval is captured into `payload.signpostMetrics`.
- `mxSignpost(_ type: OSSignpostType, log: OSLog, name: StaticString, signpostID: OSSignpostID = .exclusive, _ format: StaticString = "", _ args: CVarArg...)`. Pair `.begin` / `.end` with the **same** `name` (and matching `signpostID` if the span can overlap itself — allocate one per concurrent instance).
- Animation/hitch spans: `mxSignpostAnimationIntervalBegin(log:name:signpostID:)` … `mxSignpost(.end, …)` to collect a hitch-rate ratio for a custom animation.
- Read back as `payload.signpostMetrics` → each `MXSignpostMetric` exposes `signpostCategory`, `signpostName`, `totalCount`, and `signpostIntervalData` (histogrammed duration + CPU/memory/logical-writes). Match on `(category, name)`.
- Keep signpost `name`s a **small fixed set** of `StaticString`s — they are dimensions, not free-form values, and high cardinality dilutes the aggregate.

<a id="diagnostics"></a>
## MXDiagnosticPayload — crashes / hangs / exceptions

`MXDiagnosticPayload` groups arrays of concrete diagnostics; each carries a
symbolicated-on-device `MXCallStackTree`. Types verified against the SDK:

```swift
func didReceive(_ payloads: [MXDiagnosticPayload]) {
    for payload in payloads {
        payload.crashDiagnostics?.forEach(handleCrash)          // [MXCrashDiagnostic]?
        payload.hangDiagnostics?.forEach(handleHang)            // [MXHangDiagnostic]?
        payload.cpuExceptionDiagnostics?.forEach(handleCPU)     // [MXCPUExceptionDiagnostic]?
        payload.diskWriteExceptionDiagnostics?.forEach(handleDisk) // [MXDiskWriteExceptionDiagnostic]?
        payload.appLaunchDiagnostics?.forEach(handleLaunch)     // [MXAppLaunchDiagnostic]? (iOS 16+)
    }
}
```

- **`MXCrashDiagnostic`** — `callStackTree: MXCallStackTree`, `terminationReason: String?`, `virtualMemoryRegionInfo: String?`, `exceptionType: NSNumber?`, `exceptionCode: NSNumber?`, `signal: NSNumber?`; `exceptionReason: MXCrashDiagnosticObjectiveCExceptionReason?` (iOS 17+, for uncaught `NSException`).
- **`MXHangDiagnostic`** — `callStackTree`, `hangDuration: Measurement<UnitDuration>` (main thread blocked ≥ threshold).
- **`MXCPUExceptionDiagnostic`** — `callStackTree`, `totalCPUTime`, `totalSampledTime` (sustained-CPU watchdog trips).
- **`MXDiskWriteExceptionDiagnostic`** — `callStackTree`, `totalWritesCaused: Measurement<UnitInformationStorage>` (excessive disk-write watchdog).
- Every `MXDiagnostic` base also has `metaData: MXMetaData` and `applicationVersion` — segment crashes by build to catch a regression in a specific release.

### MXCallStackTree

- `callStackTree.jsonRepresentation() -> Data` is the durable form to upload; the on-device tree is already symbolicated for **your** frames.
- The JSON is a forest of per-thread frames with `binaryName`, `address`, `offsetIntoBinaryTextSegment`, and `subFrames`. Reconstruct/re-symbolicate server-side against the matching dSYM when you need OS-frame symbols.
- Group crashes by a signature hash of the top N app frames (`terminationReason` + leaf frames) rather than raw text, so the same bug clusters across builds.

<a id="launch"></a>
## Extended launch diagnostics (iOS 16+)

`MXAppLaunchDiagnostic` reports launches the system deemed **prolonged** (slow
cold starts users would feel), separate from the launch *histogram* in
`applicationLaunchMetrics`.

- Properties: `callStackTree` (where startup time went) + `launchDuration: Measurement<UnitDuration>`.
- Use the diagnostic to see *which* work stalled a specific slow launch; use the metric histogram to trend launch time across the fleet. Move blocking work off the launch path (`background-processing`) when these appear.

<a id="export"></a>
## Durable export & upload

Payloads arrive at most daily, offline-first, and must survive termination
**before** they reach your backend. Never upload synchronously from the callback.

- **Persist first, upload later.** In the callback, write `payload.jsonRepresentation()` (metrics) / `payload.jsonRepresentation()` (diagnostics) to a file in Application Support with a stable id; return fast.
- **Idempotency:** derive a dedupe key from `metaData` + `timeStampBegin`/`timeStampEnd` (payloads are per-window) so a retried upload doesn't double-count. The window bounds also let the backend place the data on a timeline.
- **Upload out-of-band:** flush the persisted queue via a **background `URLSession`** (or a `BGProcessingTask`, see `background-processing`) so it completes even if the user backgrounds the app. Delete a file only after a 2xx.
- **Batch:** JSON payloads are small; send them together, gzip’d. Don’t hold them only in memory and don’t block launch on the flush.
- To route the parsed metrics into your existing event/analytics pipeline instead of a raw blob store, map them to typed events in `analytics-patterns`; keep the raw JSON too for re-derivation.

```swift
enum PayloadStore {
    static func persist(_ json: Data) {
        let url = dir.appendingPathComponent("\(UUID().uuidString).json")
        try? json.write(to: url, options: .atomic)   // pick up on next launch + flush
    }
}
```

<a id="testing"></a>
## Testing / simulating payloads

- **Debug menu → Simulate MetricKit Payloads** (device running a Debug build attached to Xcode) delivers a synthetic payload immediately so you can exercise your parsing/persist/upload path without waiting 24h.
- On a real device, run overnight and foreground the app the next day to get a genuine payload; the simulator does **not** generate real MetricKit data.
- Unit-test your handler by decoding a saved `jsonRepresentation()` fixture — treat the JSON schema as the contract, not the live objects.
- Assert your dedupe key and signature-hash logic against fixtures from **two builds** so regressions segment correctly.

<a id="kmp"></a>
## KMP boundary

MetricKit is iOS-only and has no Android analogue (Android uses Play Vitals /
`ApplicationExitInfo`). Keep it in `iosMain`/the iOS app and feed a **normalized**
telemetry event into shared code:

- Parse `MXMetricPayload` / `MXDiagnosticPayload` on the Swift side, map to a `commonMain` `@Serializable` telemetry model, and hand it to a shared reporter interface (see `expect-actual`, `shared-models`).
- For a unified log/telemetry sink across platforms, bridge into Kermit via `kmp-logging`. Don't try to model MetricKit types in shared code — expose only your normalized event.

<a id="ios27"></a>
## New async MetricManager (iOS 27, WWDC26)

iOS 27 adds a modern, `Codable`, `async`-stream API (`MetricManager`) alongside
`MXMetricManager`; Apple recommends migrating to it for new capabilities
(state-aware metrics, memory-exception diagnostics, crash `terminationCategory`).
It is beta as of this writing — keep `MXMetricManager` as the shipping path and
gate the new API behind `#available`. Shape, symbols, and adoption notes are in
`references/new-metricmanager.md`.

<a id="checklist"></a>
## Correctness checklist

- [ ] Exactly one long-lived subscriber registered at launch (`App.init` / `didFinishLaunching`), not in a screen.
- [ ] Callback body is minimal and thread-safe — persist `jsonRepresentation()`, defer processing; no UIKit without `@MainActor`.
- [ ] `pastPayloads` / `pastDiagnosticPayloads` drained at launch so nothing is lost across updates.
- [ ] Every metric group treated as optional; histograms/averages read, not single samples.
- [ ] Metrics and crashes segmented by `metaData.applicationBuildVersion` for release-over-release comparison.
- [ ] Custom spans use `MXMetricManager.makeLogHandle(category:)` + paired `mxSignpost(.begin/.end)` with a small fixed set of `StaticString` names.
- [ ] Diagnostics read `callStackTree.jsonRepresentation()`; crashes grouped by a stable top-frame signature, not raw text.
- [ ] Payloads persisted before upload; uploaded via background session/`BGProcessingTask`; deleted only after 2xx; deduped by window bounds.
- [ ] Any upload/collection reflected in the privacy manifest (`app-store-review`).
- [ ] Handler validated against saved JSON fixtures (incl. two builds) and Xcode's Simulate MetricKit Payloads.
- [ ] New `MetricManager` (iOS 27) adoption gated behind `#available`, with `MXMetricManager` as the fallback.
