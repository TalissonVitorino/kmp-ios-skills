# Change history, containers, groups & errors

Deep material for syncing contacts into your own store and traversing the account hierarchy.

## Incremental sync with a history token

Re-enumerating every contact on each launch is wasteful. Persist an opaque history
token and fetch only the deltas.

```swift
import Contacts

func syncDeltas(store: CNContactStore, since savedToken: Data?) throws -> Data {
    let req = CNChangeHistoryFetchRequest()
    req.startingToken = savedToken            // nil ⇒ full history from the beginning
    req.shouldUnifyResults = true             // report unified contacts, matching unifiedContacts(...)
    // Optional: fetch contact bodies inline so events carry populated CNContacts.
    req.additionalContactKeyDescriptors = [
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
    ]

    let result = try store.enumeratorForChangeHistoryFetchRequest(req)  // CNFetchResult<NSEnumerator>
    for case let event as CNChangeHistoryEvent in result.value {
        switch event {
        case let e as CNChangeHistoryAddContactEvent:
            upsert(e.contact)                       // e.containerIdentifier also available
        case let e as CNChangeHistoryUpdateContactEvent:
            upsert(e.contact)
        case let e as CNChangeHistoryDeleteContactEvent:
            remove(byIdentifier: e.contactIdentifier)
        case is CNChangeHistoryDropEverythingEvent:
            wipeLocalCacheAndRefetchAll()           // token too old / history truncated
        default:
            break                                   // group add/update/delete, member add/remove, …
        }
    }
    return result.currentHistoryToken               // persist for the next sync
}
```

- Event subclasses of `CNChangeHistoryEvent` include: `…AddContactEvent`,
  `…UpdateContactEvent`, `…DeleteContactEvent`, `…AddGroupEvent`, `…UpdateGroupEvent`,
  `…DeleteGroupEvent`, `…AddMemberToGroupEvent`, `…RemoveMemberFromGroupEvent`, and
  `…DropEverythingEvent`. Always handle `DropEverything` by doing a full re-sync — it
  signals the incremental log could not be reconstructed from your token.
- The enumerator is an `NSEnumerator` of Objective-C event objects; the `for case let … as`
  cast per event is the idiomatic Swift bridge.
- `startingToken == nil` replays the *entire* history — only do that on first sync or after a
  `DropEverything`; otherwise always pass the saved token.

## Knowing when to sync

`CNContactStore` posts `CNContactStoreDidChange` (a `Notification.Name`) when the database
changes. It carries **no** useful payload — treat it purely as a "run the delta fetch" trigger.

```swift
NotificationCenter.default.addObserver(
    forName: .CNContactStoreDidChange, object: nil, queue: .main) { _ in
    // debounce, then call syncDeltas(store:since:)
}
```

Debounce: bulk edits (an account sync) fire many notifications in a burst.

## Containers & groups

The hierarchy is **container (account) → group → contact**. A unified contact can span
containers; raw contacts belong to exactly one.

```swift
// Default container new contacts go into:
let defaultId = store.defaultContainerIdentifier()

// All containers (accounts): pass nil predicate for every container.
let containers = try store.containers(matching: nil)     // [CNContainer]

// Groups inside a specific container:
let groups = try store.groups(matching:
    CNGroup.predicateForGroupsInContainer(withIdentifier: defaultId))  // [CNGroup]

// Contacts in a group (works with unifiedContacts):
let members = try store.unifiedContacts(
    matching: CNContact.predicateForContactsInGroup(withIdentifier: groups[0].identifier),
    keysToFetch: [CNContactGivenNameKey as CNKeyDescriptor])
```

- Create / rename / delete groups and group membership through `CNSaveRequest`:
  `addGroup(_:toContainerWithIdentifier:)`, `updateGroup(_:)`, `deleteGroup(_:)` (pass a
  `CNMutableGroup`), and `addMember(_:to:)` / `removeMember(_:from:)`.
- `CNContainer.containerType`: `.local`, `.exchange`, `.cardDAV` (iCloud is CardDAV), `.unassigned`.

## Error handling

`execute(_:)` and fetches throw `CNError` (domain `CNErrorDomain`). Notable `CNError.Code`:

- `.authorizationDenied` — no write permission; route to Settings.
- `.insertedRecordAlreadyExists` — adding a contact/id that already exists.
- `.recordDoesNotExist` — updating/deleting a stale contact (deleted elsewhere).
- `.containerReadOnly` — the target container (some corporate accounts) forbids writes.
- `.validationMultipleErrors` — batch save partly invalid; inspect `userInfo[CNErrorUserInfoAffectedRecordsKey]`.
- `.communicationError` — transient store/XPC failure; safe to retry.

```swift
do { try store.execute(save) }
catch let error as NSError where error.domain == CNErrorDomain {
    switch CNError.Code(rawValue: error.code) {
    case .authorizationDenied: presentSettingsPrompt()
    case .containerReadOnly:   showReadOnlyAccountMessage()
    default:                   report(error)
    }
}
```
