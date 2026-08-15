# MXMetricPayload — field reference

Per-metric-type accessors on `MXMetricPayload`. All group properties are optional
(`nil` when the OS collected nothing that day). Types below match the SDK headers;
histogram buckets and `Measurement` units are stable since iOS 14 unless noted.
Confirm any single accessor against the current SDK header before relying on it —
Apple has added fields per release (e.g. instructions/optimized-launch/APL).

## Payload envelope

- `timeStampBegin: Date`, `timeStampEnd: Date` — the 24h window; use both as the dedupe/timeline key.
- `latestApplicationVersion: String`, `includesMultipleApplicationVersions: Bool` — a payload can span an app update; if `true`, don't attribute it to a single build.
- `metaData: MXMetaData?` — `applicationBuildVersion`, `osVersion`, `deviceType`, `regionFormat`, `platformArchitecture`, `pid` (`isTestFlightApp` on newer SDKs). Segment everything by build.
- `jsonRepresentation() -> Data`, `dictionaryRepresentation() -> [AnyHashable: Any]` — durable/serializable forms.

## Histograms

Most time/count distributions are `MXHistogram<UnitType>`:

```swift
if let h = payload.applicationLaunchMetrics?.histogrammedTimeToFirstDraw {
    for bucket in h.bucketEnumerator {                 // MXHistogramBucket
        let b = bucket as! MXHistogramBucket
        // b.bucketStart, b.bucketEnd  (Measurement<UnitDuration>), b.bucketCount (Int)
    }
    _ = h.totalBucketCount
}
```

## `MXAppLaunchMetric` (`applicationLaunchMetrics`)

- `histogrammedTimeToFirstDraw: MXHistogram<UnitDuration>` — cold-launch to first frame.
- `histogrammedApplicationResumeTime: MXHistogram<UnitDuration>` — warm resume.
- `histogrammedOptimizedTimeToFirstDraw: MXHistogram<UnitDuration>` — prewarmed launches (iOS 15.2+).
- `histogrammedExtendedLaunch: MXHistogram<UnitDuration>` — extended launch (iOS 16+); pairs with `MXAppLaunchDiagnostic`.

## `MXAppResponsivenessMetric` (`applicationResponsivenessMetrics`)

- `histogrammedApplicationHangTime: MXHistogram<UnitDuration>` — main-thread hang durations. This is the "hang" metric (there is no separate `applicationHangTimeMetrics`).

## `MXAppRunTimeMetric` (`applicationTimeMetrics`)

- `cumulativeForegroundTime`, `cumulativeBackgroundTime`, `cumulativeBackgroundAudioTime`, `cumulativeBackgroundLocationTime` — all `Measurement<UnitDuration>`.

## `MXMemoryMetric` (`memoryMetrics`)

- `peakMemoryUsage: Measurement<UnitInformationStorage>`.
- `averageSuspendedMemory: MXAverage<UnitInformationStorage>` — `.averageMeasurement`, `.sampleCount`, `.standardDeviation`.

## `MXCPUMetric` (`cpuMetrics`)

- `cumulativeCPUTime: Measurement<UnitDuration>`.
- `cumulativeCPUInstructions: Measurement<Unit>` (iOS 14+) — better cross-CPU normalization than time.

## `MXGPUMetric` (`gpuMetrics`)

- `cumulativeGPUTime: Measurement<UnitDuration>`.

## `MXDiskIOMetric` (`diskIOMetrics`)

- `cumulativeLogicalWrites: Measurement<UnitInformationStorage>`.

## `MXDisplayMetric` (`displayMetrics`)

- `averagePixelLuminance: MXAverage<MXUnitAveragePixelLuminance>?` — nil on devices without APL sensing.

## `MXAnimationMetric` (`animationMetrics`)

- `scrollHitchTimeRatio: Measurement<Unit>` (iOS 14+) — hitch time per scrolling second; the fleet-wide analogue of Instruments' Animation Hitches.

## `MXAppExitMetric` (`applicationExitMetrics`)

- `foregroundExitData: MXForegroundExitData`, `backgroundExitData: MXBackgroundExitData`.
- Foreground counts: `cumulativeNormalAppExitCount`, `cumulativeAbnormalExitCount`, `cumulativeMemoryResourceLimitExitCount`, `cumulativeBadAccessExitCount`, `cumulativeIllegalInstructionExitCount`, `cumulativeAppWatchdogExitCount`.
- Background adds: `cumulativeMemoryPressureExitCount`, `cumulativeSuspendedWithLockedFileExitCount`, `cumulativeCPUResourceLimitExitCount`, `cumulativeBackgroundTaskAssertionTimeoutExitCount`, plus the normal/abnormal/watchdog counts. Watch OOM (`MemoryResourceLimit` / `MemoryPressure`) and `AppWatchdog` — the crash-free-but-killed cases MXCrashDiagnostic won't show.

## `MXCellularConditionMetric` (`cellularConditionMetrics`)

- `histogrammedCellularConditionTime: MXHistogram<MXUnitSignalBars>` — time on each signal-bar bucket; correlate with network failures.

## `MXLocationActivityMetric` (`locationActivityMetrics`)

- `cumulativeBestAccuracyTime`, `cumulativeBestAccuracyForNavigationTime`, `cumulativeNearestTenMetersAccuracyTime`, `cumulativeHundredMetersAccuracyTime`, `cumulativeKilometerAccuracyTime`, `cumulativeThreeKilometersAccuracyTime` — all `Measurement<UnitDuration>`.

## `MXNetworkTransferMetric` (`networkTransferMetrics`)

- `cumulativeWifiUpload`, `cumulativeWifiDownload`, `cumulativeCellularUpload`, `cumulativeCellularDownload` — all `Measurement<UnitInformationStorage>`.

## `MXSignpostMetric` (`signpostMetrics: [MXSignpostMetric]`)

- `signpostCategory: String`, `signpostName: String`, `totalCount: Int`.
- `signpostIntervalData: MXSignpostIntervalData?` with:
  - `histogrammedSignpostDuration: MXHistogram<UnitDuration>?`
  - `signpostCumulativeCPUTime: Measurement<UnitDuration>?`
  - `signpostAverageMemory: MXAverage<UnitInformationStorage>?`
  - `signpostCumulativeLogicalWrites: Measurement<UnitInformationStorage>?`
  - `signpostCumulativeHitchTimeRatio: Measurement<Unit>?` (for animation-interval signposts)
- Match on the `(signpostCategory, signpostName)` you emitted via `MXMetricManager.makeLogHandle(category:)`.
