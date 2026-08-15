# CloudKit subscriptions & incremental change fetching

Depth companion to the `cloudkit` SKILL. Covers registering subscriptions,
receiving the silent push, and turning it into a delta fetch with persisted
change tokens. Use this when hand-rolling sync (not `CKSyncEngine`, which does
all of this internally).

## Subscription types

| Type | DB support | Fires on |
|---|---|---|
| `CKQuerySubscription` | private, public, shared | record create/update/delete matching an `NSPredicate` |
| `CKDatabaseSubscription` | private, shared (custom zones only) | any change in the DB's custom zones |
| `CKRecordZoneSubscription` | private, shared | any change within one specific zone |

The **public** DB supports only `CKQuerySubscription`. Database/zone
subscriptions + change-token fetching require custom zones (private/shared).

## Register once (idempotent, but persist a flag)

```swift
func registerDatabaseSubscription(_ db: CKDatabase) async throws {
    let sub = CKDatabaseSubscription(subscriptionID: "private-db-changes")
    let info = CKSubscription.NotificationInfo()
    info.shouldSendContentAvailable = true      // silent push — no alert, wakes app to fetch
    sub.notificationInfo = info
    _ = try await db.save(sub)                  // errServerRejectedRequest if it already exists — treat as OK
}
```

```swift
// Query subscription (e.g. public leaderboard row changed):
let predicate = NSPredicate(format: "score > %d", 0)
let qsub = CKQuerySubscription(
    recordType: "Score", predicate: predicate,
    subscriptionID: "high-scores",
    options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion])
let info = CKSubscription.NotificationInfo()
info.alertBody = "New high score!"              // user-visible; or shouldSendContentAvailable for silent
info.shouldBadge = true
qsub.notificationInfo = info
_ = try await CKContainer.default().publicCloudDatabase.save(qsub)
```

- Silent pushes (`shouldSendContentAvailable = true`) need the **Remote notifications** background mode and are subject to system budget — see `background-processing`.
- User-visible alerts use `alertBody` / `title` / `soundName` / `shouldBadge`.

## Receive the push

CloudKit pushes arrive as remote notifications. Convert with `CKNotification`:

```swift
func application(_ application: UIApplication,
                 didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                 fetchCompletionHandler completion: @escaping (UIBackgroundFetchResult) -> Void) {
    guard let note = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
        return completion(.noData)
    }
    if note.subscriptionID == "private-db-changes" {
        Task {
            do { try await fetchDatabaseChanges(); completion(.newData) }
            catch { completion(.failed) }
        }
    } else {
        completion(.noData)
    }
}
```

## Incremental fetch with persisted change tokens

Two-stage: fetch which **zones** changed, then fetch **record** changes per zone.
Persist both tokens (per database, per zone) so each fetch is a delta.

```swift
func fetchDatabaseChanges() async throws {
    let db = CKContainer.default().privateCloudDatabase
    var changedZoneIDs: [CKRecordZone.ID] = []

    // Stage 1: which zones changed since our saved DB token?
    let dbOp = CKFetchDatabaseChangesOperation(previousServerChangeToken: loadDBToken())
    dbOp.recordZoneWithIDChangedBlock = { changedZoneIDs.append($0) }
    dbOp.recordZoneWithIDWasDeletedBlock = { deleteLocalZone($0) }
    dbOp.changeTokenUpdatedBlock = { saveDBToken($0) }          // persist intermediate tokens too
    dbOp.fetchDatabaseChangesResultBlock = { result in
        if case .success(let (token, _)) = result { saveDBToken(token) }
    }
    db.add(dbOp)

    // Stage 2: for each changed zone, fetch record deltas from its saved token.
    for zoneID in changedZoneIDs { try await fetchZoneChanges(db, zoneID) }
}

func fetchZoneChanges(_ db: CKDatabase, _ zoneID: CKRecordZone.ID) async throws {
    let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
    config.previousServerChangeToken = loadZoneToken(zoneID)     // nil ⇒ full initial fetch
    let op = CKFetchRecordZoneChangesOperation(
        recordZoneIDs: [zoneID], configurationsByRecordZoneID: [zoneID: config])
    op.recordWasChangedBlock = { _, result in
        if case .success(let record) = result { upsertLocally(record) }
    }
    op.recordWithIDWasDeletedBlock = { recordID, _ in deleteLocally(recordID) }
    op.recordZoneChangeTokensUpdatedBlock = { _, token, _ in if let token { saveZoneToken(zoneID, token) } }
    op.recordZoneFetchResultBlock = { _, result in
        if case .success(let (token, _, _)) = result { saveZoneToken(zoneID, token) }
    }
    db.add(op)
}
```

- **Persist tokens durably** (Keychain/DB/file). A lost token forces a full refetch; a stale one you keep using is fine — the server returns everything since it.
- **`.changeTokenExpired`** (server aged out your token): discard it, set `previousServerChangeToken = nil`, refetch the zone from scratch.
- `changeTokenUpdatedBlock` / `recordZoneChangeTokensUpdatedBlock` fire mid-operation for large result sets — persist those intermediate tokens so an interrupted fetch resumes without re-downloading.
- CloudKit does **not** guarantee record ordering across a fetch; apply upserts idempotently keyed by `recordID`.

## Notes

- Prefer **`CKSyncEngine`** (see `references/cksyncengine.md`) over this manual pipeline for new private/shared-DB code — it owns tokens, subscriptions, batching, and retries. Hand-roll only for the public DB (query subscriptions), unusual topologies, or to retrofit an existing token store.
- The `*ResultBlock` / typed-`Result` operation callbacks shown here are the iOS 15+ APIs; the older `*CompletionBlock` variants are deprecated.

## Sources

- Apple Developer Documentation: `CKDatabaseSubscription`, `CKQuerySubscription`, `CKRecordZoneSubscription`, `CKSubscription.NotificationInfo`, `CKFetchDatabaseChangesOperation`, `CKFetchRecordZoneChangesOperation`, `CKNotification`, `CKServerChangeToken`.
- Apple sample: `apple/sample-cloudkit-sync` (change-token fetch flow).
