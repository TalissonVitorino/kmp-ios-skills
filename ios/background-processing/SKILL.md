---
name: background-processing
description: "Schedule and run iOS background work with the BackgroundTasks framework — BGTaskScheduler.register(forTaskWithIdentifier:using:launchHandler:) + submit(_:), BGAppRefreshTaskRequest (short opportunistic refresh), BGProcessingTaskRequest (long maintenance with requiresNetworkConnectivity / requiresExternalPower), and iOS 26 BGContinuedProcessingTask (foreground-started work that continues in the background with system progress UI). Covers Info.plist BGTaskSchedulerPermittedIdentifiers + UIBackgroundModes, expirationHandler + setTaskCompleted(success:), background URLSession downloads, silent content-available push wakeups, and on-device debugging via _simulateLaunchForTaskWithIdentifier. Use when a fintech app must sync balances, refresh tokens, prefetch, or finish an export off-screen. For the APNs payload/registration side use push-notifications; for reading Keychain secrets while the device is locked see swift-security (AfterFirstUnlock); for scene-phase hooks see app-lifecycle."
---

# Background Processing (iOS · BackgroundTasks)

Run work when the app is not on screen. iOS never guarantees a wake — the system
schedules opportunistically against battery, thermal, network, and usage budgets.
Design every task to be **short, idempotent, and resumable**, and to finish
cleanly the instant the system reclaims it.

- **Android/KMP counterpart:** WorkManager (no dedicated skill here) — expose a `commonMain`
  `interface BackgroundSyncScheduler` and bind a BGTaskScheduler `actual` in `iosMain`; see `expect-actual`.
- **Related:** `push-notifications` (APNs payload + registration for `content-available` wakeups) ·
  `swift-security` (Keychain items a locked-device task reads need `...AfterFirstUnlock`) ·
  `app-lifecycle` (scenePhase → schedule on background) · `activitykit` (user-visible ongoing UI, not off-screen compute).

## Contents

