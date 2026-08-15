# CKSyncEngine — full delegate skeleton (iOS 17+)

`CKSyncEngine` syncs a **custom local store** to one CloudKit database. You own
persistence; it owns change tokens, subscriptions, batching, retries, and push.
This is the depth companion to the `cloudkit` SKILL's CKSyncEngine section.

## Lifecycle

1. On launch, load the persisted `CKSyncEngine.State.Serialization` (from your local store) and build the engine.
2. When local data changes, enqueue pending changes: `engine.state.add(pendingRecordZoneChanges:)`.
3. The engine calls `nextRecordZoneChangeBatch` to pull the actual `CKRecord`s to upload.
4. The engine calls `handleEvent` for every step (state updates, fetched changes, sent results, account changes).
5. **Persist `stateSerialization` on every `.stateUpdate`** — it is your only durable record of change tokens + pending edits.

## Building the engine

```swift
import CloudKit
import os

actor CloudSyncEngine {
    private let localStore: LocalStore          // your SQLite/file/model store
    private var engine: CKSyncEngine!
    private let log = Logger(subsystem: "app.sync", category: "CKSyncEngine")

    init(localStore: LocalStore) {
        self.localStore = localStore
        var config = CKSyncEngine.Configuration(
            database: CKContainer.default().privateCloudDatabase,
            stateSerialization: localStore.loadSyncState(),   // Data? decoded to Serialization
            delegate: self)
        config.automaticallySync = true          // engine schedules fetch/send itself
        self.engine = CKSyncEngine(config)
    }

    /// Call when the user creates/edits/deletes locally.
    func recordChanged(_ id: CKRecord.ID)  { engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)]) }
    func recordDeleted(_ id: CKRecord.ID)  { engine.state.add(pendingRecordZoneChanges: [.deleteRecord(id)]) }

    /// Ensure the custom zone exists once (engine also accepts pending zone changes).
    func ensureZone(_ zoneID: CKRecordZone.ID) {
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    }

    /// Explicit pull-to-refresh — safe ONLY outside delegate callbacks.
    func manualSync() async throws {
        try await engine.fetchChanges()
        try await engine.sendChanges()
    }
}
```

## Delegate

```swift
extension CloudSyncEngine: CKSyncEngineDelegate {

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {

        case .stateUpdate(let update):
            // MUST persist — encodes change tokens + queued pending changes.
            localStore.saveSyncState(update.stateSerialization)

        case .accountChange(let change):
            switch change.changeType {
            case .signIn:                 // new account → resync from scratch
                reuploadEverything()
            case .switchAccounts, .signOut:
                localStore.wipeCloudMirror()   // old account's data must not linger
            @unknown default: break
            }

        case .fetchedRecordZoneChanges(let changes):
            for mod in changes.modifications {
                localStore.upsert(from: mod.record)     // apply server record locally
            }
            for del in changes.deletions {
                localStore.delete(del.recordID)
            }

        case .sentRecordZoneChanges(let sent):
            for saved in sent.savedRecords {
                localStore.markSynced(saved)            // stash recordChangeTag/system fields
            }
            for failed in sent.failedRecordSaves {
                handleFailedSave(failed, syncEngine: syncEngine)
            }

        case .fetchedDatabaseChanges(let changes):
            for del in changes.deletions {              // a zone was deleted server-side
                localStore.deleteZone(del.zoneID)
            }

        case .willFetchChanges, .didFetchChanges,
             .willSendChanges, .didSendChanges,
             .sentDatabaseChanges:
            break                                       // progress hooks; observe if useful

        @unknown default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pending.isEmpty else { return nil }

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            // Return the current CKRecord for this ID, or nil to drop it from the batch
            // (e.g. it was deleted locally after being enqueued).
            localStore.materializeRecord(for: recordID)
        }
    }
}
```

## Handling a failed save (conflict)

```swift
private func handleFailedSave(_ failed: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
                              syncEngine: CKSyncEngine) {
    guard let ck = failed.error as? CKError else { return }
    switch ck.code {
    case .serverRecordChanged:
        // Merge server truth with local intent, then re-enqueue.
        if let server = ck.serverRecord {
            let merged = localStore.merge(server: server)   // three-way merge
            localStore.upsert(from: merged)
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(merged.recordID)])
        }
    case .unknownItem:
        localStore.delete(failed.record.recordID)           // gone server-side
    case .zoneNotFound:
        syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: failed.record.recordID.zoneID))])
        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failed.record.recordID)])
    default:
        break   // transient codes are retried by the engine automatically
    }
}
```

## Materializing records: preserve system fields

When you rebuild a `CKRecord` from your local model to upload, you **must** start
from the last-known server record (with its `recordChangeTag`), not a fresh
`CKRecord`, or every save looks like a first write and you lose optimistic
concurrency. Persist the encoded system fields locally:

```swift
// Save: capture system fields after a successful sync.
func encodeSystemFields(_ record: CKRecord) -> Data {
    let coder = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: coder)
    coder.finishEncoding()
    return coder.encodedData
}

// Materialize: rehydrate the record shell, then set your fields.
func materializeRecord(for id: CKRecord.ID) -> CKRecord? {
    guard let model = localStore.model(for: id) else { return nil }  // nil ⇒ deleted
    let record: CKRecord
    if let data = model.systemFields,
       let coder = try? NSKeyedUnarchiver(forReadingFrom: data) {
        coder.requiresSecureCoding = true
        record = CKRecord(coder: coder) ?? CKRecord(recordType: model.type, recordID: id)
        coder.finishDecoding()
    } else {
        record = CKRecord(recordType: model.type, recordID: id)
    }
    record["balanceMinorUnits"] = model.balanceMinorUnits as NSNumber
    record["displayName"] = model.displayName as CKRecordValue
    return record
}
```

## Rules

- One engine per database. Sync private and shared DBs with two engines if needed.
- Never call `fetchChanges`/`sendChanges` from within `handleEvent` or `nextRecordZoneChangeBatch` — deadlock / infinite-loop risk. Let `automaticallySync` drive; call manually only for user-initiated refresh.
- Route the CloudKit silent push to the engine (or rely on automatic sync). Needs Push Notifications capability + remote-notifications background mode.
- Keep local record IDs **stable** across launches so re-materialization and conflict merges line up.
- Test the sign-out path: the old account's mirror must be wiped so it can't leak into a new account.

## Sources

- Apple, *Sync to iCloud with CKSyncEngine* (WWDC23, session 10188).
- Apple sample: `apple/sample-cloudkit-sync-engine`.
- Apple Developer Documentation: `CKSyncEngine`, `CKSyncEngineDelegate`, `CKSyncEngine.Event`, `CKSyncEngine.State.Serialization`, `CKSyncEngine.RecordZoneChangeBatch`.
