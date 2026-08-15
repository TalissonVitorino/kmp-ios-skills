# Debugging & testing background tasks

The system's scheduler is deliberately unpredictable — you cannot wait for a "natural"
run in a test loop. Force execution with the private simulation hooks and verify each
contract path deterministically.

## Forcing a launch / expiration (device only)

1. Run the app on a **physical device** (these SPIs are unavailable in the Simulator).
2. Trigger `BGTaskScheduler.shared.submit(request)` for the identifier under test.
3. Pause execution (breakpoint or Xcode's pause button).
4. In the LLDB console:

```
# Run the pending task's launch handler now:
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.example.fintech.refresh"]

# Fire the expirationHandler to test cleanup/checkpointing:
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateExpirationForTaskWithIdentifier:@"com.example.fintech.refresh"]
```

5. Resume — the launch handler runs and hits your breakpoints.

- The task must be **pending** (submitted, not yet run) for `_simulateLaunch` to do anything.
- These are private symbols for debugging only; never ship a code path that calls them.
- `BGContinuedProcessingTask` starts from a foreground `submit` in normal use, so exercise it directly by tapping the action, then background the app to watch it continue and to test the expiration path.

## Inspecting scheduled state

```swift
BGTaskScheduler.shared.getPendingTaskRequests { requests in
    for r in requests { print(r.identifier, r.earliestBeginDate as Any) }
}
// Swift concurrency:
let pending = await BGTaskScheduler.shared.pendingTaskRequests
```

Cancel while iterating a test:

```swift
BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: "com.example.fintech.refresh")
BGTaskScheduler.shared.cancelAllTaskRequests()
```

## submit(_:) errors — `BGTaskScheduler.Error.Code`

| Code | Cause | Fix |
|---|---|---|
| `.notPermitted` | id/mode not in Info.plist, wrong entitlement, or **Background App Refresh disabled** in Settings | verify plist + Settings › General › Background App Refresh |
| `.tooManyPendingTaskRequests` | already-pending request for this id (or too many overall) | one pending per id; re-submitting replaces |
| `.unavailable` | scheduling unavailable in this context (e.g. extension) | schedule from the app process |

```swift
do { try BGTaskScheduler.shared.submit(request) }
catch let error as BGTaskScheduler.Error where error.code == .notPermitted {
    // Most common in dev: identifier missing from Info.plist, or user turned off Background App Refresh.
}
```

## Test matrix

- **Happy path:** simulate launch → work completes → `setTaskCompleted(success: true)`; assert the next request is re-submitted.
- **Expiration:** simulate expiration mid-work → `Task` cancels, checkpoint persists, `setTaskCompleted(success: false)`; next launch resumes from the checkpoint.
- **Failure:** force the work to throw → `setTaskCompleted(success: false)`; confirm no crash and completion still called exactly once.
- **Background App Refresh OFF:** toggle it off in Settings → confirm `submit` handles `.notPermitted` gracefully and the foreground fallback still syncs.
- **Low Power Mode:** discretionary/processing tasks are heavily deferred — confirm the app still functions with no background runs at all.
- **Relaunch:** for background `URLSession`, kill the app after starting a transfer, let it finish, confirm the app is relaunched into `handleEventsForBackgroundURLSession` and the stored completion handler is called.

## Observing in Console / os_log

- Filter Console.app (device connected) by your subsystem, plus system logs from the `BackgroundTasks`/`dasd` (Duet Activity Scheduler) subsystems to see why a task was deferred (thermal, battery, budget).
- Emit an `os_log`/`Logger` line at handler entry, each checkpoint, and completion so a background run leaves a trail even with no debugger attached. Never log secrets or PII.
- The scheduler weighs recent app usage, battery, thermal state, and per-app budgets — a task not running is usually the system rationing, not a bug. Validate correctness with the simulate hooks, not by waiting.