- [Pick the right task type](#pick)
- [Project configuration (Info.plist / entitlements)](#config)
- [Register handlers at launch](#register)
- [BGAppRefreshTask — short refresh](#refresh)
- [BGProcessingTask — long maintenance](#processing)
- [BGContinuedProcessingTask (iOS 26)](#continued)
- [Expiration & completion](#expiration)
- [Background URLSession downloads](#urlsession)
- [Silent push (content-available)](#push)
- [Debugging & testing](#debug)
- [Correctness checklist](#checklist)
- References: `references/background-urlsession.md`, `references/debugging-and-testing.md`

<a id="pick"></a>
## Pick the right task type

| Need | Type | Runtime budget | Trigger |
|---|---|---|---|
| Freshen small data (balances, feed head), rotate a token | `BGAppRefreshTaskRequest` | seconds (~30s) | system-chosen, opportunistic |
| Long maintenance: DB compaction, batch upload, ML index, cleanup | `BGProcessingTaskRequest` | minutes | system-chosen; can require power/network |
| Finish a **user-initiated** job off-screen (export statement PDF, encrypt & upload) with live progress | `BGContinuedProcessingTask` (iOS 26+) | until done or evicted | **you** submit from the foreground on a tap |
| Transfer bytes reliably, survive app termination | background `URLSession` | until transfer finishes | system-managed |
| Wake on server event (new transaction) | silent `content-available` push | seconds | APNs delivery |

- App-refresh and processing tasks are **deferred and rationed** — never assume timely or frequent execution. Do essential work when the app is foregrounded; treat background runs as best-effort catch-up.
- Only `BGContinuedProcessingTask` starts promptly, because a user explicitly asked for it.

<a id="config"></a>
## Project configuration

Every identifier you register/submit must be listed in Info.plist, and the matching
background mode must be enabled — otherwise `submit(_:)` throws and `register` traps.

```xml
<!-- Info.plist -->
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>com.example.fintech.refresh</string>       <!-- BGAppRefreshTask -->
    <string>com.example.fintech.maintenance</string>   <!-- BGProcessingTask -->
    <string>com.example.fintech.export</string>         <!-- BGContinuedProcessingTask, exact id -->
    <string>com.example.fintech.export.*</string>       <!-- or a wildcard prefix (continued only) -->
</array>

<key>UIBackgroundModes</key>
<array>
    <string>fetch</string>              <!-- BGAppRefreshTask + legacy background fetch -->
    <string>processing</string>         <!-- BGProcessingTask -->
    <string>remote-notification</string><!-- silent content-available push -->
</array>
```

- Use reverse-DNS identifiers scoped to the bundle id. Keep them as constants — the same string is used at register, submit, Info.plist, and in the debugger.
- `BGContinuedProcessingTask` permits a trailing-`*` **wildcard** so you can encode a per-job suffix (e.g. `com.example.fintech.export.<uuid>`); refresh/processing require exact-match ids.
- GPU-backed continued processing (`.gpu` resource) additionally needs the `com.apple.developer.background-tasks.continued-processing.gpu` entitlement.

<a id="register"></a>
## Register handlers at launch

Register **before launch finishes** — in `application(_:didFinishLaunchingWithOptions:)`,
or synchronously in the SwiftUI `App.init`. Registering after launch traps; a
launch handler that isn't registered means iOS silently drops the task.

```swift
import BackgroundTasks

enum TaskID {
    static let refresh = "com.example.fintech.refresh"
    static let maintenance = "com.example.fintech.maintenance"
}

func registerBackgroundTasks() {
    BGTaskScheduler.shared.register(forTaskWithIdentifier: TaskID.refresh, using: nil) { task in
        handleRefresh(task as! BGAppRefreshTask)
    }
    BGTaskScheduler.shared.register(forTaskWithIdentifier: TaskID.maintenance, using: nil) { task in
        handleMaintenance(task as! BGProcessingTask)
    }
}
```

- `using: nil` runs the launch handler on a private serial background queue. Pass a specific `DispatchQueue` only if you need one; UI work must still hop to `@MainActor`.
- The launch handler is your **only** entry point — the app may be relaunched straight into it with no UI. Keep global setup (DI, DB, Keychain) cheap and side-effect-free at this stage.
- Submit the *next* request each time (see below) — tasks are one-shot; there is no auto-repeat.

<a id="refresh"></a>
## BGAppRefreshTask — short refresh

Opportunistic, seconds-long freshen. Reschedule from **inside** the handler so the
chain continues, and again whenever you enter the background.

```swift
func scheduleRefresh() {
    let request = BGAppRefreshTaskRequest(identifier: TaskID.refresh)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)   // hint, not a guarantee
    do { try BGTaskScheduler.shared.submit(request) }
    catch { print("refresh submit failed: \(error)") }
}

func handleRefresh(_ task: BGAppRefreshTask) {
    scheduleRefresh()                     // 1. queue the next occurrence first

    let work = Task {                     // 2. do the actual work, cancellable
        do {
            try await SyncService.shared.refreshBalances()
            task.setTaskCompleted(success: true)
        } catch is CancellationError {
            task.setTaskCompleted(success: false)
        } catch {
            task.setTaskCompleted(success: false)
        }
    }

    task.expirationHandler = { work.cancel() }   // 3. system is reclaiming — stop now
}
```

- `earliestBeginDate` is a *floor*, not a schedule — the task may run much later, or not until the app is used. Never set it in the past.
- Only one pending request per identifier; re-submitting replaces it.

<a id="processing"></a>
## BGProcessingTask — long maintenance

Minutes-long, deferrable work. Can ask the system to wait for power and/or network.

```swift
func scheduleMaintenance() {
    let request = BGProcessingTaskRequest(identifier: TaskID.maintenance)
    request.requiresNetworkConnectivity = true    // wait for connectivity (uploads/downloads)
    request.requiresExternalPower = true          // run only while charging (heavy CPU/IO)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
    try? BGTaskScheduler.shared.submit(request)
}

func handleMaintenance(_ task: BGProcessingTask) {
    scheduleMaintenance()
    let work = Task {
        do {
            try await Ledger.compactAndReconcile()   // check Task.isCancelled between chunks
            task.setTaskCompleted(success: true)
        } catch { task.setTaskCompleted(success: false) }
    }
    task.expirationHandler = { work.cancel() }
}
```

- `requiresExternalPower = true` also implies the device is likely idle — good for CPU/GPU-heavy jobs, but the user may never charge, so keep a foreground fallback path.
- `requiresNetworkConnectivity = true` lets you do networking inside the task; without it, assume no network. For large transfers prefer a background `URLSession` (below).
- Break long work into **checkpointed chunks** so an expiration mid-run loses at most one chunk, and the next launch resumes.

<a id="continued"></a>
## BGContinuedProcessingTask (iOS 26)

For work a user **starts in the foreground** (tap "Export") that must keep running if
they background the app. The system shows progress in its own UI (Live Activity-style)
and drives it from your `Progress`. You submit it on demand — it does not wait for a
system-chosen window.

```swift
@available(iOS 26.0, *)
func startExport(itemCount: Int) throws {
    let id = "com.example.fintech.export.\(UUID().uuidString)"   // matches the "…export.*" wildcard
    let request = BGContinuedProcessingTaskRequest(
        identifier: id,
        title: "Exporting statements",
        subtitle: "Preparing \(itemCount) items")
    request.strategy = .queue          // .queue (default) waits for resources; .fail throws if unavailable now
    // request.requiredResources = .gpu   // opt into GPU (needs the entitlement); default is .default
    try BGTaskScheduler.shared.submit(request)
}

@available(iOS 26.0, *)
func handleExport(_ task: BGContinuedProcessingTask) {
    let items = ExportQueue.current
    task.progress.totalUnitCount = Int64(items.count)     // REQUIRED: drive progress
    var cancelled = false
    task.expirationHandler = { cancelled = true }

    for (i, item) in items.enumerated() {
        if cancelled { break }
        Exporter.process(item)
        task.progress.completedUnitCount = Int64(i + 1)
        task.updateTitle("Exporting statements", subtitle: "\(i + 1) of \(items.count)")
    }
    task.setTaskCompleted(success: !cancelled)
}
```

- Register its handler at launch like the others: `register(forTaskWithIdentifier:using:)` — the identifier you register can be the **wildcard prefix** (`com.example.fintech.export.*`), and the concrete per-job id is matched to it.
- `BGContinuedProcessingTask` conforms to `ProgressReporting`; it **must** report progress via `task.progress`. The system uses it for the visible UI and to prioritize eviction — tasks reporting little progress are killed first under pressure.
- `updateTitle(_:subtitle:)` refreshes the user-facing text mid-run.
- `strategy` (`SubmissionStrategy`): `.queue` (submission succeeds and waits for resources) vs `.fail` (submission throws immediately if the system can't start it). `requiredResources` (`Resources`): `.default` or `.gpu` (gate with `BGTaskScheduler.supportedResources.contains(.gpu)` before requesting).
- Always originate from an explicit user action; do not use it for silent periodic sync (that's `BGAppRefreshTask`).

<a id="expiration"></a>
## Expiration & completion

Two contract rules the system enforces — violating either gets your app throttled
or terminated:

- **Set `task.expirationHandler` first**, before starting work. It fires on the main-ish
  system path when time is up; from it you must **stop immediately** (cancel the `Task`,
  set a flag, flush a checkpoint). You get only a moment — no new async work.
- **Call `task.setTaskCompleted(success:)` exactly once**, on every path (success, failure,
  cancellation). Never call it twice; never omit it. `success: false` signals iOS to retry
  the same request later; it does **not** auto-reschedule a new one.

```swift
task.expirationHandler = {
    work.cancel()                 // cooperative cancel of the in-flight Task
    // persist a resume checkpoint here if mid-chunk
}
```

- Bridge structured concurrency: wrap the body in a `Task { }`, cancel it in the expiration handler, and check `Task.isCancelled` / `try Task.checkCancellation()` between units of work.
- Keep completion reachable from `defer` or a single exit point so an early `throw` can't skip it.

<a id="urlsession"></a>
## Background URLSession downloads

For reliable transfers that survive suspension **and app termination**, use a
background-configured `URLSession`. The system runs the transfer out-of-process and
relaunches your app to finish.

```swift
let config = URLSessionConfiguration.background(withIdentifier: "com.example.fintech.bg-download")
config.isDiscretionary = true              // let the system pick an optimal (power/wifi) window
config.sessionSendsLaunchEvents = true     // relaunch the app on completion
let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
session.downloadTask(with: url).resume()   // downloadTask/uploadTask only — no completion-handler or data tasks
```

- On relaunch, iOS calls `application(_:handleEventsForBackgroundURLSession:completionHandler:)` (or the SwiftUI `.backgroundTask(.urlSession(...))`). **Store the completion handler**, recreate the *same-identifier* session, and call the stored handler from `urlSessionDidFinishEvents(forBackgroundURLSession:)`.
- Use `URLSessionDownloadDelegate` / `URLSessionTaskDelegate` (delegate, not completion-handler APIs — those are unsupported for background sessions). Move the downloaded file out of the temp location inside `didFinishDownloadingTo` synchronously.
- One session **object per identifier** at a time; reuse it, don't recreate a second live one.
- Full relaunch-handler wiring, upload/resume-data, and delegate methods: `references/background-urlsession.md`.

<a id="push"></a>
## Silent push (content-available)

Wake the app for a few seconds when the server has news (a posted transaction), without
showing a notification. Requires the `remote-notification` background mode.

```json
{ "aps": { "content-available": 1 }, "txnId": "..." }
```

```swift
func application(_ application: UIApplication,
                 didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                 fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
    Task {
        let result = await SyncService.shared.pull(userInfo)   // .newData / .noData / .failed
        completionHandler(result)                              // call within ~30s or get throttled
    }
}
```

- Silent pushes are **rate-limited and coalesced** by iOS — not a real-time channel and not guaranteed delivery. For time-critical UI use a visible/alert push instead; pair silent push with `BGAppRefreshTask` for resilience.
- Must send `content-available: 1` and (for silent) omit `alert`/`sound`/`badge`. Use APNs priority `5` for silent pushes.
- APNs registration, token handling, and payload construction live in `push-notifications`. A locked-device wakeup can only read Keychain items stored `...AfterFirstUnlock*` — see `swift-security`.

## SwiftUI entry points

`.backgroundTask` registers and handles without an AppDelegate (iOS 16+):

```swift
WindowGroup { RootView() }
.backgroundTask(.appRefresh(TaskID.refresh)) {
    await SyncService.shared.refreshBalancesQuietly()   // async closure = the handler
}
.backgroundTask(.urlSession("com.example.fintech.bg-download")) {
    // handle finished background URLSession events
}
```

- You still submit `BGAppRefreshTaskRequest` yourself (e.g. on `scenePhase == .background`) and still list identifiers in Info.plist.
- The closure is `async`; cancellation surfaces as normal Swift `CancellationError` when the system reclaims time.

<a id="debug"></a>
## Debugging & testing

The system rarely runs tasks on demand, so force them with the private scheduler hooks
from the **debugger, on a real device** (they no-op / are unavailable in Simulator),
while the process is paused at a breakpoint after `submit(_:)`:

```
# Launch a pending task now:
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.example.fintech.refresh"]

# Force the expiration handler to fire (test your cleanup path):
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateExpirationForTaskWithIdentifier:@"com.example.fintech.refresh"]
```

- Inspect what's scheduled: `BGTaskScheduler.shared.getPendingTaskRequests { print($0) }` (Swift async: `await ...pendingTaskRequests`).
- `submit(_:)` throws `BGTaskScheduler.Error` — `.notPermitted` (id/mode missing from Info.plist, or Background App Refresh off in Settings), `.tooManyPendingTaskRequests`, `.unavailable`. Log and branch on these.
- Test matrix, Console.app filters, Low Power Mode / Background-App-Refresh-off behavior, and simulating background URLSession completion: `references/debugging-and-testing.md`.

<a id="checklist"></a>
## Correctness checklist

- [ ] Every identifier appears in `BGTaskSchedulerPermittedIdentifiers` **and** its `UIBackgroundModes` entry is set; ids are shared constants.
- [ ] Handlers registered before launch completes (`didFinishLaunchingWithOptions` / `App.init`); never after.
- [ ] `expirationHandler` set **before** work starts; it stops work immediately and persists a checkpoint.
- [ ] `setTaskCompleted(success:)` called **exactly once** on every path (success/failure/cancel).
- [ ] Refresh/processing requests re-submitted from inside the handler and on entering background — no reliance on auto-repeat.
- [ ] `earliestBeginDate` treated as a hint, never in the past; work is idempotent and resumable across partial runs.
- [ ] Long work is chunked and checks `Task.isCancelled`; UI updates hop to `@MainActor`.
- [ ] `BGProcessingTask`: `requiresNetworkConnectivity` / `requiresExternalPower` match the workload; foreground fallback exists if conditions never occur.
- [ ] `BGContinuedProcessingTask` originates from a user action, drives `task.progress`, and (for `.gpu`) checks `supportedResources` + holds the entitlement.
- [ ] Background `URLSession`: `background(withIdentifier:)` + `sessionSendsLaunchEvents`, delegate-based, relaunch completion handler stored and invoked; one live session per id.
- [ ] Silent push sends `content-available: 1`, calls `completionHandler` within the window; treated as best-effort, not guaranteed/real-time.
- [ ] Locked-device tasks read only `...AfterFirstUnlock*` Keychain items (`swift-security`); no secrets logged.
- [ ] Verified on device via `_simulateLaunchForTaskWithIdentifier` / `_simulateExpirationForTaskWithIdentifier`, and against Background App Refresh disabled.
