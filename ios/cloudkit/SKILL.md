---
name: cloudkit
description: "Implement, review, or debug iCloud sync in iOS/macOS apps with CloudKit. Covers CKContainer + private/public/shared CKDatabase, CKRecord / CKRecord.Reference / CKAsset, CKQuery + CKQueryOperation, CKSubscription (query/database/recordZone) with silent push, CKSyncEngine (iOS 17+: state serialization, fetchChanges/sendChanges, delegate + change batches), CKShare + UICloudSharingController collaboration, NSUbiquitousKeyValueStore for small prefs, accountStatus gating, and CKError handling (retryAfterSeconds, serverRecordChanged conflicts, quotaExceeded). Also covers syncing SwiftData models via ModelConfiguration(cloudKitDatabase:). Use when adding iCloud sync, resolving CloudKit conflicts, or wiring subscriptions/push. For the SwiftData model layer itself see `swiftdata`; for at-rest secret encryption see `swift-security`; for sync/conflict architecture see `offline-first`; for APNs plumbing see `push-notifications`; for background delivery see `background-processing`."
---

# CloudKit (iCloud sync — iOS 26 era)

Apple's hosted backend for syncing app data across a user's devices (and, via
shares, between users). No server code; you model records and CloudKit handles
storage, auth (the iCloud account), and delivery.

- **Fintech caution:** the **public** database is world-readable and the record data is **not** end-to-end encrypted at rest under your key. Never put balances, PANs, transactions, or PII in it. For sensitive fields, either keep them out of CloudKit or store a CryptoKit-sealed blob whose key lives in the Keychain (see `swift-security`) — CloudKit syncs opaque bytes fine.
- **When *not* to use CloudKit:** you need server-side business logic, non-Apple clients, or a queryable ledger of record. CloudKit is a per-user sync cache, not a system of record.
- **Modern default:** for a hand-rolled model use **`CKSyncEngine`** (iOS 17+). For a SwiftData/Core Data model, turn on the built-in mirroring instead of touching CKRecord directly.

## Contents

