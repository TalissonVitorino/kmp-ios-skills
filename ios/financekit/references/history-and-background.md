# FinanceKit — history & background delivery (depth)

Companion to `SKILL.md`. Covers `FinanceStore.History`, `Changes`, `HistoryToken`,
and the iOS 26 `BackgroundDeliveryExtension`.

## History as an AsyncSequence

Both history entry points return `FinanceStore.History<Model>` where
`Model: Identifiable`. `History` conforms to `AsyncSequence`; its element is
`FinanceStore.Changes<Model>`.

```swift
// Signatures
func transactionHistory(
    forAccountID accountID: UUID,
    since token: FinanceStore.HistoryToken? = nil,
    isMonitoring: Bool = true) -> FinanceStore.History<Transaction>

func accountHistory(
    since token: FinanceStore.HistoryToken? = nil,
    isMonitoring: Bool = true) -> FinanceStore.History<Account>
```

```swift
struct Changes<Model: Identifiable> {
    let inserted: [Model]        // full objects added
    let updated:  [Model]        // full objects changed
    let deleted:  [Model.ID]     // identifiers only
    let newToken: FinanceStore.HistoryToken  // persist this
}
```

### Iteration

```swift
let history = store.transactionHistory(forAccountID: id, since: savedToken, isMonitoring: true)
for try await changes in history {
    try localStore.upsert(changes.inserted + changes.updated)
    try localStore.remove(ids: changes.deleted)
    persist(token: changes.newToken)     // resume point
}
```

- `makeAsyncIterator()` → `Iterator`; `next() async throws -> Changes<Model>?` yields batches until `nil`.
- **`isMonitoring: true`** (default): the sequence stays open and keeps yielding as the store changes — the loop does not naturally end; cancel the enclosing `Task` to stop.
- **`isMonitoring: false`**: drains everything since `token`, then ends — the right choice inside a background extension or a one-shot sync.
- `since: nil` starts from the beginning (full backfill on first run); afterwards always pass the last `newToken`.

### Token discipline

- Persist `newToken` **after** each batch is durably applied, not before — a crash mid-apply then replays that batch instead of skipping it.
- Store the token where both the app and any extension can read it: a Keychain item in a shared access group (`swift-security`), using an accessibility class that allows background reads (e.g. `...AfterFirstUnlockThisDeviceOnly`) so the extension can fetch it while the device is locked.
- `deleted` carries IDs only; delete locally by ID and tolerate an unknown ID (already gone).

## Background delivery extension (iOS 26)

The extension is a separate target woken by the system when shared data changes,
subject to the registered `UpdateFrequency`.

### Main app: register interest

```swift
FinanceStore.shared.enableBackgroundDelivery(
    for: [.transactions, .accounts],   // BackgroundDataType
    frequency: .daily)                 // UpdateFrequency floor

// Later, to stop:
FinanceStore.shared.disableBackgroundDelivery(for: [.transactions])
FinanceStore.shared.disableAllBackgroundDelivery()
```

- `BackgroundDataType`: `.transactions`, `.accounts`, `.orders`.
- `UpdateFrequency` is a **minimum interval**: after a delivery, further deliveries are suppressed until it elapses; if nothing changed, nothing is delivered. Don't rely on it as a precise timer.

### Extension target: implement the protocol

```swift
import FinanceKit

@main
struct SpendingRefreshExtension: BackgroundDeliveryExtension {
    // BackgroundDeliveryExtension: AppExtension, BackgroundDeliveryExtensionProviding

    func didReceiveData(for types: [FinanceStore.BackgroundDataType]) async {
        let token = loadTokenFromSharedKeychain()
        // Bounded drain — isMonitoring:false so it ends.
        let history = FinanceStore.shared.transactionHistory(
            forAccountID: primaryAccountID, since: token, isMonitoring: false)
        do {
            for try await changes in history {
                try cache.apply(changes)
                saveTokenToSharedKeychain(changes.newToken)
            }
            reloadWidgetTimelines()
        } catch {
            // Leave the token untouched so the next wake retries this delta.
        }
    }

    func willTerminate() async {
        // Flush caches / persist partial progress before teardown.
    }
}
```

- Conform to `BackgroundDeliveryExtension` (which refines `AppExtension` and `BackgroundDeliveryExtensionProviding`). Required members: `didReceiveData(for:) async` and `willTerminate() async`.
- You get a **limited execution window** — keep work incremental and idempotent, favor `isMonitoring: false`, and never block. Heavy processing belongs in the main app on next launch.
- Common use: recompute a spending summary and call WidgetKit reloads (`widgetkit`), or update an on-device cache. For general background scheduling not tied to FinanceKit deltas, use `background-processing` (BGTaskScheduler).
- Share state between app and extension through an App Group / shared Keychain access group; the extension has no access to the app's process memory.
