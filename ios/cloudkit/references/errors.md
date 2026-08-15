# CloudKit error handling — retry, backoff, conflict merge

Depth companion to the `cloudkit` SKILL's Error handling section. Every sync
path must classify `CKError`, honor server backoff, and merge conflicts instead
of overwriting.

## CKError essentials

- Domain `CKErrorDomain`; cast with `error as? CKError`, switch on `.code`.
- Key `userInfo` accessors (typed properties on `CKError`):
  - `retryAfterSeconds: Double?` — server-mandated backoff (`CKErrorRetryAfterKey`).
  - `serverRecord` / `clientRecord` / `ancestorRecord: CKRecord?` — the three sides of a `.serverRecordChanged` conflict.
  - `partialErrorsByItemID: [AnyHashable: Error]?` — per-item failures in a `.partialFailure` (`CKPartialErrorsByItemIDKey`).

## Classify: transient vs. fatal vs. conflict

```swift
enum CKOutcome { case retry(after: TimeInterval), conflict(CKError), fatal(CKError), userAction(CKError) }

func classify(_ error: Error) -> CKOutcome {
    guard let ck = error as? CKError else { return .fatal(error as? CKError ?? CKError(.internalError)) }
    switch ck.code {
    // Transient — safe to retry with backoff.
    case .networkUnavailable, .networkFailure, .serviceUnavailable,
         .requestRateLimited, .zoneBusy, .serverResponseLost:
        return .retry(after: ck.retryAfterSeconds ?? 3)
    // Conflict — must merge.
    case .serverRecordChanged:
        return .conflict(ck)
    // Needs the user.
    case .notAuthenticated:   return .userAction(ck)   // sign into iCloud
    case .quotaExceeded:      return .userAction(ck)   // iCloud full — do not retry blindly
    case .managedAccountRestricted, .permissionFailure:
        return .userAction(ck)
    // Recoverable by resyncing.
    case .changeTokenExpired: return .fatal(ck)        // discard token, full refetch
    case .partialFailure:     return .conflict(ck)     // walk partialErrorsByItemID
    default:                  return .fatal(ck)
    }
}
```

## Exponential backoff that respects `retryAfterSeconds`

The server's `retryAfterSeconds` is authoritative — never retry sooner. Add
jitter and a cap on top for repeated transient failures.

```swift
func backoffDelay(attempt: Int, serverHint: TimeInterval?) -> TimeInterval {
    if let hint = serverHint { return hint }                  // obey the server first
    let base = min(pow(2.0, Double(attempt)), 60)             // 1,2,4,…,60s
    let jitter = Double.random(in: 0...0.3) * base
    return base + jitter
}

func withRetry<T>(max attempts: Int = 5, _ op: @Sendable () async throws -> T) async throws -> T {
    var attempt = 0
    while true {
        do { return try await op() }
        catch {
            attempt += 1
            switch classify(error) {
            case .retry(let after) where attempt < attempts:
                try await Task.sleep(nanoseconds: UInt64(backoffDelay(attempt: attempt, serverHint: after) * 1_000_000_000))
            default:
                throw error
            }
        }
    }
}
```

`CKSyncEngine` implements this internally — only hand-roll it for direct
`CKDatabase`/`CKOperation` calls.

## Three-way merge on `.serverRecordChanged`

The default save policy `.ifServerRecordUnchanged` rejects a stale write with
`.serverRecordChanged`, handing you server, client, and (often) ancestor
records. Merge field-by-field, then re-save the **server** record with your
merged values so its `recordChangeTag` is current.

```swift
func merge(_ ck: CKError) -> CKRecord? {
    guard let server = ck.serverRecord else { return nil }
    let client = ck.clientRecord
    let ancestor = ck.ancestorRecord

    // Re-save onto the server record → carries the latest change tag.
    let merged = server

    for key in Set((client?.allKeys() ?? []) + server.allKeys()) {
        let base = ancestor?[key]
        let mine = client?[key]
        let theirs = server[key]
        // Only take my value where I actually changed it from the common ancestor.
        if !isEqual(mine, base) && isEqual(theirs, base) {
            merged[key] = mine
        }
        // If both changed the same key → domain rule (e.g. max, sum, or last-writer).
    }
    return merged
}
```

- Pick a deterministic rule for double-edits (both sides changed the same field): last-modified-wins, numeric `max`, additive merge for counters, etc. Make it explicit — silent field loss is the classic CloudKit bug.
- After merging, re-enqueue/re-save `merged`; a fresh conflict just loops the merge.
- For counters/balances that must not lose updates, model them as append-only child records and sum locally, rather than editing one mutable field.

## Partial failures

A batch (`modifyRecords`, or a `CKModifyRecordsOperation`) can report overall
success while individual items failed:

```swift
if let ck = error as? CKError, ck.code == .partialFailure {
    for (itemID, itemError) in ck.partialErrorsByItemID ?? [:] {
        if let inner = itemError as? CKError, inner.code == .serverRecordChanged {
            if let merged = merge(inner) { resave(merged) }
        }
    }
}
```

## Quota & auth

- `.quotaExceeded` (private DB) → the **user's** iCloud storage is full. Surface a clear message; retrying won't help until they free space or upgrade. In SwiftData+CloudKit this can fail the whole container init — degrade to local-only, don't crash.
- `.notAuthenticated` → not signed into iCloud; route to Settings, don't retry silently.
- Re-check `accountStatus()` and observe `CKAccountChanged` around these.

## Sources

- Apple Developer Documentation: `CKError`, `CKError.Code`, `CKErrorRetryAfterKey`, `CKPartialErrorsByItemIDKey`, `CKRecordChangedErrorServerRecordKey` / `…ClientRecordKey` / `…AncestorRecordKey`.
- Apple, *CloudKit Tips and Tricks* / conflict-resolution guidance (WWDC sessions).