- [Setup & entitlements](#setup)
- [Account status (gate every sync)](#account)
- [Containers & databases](#databases)
- [Records, references, assets](#records)
- [Queries](#queries)
- [Subscriptions & push](#subscriptions)
- [CKSyncEngine (iOS 17+)](#syncengine)
- [SwiftData + CloudKit](#swiftdata)
- [Sharing (CKShare)](#sharing)
- [NSUbiquitousKeyValueStore](#kvs)
- [Error handling](#errors)
- [Correctness checklist](#checklist)
- Depth: `references/cksyncengine.md`, `references/errors.md`, `references/subscriptions.md`

<a id="setup"></a>
## Setup & entitlements

- Add the **iCloud** capability → check **CloudKit**; Xcode creates the `com.apple.developer.icloud-container-identifiers` entitlement and a default container `iCloud.<bundle-id>`.
- Add the **Push Notifications** capability and enable **Remote notifications** background mode — CloudKit subscriptions and `CKSyncEngine` deliver change pushes over APNs.
- Model your schema in the **CloudKit Console** (or let it auto-create record types from saves in the Development environment). **Development and Production schemas are separate** — you must explicitly *Deploy Schema Changes to Production* before an App Store build works. New fields, indexes, and record types don't reach Production automatically.
- Querying by a field requires a **queryable index** on it in the console; sorting requires a **sortable** index; `recordName` needs a queryable index for `NSPredicate(value: true)` fetches.

<a id="account"></a>
## Account status (gate every sync)

Never sync without confirming the user is signed into iCloud. Check on launch and re-check on the account-changed notification.

```swift
import CloudKit

let container = CKContainer.default() // or CKContainer(identifier: "iCloud.com.example.app")

func iCloudReady() async -> Bool {
    do {
        switch try await container.accountStatus() {
        case .available:               return true
        case .noAccount:               // not signed in → prompt to sign in
             return false
        case .restricted:              // parental controls / MDM
             return false
        case .couldNotDetermine:       return false
        case .temporarilyUnavailable:  // e.g. account being reconfigured; retry later
             return false
        @unknown default:              return false
        }
    } catch { return false }
}
```

- Observe **`CKAccountChanged`** (`NotificationCenter`) — fires when the user signs in/out or switches iCloud accounts. Re-evaluate status and, on sign-out, stop syncing and clear the local cache tied to the old account.
- `container.userRecordID()` returns the current user's record ID; `requestApplicationPermission`/`fetchUserRecordID` discoverability APIs are largely deprecated — don't build on them.

<a id="databases"></a>
## Containers & databases

A `CKContainer` exposes three databases, each a `CKDatabase`:

| Database | Access | Zones | Typical use |
|---|---|---|---|
| `privateCloudDatabase` | only the signed-in user; counts against **their** iCloud quota | default zone **+ custom zones** | the user's own synced data |
| `publicCloudDatabase` | world-readable, writable per role; counts against **your app's** quota | default zone only | shared reference data, leaderboards |
| `sharedCloudDatabase` | records other users shared **with** this user | mirrors the owner's shared zones | collaboration (see [Sharing](#sharing)) |

```swift
let priv = container.privateCloudDatabase
let pub  = container.publicCloudDatabase
let shared = container.sharedCloudDatabase
```

- **Custom zones** (`CKRecordZone`) exist only in the private/shared DBs. You need one to use `fetchDatabaseChanges` / zone change tracking, atomic multi-record saves, and sharing. The **public** DB has only the default zone and does **not** support change-token fetching or zone/database subscriptions — only query subscriptions.
- Create a zone once: `CKModifyRecordZonesOperation` or `database.save(CKRecordZone(zoneName: "Ledger"))`.

<a id="records"></a>
## Records, references, assets

`CKRecord` is a schemaless key–value bag with a `recordType` and a `CKRecord.ID`.

```swift
let zoneID = CKRecordZone.ID(zoneName: "Ledger", ownerName: CKCurrentUserDefaultName)
let id = CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
let account = CKRecord(recordType: "Account", recordID: id)
account["displayName"] = "Checking" as CKRecordValue
account["balanceMinorUnits"] = 125_00 as NSNumber          // store money as integer minor units
account["createdAt"] = Date() as CKRecordValue
```

- Supported value types: `String`, `NSNumber` (Int/Double/Bool), `Date`, `Data` (≤1 MB — larger goes in a `CKAsset`), `CLLocation`, `CKRecord.Reference`, `CKAsset`, and arrays of these. **Not** arbitrary Codable — encode structs to `Data`/JSON yourself or use per-field columns.
- **Assign a stable `recordName` yourself** (a UUID). Do not rely on server-generated names — you need the ID to reference, update, and reconcile records locally.
- `record.recordChangeTag` is the server version token; `creationDate`/`modificationDate`/`creatorUserRecordID`/`lastModifiedUserRecordID` are system fields.

### References (relationships)

```swift
let owner = CKRecord.Reference(recordID: account.recordID, action: .deleteSelf)
let txn = CKRecord(recordType: "Transaction", recordID: .init(zoneID: zoneID))
txn["account"] = owner              // many-to-one: transaction → account
```

- `action: .deleteSelf` → this record is cascade-deleted when the target is deleted. `action: .none` → no cascade (you clean up). CloudKit has no server-side joins; model the back-reference and query by it.
- Keep referenced records **in the same zone** for atomic saves and sharing to work.

### Assets (large binaries)

```swift
let statement = CKRecord(recordType: "Statement", recordID: .init(zoneID: zoneID))
statement["pdf"] = CKAsset(fileURL: localPDFURL)   // CloudKit uploads the file
// On fetch: (record["pdf"] as? CKAsset)?.fileURL  → a temp URL; copy it out, it's transient.
```

- Use `CKAsset` for anything over ~1 MB (images, PDFs, audio). The `fileURL` you get back on fetch is a **temporary** cache location — copy it into your own storage before the file is reclaimed.

### Save / fetch (async, iOS 15+)

```swift
let saved = try await priv.save(account)                    // single record
let fetched = try await priv.record(for: id)                // single record
try await priv.deleteRecord(withID: id)

// Batch, atomic within a zone:
let (saveResults, deleteResults) = try await priv.modifyRecords(
    saving: [account, txn], deleting: [],
    savePolicy: .ifServerRecordUnchanged)                   // reject if server changed → conflict
```

- **`savePolicy`:** `.ifServerRecordUnchanged` (default; surfaces `.serverRecordChanged` so you can merge) → prefer this. `.changedKeys` / `.allKeys` overwrite — last-writer-wins, silent data loss. Use overwrite policies only when you truly own the field.
- For fine-grained control and progress, drop to `CKModifyRecordsOperation` (set `savePolicy`, `isAtomic`, per-record and completion blocks).

<a id="queries"></a>
## Queries

```swift
let predicate = NSPredicate(format: "account == %@", CKRecord.Reference(recordID: id, action: .none))
let query = CKQuery(recordType: "Transaction", predicate: predicate)
query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]

// Convenience (iOS 15+): one page, up to `resultsLimit`.
let (matches, cursor) = try await priv.records(matching: query, inZoneWith: zoneID, resultsLimit: 50)
for (recordID, result) in matches {
    if case .success(let record) = result { /* use record */ }
}
```

- `matches` is `[(CKRecord.ID, Result<CKRecord, Error>)]` — **per-record** results; a record can fail (e.g. asset missing) while others succeed. Always switch on the `Result`.
- **Paginate** with the returned `cursor`: `priv.records(continuingMatchFrom: cursor, resultsLimit:)`. Never assume one call returns everything.
- Only **queryable-indexed** fields are usable in predicates; only **sortable** fields in `sortDescriptors`. Fetch-all uses `NSPredicate(value: true)` (needs `recordName` queryable).
- For manual paging / result-block control use `CKQueryOperation` (`queryResultBlock`, `recordMatchedBlock`, `resultsLimit`, `cursor`). `CKQuery` cannot query the private default zone across zones — query a specific zone.

<a id="subscriptions"></a>
## Subscriptions & push

Subscriptions tell CloudKit to send a push when matching data changes, so you sync reactively instead of polling. Register **once** (persist a "did register" flag; re-registering is wasteful, not harmful).

- **`CKQuerySubscription`** — fires on create/update/delete matching a predicate. The **only** subscription type the **public** DB supports.
- **`CKDatabaseSubscription`** — fires on *any* change in the **private/shared** DB's custom zones. The backbone of whole-database sync (what `CKSyncEngine` uses internally). Not supported in the public DB or the default zone.
- **`CKRecordZoneSubscription`** — fires on changes within one specific zone.

```swift
let sub = CKDatabaseSubscription(subscriptionID: "private-changes")
let info = CKSubscription.NotificationInfo()
info.shouldSendContentAvailable = true          // SILENT push → wake the app to fetch, no alert
sub.notificationInfo = info
try await priv.save(sub)
```

- For **background sync**, use `shouldSendContentAvailable = true` (silent, `content-available`) — requires the remote-notifications background mode. Handle it in `didReceiveRemoteNotification`, then fetch changes and call the completion handler. See `push-notifications` for the APNs entry point and `background-processing` for budget/delivery.
- For **user-visible** alerts set `alertBody`/`soundName`/`shouldBadge` instead.
- `CKFetchDatabaseChangesOperation` + `CKFetchRecordZoneChangesOperation` with persisted **change tokens** turn a push into an incremental delta fetch. Full operation flow in `references/subscriptions.md`.

<a id="syncengine"></a>
## CKSyncEngine (iOS 17+)

`CKSyncEngine` is the modern path for a **custom local model** (SQLite, files, your own store): it manages the change tokens, zone/database subscriptions, retries, batching, and push handling that you'd otherwise write by hand. You own local persistence; it owns the sync protocol.

Mental model — two directions, driven by your delegate:

- **Outgoing:** you tell the engine which record IDs changed (`state.add(pendingRecordZoneChanges:)`); it later calls back asking you to *materialize* those into `CKRecord`s in a batch.
- **Incoming:** it fetches server changes and hands you events to apply to your local store.

```swift
import CloudKit

actor SyncController {
    private var engine: CKSyncEngine!

    init(previousState: CKSyncEngine.State.Serialization?) {
        var config = CKSyncEngine.Configuration(
            database: CKContainer.default().privateCloudDatabase,
            stateSerialization: previousState,   // reload what you persisted last run
            delegate: self)
        config.automaticallySync = true
        self.engine = CKSyncEngine(config)
    }
}

extension SyncController: CKSyncEngineDelegate {
    // 1) React to sync events.
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            // PERSIST THIS every time — it's your change tokens + pending edits.
            persist(update.stateSerialization)
        case .accountChange(let change):
            handleAccountChange(change)          // signed out → wipe local cache
        case .fetchedRecordZoneChanges(let changes):
            for mod in changes.modifications { applyToLocalStore(mod.record) }
            for del in changes.deletions { deleteLocally(del.recordID) }
        case .sentRecordZoneChanges(let sent):
            for failed in sent.failedRecordSaves { resolve(failed) }  // e.g. serverRecordChanged
        case .willFetchChanges, .didFetchChanges,
             .willSendChanges, .didSendChanges,
             .fetchedDatabaseChanges, .sentDatabaseChanges:
            break                                // observe as needed
        @unknown default: break
        }
    }

    // 2) Hand the engine the actual records to upload for this batch.
    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            materializeRecord(for: recordID)     // your local model → CKRecord, or nil if deleted
        }
    }
}
```

- **Persist `stateSerialization` on every `.stateUpdate`.** It encodes the change tokens and the queue of pending edits. Lose it and you re-fetch/re-upload everything (usually converges, but wastes quota and can duplicate if your local IDs aren't stable).
- **Never call `fetchChanges(_:)` / `sendChanges(_:)` from inside `handleEvent` / `nextRecordZoneChangeBatch`** — you can deadlock or loop. With `automaticallySync = true` the engine schedules them; call them manually only for explicit pull-to-refresh, and outside the delegate callbacks.
- Register your local edits with `engine.state.add(pendingRecordZoneChanges: [.saveRecord(id), .deleteRecord(id)])`; the engine coalesces and later calls `nextRecordZoneChangeBatch`.
- The engine creates/manages the `CKDatabaseSubscription` for you; you still need the push entitlement + background mode and must route the CloudKit push into the engine (or let automatic sync handle it).
- Full delegate skeleton (account wipe, conflict merge, manual fetch) in `references/cksyncengine.md`.

<a id="swiftdata"></a>
## SwiftData + CloudKit

If your model is **SwiftData**, don't hand-roll CKRecord — mirror the store to CloudKit automatically.

```swift
import SwiftData

let config = ModelConfiguration(
    "Default",
    schema: Schema([Account.self, Transaction.self]),
    cloudKitDatabase: .automatic)          // .private("iCloud.com.example.app") to pin a container; .none to disable
let container = try ModelContainer(for: Account.self, Transaction.self, configurations: config)
```

- `cloudKitDatabase:` takes `.automatic` (uses the first CloudKit container in your entitlements), `.private("iCloud.…")` (pin a specific container), or `.none` (local only).
- **Only the private database** is supported. There is **no** public or shared CloudKit database via SwiftData mirroring — if you need public data or CKShare collaboration, use CloudKit directly (or CKSyncEngine alongside).
- Mirroring imposes model constraints (the same ones Core Data + CloudKit have): **every attribute must be optional or have a default value**, **no `@Attribute(.unique)`**, and **relationships must be optional** (and generally have inverses). CloudKit can't express uniqueness or non-null constraints, so the schema must tolerate partial/late-arriving data.
- The Core Data equivalent is `NSPersistentCloudKitContainer` (see `core-data`); the constraints are identical.
- For the model layer, migrations, and predicates see `swiftdata`.

<a id="sharing"></a>
## Sharing (CKShare)

`CKShare` lets the owner share a record hierarchy from their **private** DB; participants access it through their **shared** DB.

```swift
let share = CKShare(rootRecord: account)
share[CKShare.SystemFieldKey.title] = "Joint account" as CKRecordValue
share.publicPermission = .none                 // .none | .readOnly | .readWrite
// Save the root record and the share together, atomically, in a custom zone:
try await priv.modifyRecords(saving: [account, share], deleting: [])
```

- **Present the invite UI** with `UICloudSharingController`. Prefer the `init(share:container:)` initializer — create/save the `CKShare` yourself first, then present it. The `init(preparationHandler:)` initializer is **deprecated**; avoid it, especially wrapped in `UIViewControllerRepresentable`, where the not-yet-created-share path is unreliable.
- **Accept an invite:** implement `windowScene(_:userDidAcceptCloudKitShareWith:)` (scene delegate) / `application(_:userDidAcceptCloudKitShareWith:)` and call `container.accept(shareMetadata)` (`CKAcceptSharesOperation`).
- Participants read/write via `sharedCloudDatabase`; changes flow through the same subscription/`CKSyncEngine` machinery. Share the **root** of a hierarchy — all records reachable via references in the same zone come along.
- **iOS 26 note:** the new share-access request APIs (`CKShareRequestAccessOperation`) are present in the SDK but reported **nonfunctional in early iOS 26 betas**, and CloudKit share URLs may not deep-link into third-party apps in beta — verify on device before shipping a flow that depends on them.

<a id="kvs"></a>
## NSUbiquitousKeyValueStore

iCloud-synced key-value store for **small, non-critical** preferences (like a cloud `UserDefaults`) — last-writer-wins, no conflict resolution.

```swift
let kv = NSUbiquitousKeyValueStore.default
kv.set(true, forKey: "hasCompletedOnboarding")
kv.set("dark", forKey: "theme")
kv.synchronize()      // flush to disk; sync still happens on the system's schedule

NotificationCenter.default.addObserver(
    forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
    object: kv, queue: .main) { note in
    // Merge external changes; check the change-reason key for initial-sync vs. quota-violation.
}
```

- Hard limits: **1 MB total**, **1024 keys**, ~1 MB per value. Requires the **iCloud key-value storage** entitlement.
- **Not for real data** — no per-record sync, no conflict handling, silently drops when over quota. Use it for flags/settings; use CloudKit or SwiftData+CloudKit for anything the user would miss.

<a id="errors"></a>
## Error handling

CloudKit errors are `CKError` (domain `CKErrorDomain`). Switch on `error.code` and read `userInfo` for retry/conflict details. **Every** sync path must handle these.

```swift
if let ck = error as? CKError {
    switch ck.code {
    case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
        // Transient. Honor the server's backoff:
        let delay = ck.retryAfterSeconds ?? 3      // seconds
        scheduleRetry(after: delay)
    case .serverRecordChanged:
        // Conflict. Merge, don't clobber:
        let server = ck.serverRecord              // the winning server version
        let client = ck.clientRecord              // your rejected version
        // let ancestor = ck.ancestorRecord       // common base, if available
        resolveAndResave(server: server, client: client)
    case .quotaExceeded:
        // User's iCloud is full (private DB) → surface a message; don't retry blindly.
        notifyUserStorageFull()
    case .partialFailure:
        // Batch: inspect per-item failures.
        let byID = ck.partialErrorsByItemID ?? [:]  // [CKRecord.ID: Error]
        for (_, itemError) in byID { handle(itemError) }
    case .notAuthenticated:
        promptSignIntoiCloud()
    case .changeTokenExpired:
        resyncFromScratch()                        // discard token, refetch zone
    case .unknownItem:
        treatAsDeleted()
    default:
        log(ck)
    }
}
```

- **Always** honor `retryAfterSeconds` (from `CKErrorRetryAfterKey`) on rate-limit/busy errors — hammering makes throttling worse. `CKSyncEngine` does this for you.
- **`.serverRecordChanged` is the core conflict case.** The default `.ifServerRecordUnchanged` save policy surfaces it so you can three-way merge (`serverRecord` / `clientRecord` / `ancestorRecord`) instead of losing a write. For merge strategy see `offline-first`.
- On **`.partialFailure`**, the operation as a whole may "succeed" — you must walk `partialErrorsByItemID`; a common nested code is `.serverRecordChanged` per record.
- Full retry helper + a three-way merge example in `references/errors.md`.

<a id="checklist"></a>
## Correctness checklist

- [ ] `accountStatus()` checked before any sync; `CKAccountChanged` observed; local cache cleared on sign-out / account switch.
- [ ] No sensitive/financial data in the **public** database; sensitive fields kept out of CloudKit or stored as Keychain-keyed sealed blobs (`swift-security`).
- [ ] Schema **deployed to Production** before release; queried fields have queryable indexes, sorted fields sortable indexes.
- [ ] Own stable `recordName`s (UUIDs) — not server-generated — so records are referenceable and reconcilable.
- [ ] Saves use `.ifServerRecordUnchanged` and handle `.serverRecordChanged` by merging, not overwriting.
- [ ] `CKAsset` for payloads > ~1 MB; asset `fileURL` copied out of its temporary location on fetch.
- [ ] Subscription registered once (flag persisted); public DB uses only `CKQuerySubscription`; silent push uses `shouldSendContentAvailable` + remote-notifications background mode.
- [ ] `CKSyncEngine`: `stateSerialization` persisted on **every** `.stateUpdate`; no `fetchChanges`/`sendChanges` called from inside delegate callbacks.
- [ ] SwiftData+CloudKit: private DB only; all attributes optional/defaulted; no `.unique`; relationships optional.
- [ ] `retryAfterSeconds` honored on transient/rate-limit errors; `.quotaExceeded` surfaced to the user, not retried blindly.
- [ ] `.partialFailure` batches walked via `partialErrorsByItemID`; `.changeTokenExpired` triggers a full resync.
- [ ] `NSUbiquitousKeyValueStore` used only for small flags/settings (≤1 MB, ≤1024 keys), never for real data.
- [ ] Change tokens (or engine state) persisted so pushes trigger incremental delta fetches, not full re-downloads.
