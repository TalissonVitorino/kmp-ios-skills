# Call Directory extension — setup, staging, limits

Deep reference for `CXCallDirectoryProvider` caller ID + blocking. The main skill
shows the handler; this covers target setup, host↔extension data flow, reloads,
and the constraints that make extensions fail silently.

## Target & entitlements

- Add a **Call Directory Extension** target (its own bundle id, e.g. `app.bundle.CallDirectory`).
- Share data with the host app via an **App Group** — the extension cannot do networking or heavy computation; it only reads a pre-built, pre-sorted dataset.
- The user must enable it: **Settings → Apps → Phone → Call Blocking & Identification** (older iOS: Settings → Phone → Call Blocking & Identification). Nothing shows until enabled.

## Host app: stage data, then reload

The host app owns the source of truth (backend sync, user block list). It writes a sorted, extension-readable store into the App Group container, then asks the OS to reload:

```swift
import CallKit

let identifier = "app.bundle.CallDirectory"   // the EXTENSION's bundle id

CXCallDirectoryManager.sharedInstance.reloadExtension(withIdentifier: identifier) { error in
    if let error { /* log; common: .unexpectedIncrementalRemoval, out-of-order, extension disabled */ }
}

// Is the user's toggle on?
CXCallDirectoryManager.sharedInstance.getEnabledStatusForExtension(withIdentifier: identifier) { status, error in
    switch status {
    case .enabled:      break
    case .disabled:     break   // prompt the user to enable it in Settings
    case .unknown:      break
    @unknown default:   break
    }
}
```

- The extension runs **on the system's schedule** (after a reload request, or when the OS decides), out-of-process. You cannot call into it directly.
- Store numbers already sorted ascending so the extension just streams them in order — sorting inside the extension risks blowing the memory budget.

## Incremental vs full — get this right

```swift
override func beginRequest(with context: CXCallDirectoryExtensionContext) {
    context.delegate = self
    if context.isIncremental {
        // Apply only changes since the last SUCCESSFUL reload.
        // add* for new/changed, remove*(withPhoneNumber:) for gone.
        // remove* is ONLY valid here — calling it in a full request errors.
    } else {
        // Full rebuild: add every current entry. No remove* calls.
    }
    context.completeRequest()
}
```

- `context.isIncremental` is chosen by the OS. On the first load after install, or after certain failures, it requests a **full** rebuild — you must be able to emit the entire dataset.
- Track your own "last synced version" so incremental deltas are computed against the last success, not the last attempt.
- `removeAllIdentificationEntries()` / `removeAllBlockingEntries()` reset a category (incremental mode) before re-adding — useful when a full delta is simpler than per-number removes.

## Ordering & correctness

- `CXCallDirectoryPhoneNumber` is `Int64`, **E.164 without the `+`** (`+1 408 555 0101` → `14085550101`).
- **Strictly ascending** across the whole request, blocking and identification each in order. A single out-of-order or duplicate add fails the entire reload with `requestFailed`.
- No networking, no disk-heavy work, no large allocations — extensions have a hard memory ceiling and are killed on breach (surfaces as a failed reload). Stream from the App Group store; don't load everything into an array if the set is large.

## Failure handling

```swift
extension CallDirectoryHandler: CXCallDirectoryExtensionContextDelegate {
    func requestFailed(for extensionContext: CXCallDirectoryExtensionContext, withError error: Error) {
        // Log for diagnostics. The reload is aborted; the previous dataset stays live.
        // Common causes: out-of-order add, remove* in a full request, memory kill, extension disabled.
    }
}
```

- A failed reload keeps the **previous** successful dataset active — a bad sync won't wipe caller ID, but it also won't apply until you fix and reload.
- Because the extension can't log to your normal pipeline, write breadcrumbs to the App Group and inspect them from the host app.

## Fintech notes

- Good uses: label your own inbound numbers ("Acme Bank — Fraud Line") so customers trust the call, and block known-scam numbers you curate server-side.
- Never ship PII beyond phone-number↔label pairs into the extension store; treat it as user-visible data. Keep the block/label source under your normal data-protection story (`swift-security`).
