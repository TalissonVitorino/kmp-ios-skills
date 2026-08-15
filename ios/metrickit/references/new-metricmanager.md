# New async MetricManager (iOS 27 / WWDC26)

iOS 27 introduces `MetricManager` — a modern, `Codable`, `async`-stream MetricKit
API alongside the still-supported `MXMetricManager`. Apple's guidance ("Meet the
new MetricKit", WWDC26 session 222) is to migrate to it for the new capabilities.

> **Status: beta.** The symbol shapes below come from the WWDC26 session, not a
> shipped SDK header. Treat exact names (`intervalEntries`, `fullDayEntry`,
> `metricGroup`, the `.peakMemory`/`.crash` case spellings, `terminationCategory`,
> the StateReporting initializer) as **provisional** — verify against the iOS 27
> SDK before shipping, and gate all adoption behind `#available(iOS 27, *)` with
> `MXMetricManager` as the fallback.

## Why migrate

- **Async streams** instead of a delegate — `for await` metric and diagnostic reports.
- **`Codable`** `MetricReport` / `DiagnosticReport` — JSON export without `jsonRepresentation()` glue.
- **State-aware metrics** — intersect metrics with app-defined states via the StateReporting framework (e.g. "which tab was open").
- New signals: memory-exception diagnostics, Metal frame-rate metric, crash `terminationCategory`.

## Shape (provisional)

```swift
import MetricKit

// Create at startup and keep alive — streams stop delivering if it deallocates.
let manager = MetricManager()

// Metric reports
Task {
    for await report in manager.metricReports {          // async sequence
        for entry in report.intervalEntries {            // interval buckets
            let memory = entry.values.filter { $0.metricGroup == .memory }
            for metric in memory {
                switch metric {
                case .peakMemory(let peak): record(peak)
                default: break
                }
            }
        }
        // report.intervalEntries.fullDayEntry — the aggregated 24h bucket
    }
}

// Diagnostic reports
Task {
    for await report in manager.diagnosticReports {
        switch report.result {
        case .crash(let crash):
            record(crash.callStackTree, crash.terminationReason, crash.terminationCategory)
        case .hang(let hang):
            record(hang)
        default: break
        }
    }
}
```

- **Metric groups:** `.cpu`, `.memory`, `.display`, `.gpu`, … — metrics are enumerated per group rather than as fixed payload properties.
- **State reporting:** `MetricManager(enabledStateReportingDomains: [StateReportingDomain("com.app.tabs")])` (imports the `StateReporting` framework) to attribute metrics to app states.

## Coexistence

- Don't run both APIs for the same data unless you're validating parity during migration.
- Subscribe to **both** `metricReports` and `diagnosticReports` at launch; a report generated before subscription is lost, same as the legacy API.
- Keep the durable persist-then-upload discipline from the main skill — `Codable` reports encode directly to JSON for the same offline queue.
