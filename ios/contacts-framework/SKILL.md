---
name: contacts-framework
description: "Read, create, update, and pick contacts on iOS with the Contacts and ContactsUI frameworks. Covers CNContactStore (authorizationStatus(for:), requestAccess(for:), unifiedContacts(matching:keysToFetch:), enumerateContacts(with:), execute(CNSaveRequest)), keysToFetch / CNKeyDescriptor and partial-fetch crashes, CNContactFetchRequest predicates (predicateForContacts(matchingName:) / matchingPhoneNumber / matchingEmailAddress / inContainer), CNContact vs CNMutableContact and CNLabeledValue, CNSaveRequest add/update/delete, CNContactPickerViewController + CNContactViewController wrapped in SwiftUI via UIViewControllerRepresentable, iOS 18+ limited access (.limited, ContactAccessButton), and CNChangeHistoryFetchRequest incremental sync. Use when fetching/saving contacts, requesting Contacts permission, or embedding the system contact picker. Wrap the UIKit controllers with swiftui-uikit-interop; bridge requestAccess to async with swift-concurrency; expose a commonMain interface bound in iosMain via expect-actual for KMP. See app-store-review for the NSContactsUsageDescription Info.plist key and privacy manifest, and accessibility-patterns for the picker."
---

# Contacts & ContactsUI (iOS)

Read, write, and pick the user's contacts. `Contacts` is the data layer
(`CNContactStore`, `CNContact`); `ContactsUI` is the system UI
(`CNContactPickerViewController`, `CNContactViewController`, `ContactAccessButton`).

- **KMP boundary:** contacts are iOS-only Apple API. Expose a `commonMain`
  `interface ContactsGateway` and bind a `CNContactStore`-backed `actual` in `iosMain`
  — never let shared code depend on `CN*` types. See `expect-actual` / `android-skills:kmp-boundaries`.
- **Wrapping UIKit controllers in SwiftUI:** `UIViewControllerRepresentable` + a
  `Coordinator` delegate — see `swiftui-uikit-interop`. Full wrappers in `references/contactsui.md`.
- **Privacy:** requires `NSContactsUsageDescription` in Info.plist (app crashes on request without it). Reconcile the privacy manifest with `app-store-review`.

## Contents

- [Info.plist & authorization](#authorization)
- [Fetching contacts](#fetching)
- [keysToFetch & partial fetches](#keys)
- [Predicates](#predicates)
- [Creating / updating / deleting](#saving)
- [ContactsUI (picker, detail, access button)](#contactsui)
- [Change history (incremental sync)](#change-history)
- [Correctness checklist](#checklist)
- References: `references/contactsui.md`, `references/change-history.md`

<a id="authorization"></a>
## Info.plist & authorization

- **Required:** `NSContactsUsageDescription` — a specific reason string. Missing key = hard crash on `requestAccess`.
- `CNAuthorizationStatus` (from `CNContactStore.authorizationStatus(for: .contacts)`, a **static** method):
  - `.notDetermined` — never asked; the only state where `requestAccess` shows a prompt.
  - `.restricted` — blocked by parental controls / MDM; cannot be changed by the user.
  - `.denied` — user said no; you must deep-link to Settings, you cannot re-prompt.
  - `.authorized` — full access to all contacts.
  - `.limited` (**iOS 18+**) — user granted access to a chosen subset only. Fetches transparently return just that subset; writes still work. Do **not** treat `.limited` as an error — most apps should support it.
- `requestAccess(for:completionHandler:)` is the only public request API — there is **no** first-party `async` overload. The reply runs on an arbitrary queue; hop to `@MainActor` for UI. Wrap it for async/await (see `swift-concurrency`):

```swift
import Contacts

extension CNContactStore {
    func requestContactsAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { cont in
            requestAccess(for: .contacts) { granted, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: granted) }
            }
        }
    }
}
```

- Calling a fetch while `.notDetermined` triggers the prompt implicitly, but request explicitly so you control timing and can branch on `.denied`/`.limited`.
- **The system pickers (`CNContactPickerViewController`) need no permission at all** — they run out-of-process and hand back only what the user taps. Prefer a picker over `requestAccess` when you just need one contact.

<a id="fetching"></a>
## Fetching contacts

One `CNContactStore` instance; it is thread-safe and cheap to keep.

```swift
let store = CNContactStore()
let keys: [CNKeyDescriptor] = [
    CNContactGivenNameKey as CNKeyDescriptor,
    CNContactFamilyNameKey as CNKeyDescriptor,
    CNContactPhoneNumbersKey as CNKeyDescriptor,
]

// A) Targeted match — returns *unified* contacts (links merged across accounts).
let predicate = CNContact.predicateForContacts(matchingName: "Ada")
let matches = try store.unifiedContacts(matching: predicate, keysToFetch: keys)

// B) By identifier (stable across launches; persist this, not the object).
let one = try store.unifiedContact(withIdentifier: id, keysToFetch: keys)

// C) Enumerate ALL contacts — streaming, low memory. Only path for a full scan.
let request = CNContactFetchRequest(keysToFetch: keys)
request.sortOrder = .userDefault
try store.enumerateContacts(with: request) { contact, stop in
    // called once per contact on a background thread
    // stop.pointee = true   // early exit
}
```

- `unifiedContacts(matching:)` requires a predicate — there is **no** "match everything" predicate. Use `enumerateContacts` for a full sweep.
- **Unified vs raw:** the `unified…` APIs merge linked cards from different accounts (iCloud + Exchange) into one `CNContact` whose `identifier` is the unified id. Prefer them for display.
- `enumerateContacts` runs its block synchronously on a background thread and throws on failure. Do UI work back on `@MainActor`.
- Perf: enumerating thousands of contacts is slow — fetch the **narrowest** `keysToFetch`, and predicate-filter at the store instead of scanning in Swift.

<a id="keys"></a>
## keysToFetch & partial fetches

- A fetched `CNContact` is a **partial** snapshot. Accessing a property whose key you did **not** request throws `CNContactPropertyNotFetchedException` (a hard crash). Fetch every key you will read.
- Guard optional access with `contact.isKeyAvailable(_:)` or `areKeysAvailable(_:)`; re-fetch with more keys if needed.
- Composite descriptors when handing contacts to system UI or a formatter:
  - `CNContactFormatter.descriptorForRequiredKeys(for: .fullName)` — before `CNContactFormatter.string(from:)`.
  - `CNContactViewController.descriptorForRequiredKeys()` — before presenting the detail view (it needs *many* keys).
- Common keys: `CNContactGivenNameKey`, `CNContactFamilyNameKey`, `CNContactOrganizationNameKey`, `CNContactPhoneNumbersKey`, `CNContactEmailAddressesKey`, `CNContactPostalAddressesKey`, `CNContactImageDataKey` (large — omit unless shown), `CNContactThumbnailImageDataKey`, `CNContactImageDataAvailableKey` (cheap boolean gate before requesting image data), `CNContactIdentifierKey`.
- Multi-value fields are `[CNLabeledValue<T>]`:

```swift
for phone in contact.phoneNumbers {            // CNLabeledValue<CNPhoneNumber>
    let number = phone.value.stringValue
    let label  = CNLabeledValue<NSString>.localizedString(
        forLabel: phone.label ?? "")           // "mobile", "home", …
}
```

<a id="predicates"></a>
## Predicates

Only these `CNContact` class predicates are valid, and they **cannot be compounded** (no `AND`/`OR`/`NSCompoundPredicate`):

- `predicateForContacts(matchingName:)` — fuzzy name match; use with `unifiedContacts`.
- `predicateForContacts(withIdentifiers:)` — batch by id.
- `predicateForContacts(matching: CNPhoneNumber)` (iOS 11+).
- `predicateForContacts(matchingEmailAddress:)` (iOS 11+).
- `predicateForContactsInGroup(withIdentifier:)`, `predicateForContactsInContainer(withIdentifier:)`.

```swift
let p = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: "+15551234567"))
let hits = try store.unifiedContacts(matching: p, keysToFetch: keys)
```

- To filter on anything the predicates don't cover (e.g. birthday, organization substring), `enumerateContacts` with `request.predicate = nil` and filter in the block.
- Containers = accounts (iCloud, Exchange, Local); groups live within a container. `store.defaultContainerIdentifier()` is where new contacts land by default. See `references/change-history.md` for container/group traversal.

<a id="saving"></a>
## Creating / updating / deleting

Mutations go through `CNSaveRequest` executed on the store. **Writes require `.authorized` or `.limited`** — a picker alone can't save.

```swift
// CREATE
let newContact = CNMutableContact()
newContact.givenName = "Grace"
newContact.familyName = "Hopper"
newContact.phoneNumbers = [
    CNLabeledValue(label: CNLabelPhoneNumberMobile,
                   value: CNPhoneNumber(stringValue: "+15550101"))
]
newContact.emailAddresses = [
    CNLabeledValue(label: CNLabelWork, value: "grace@example.com" as NSString)
]
let save = CNSaveRequest()
save.add(newContact, toContainerWithIdentifier: nil)   // nil = default container
try store.execute(save)

// UPDATE — fetch, take a mutable copy, mutate, update.
let fetched = try store.unifiedContact(withIdentifier: id,
    keysToFetch: [CNContactPhoneNumbersKey as CNKeyDescriptor,
                  CNContactViewController.descriptorForRequiredKeys()])
guard let editable = fetched.mutableCopy() as? CNMutableContact else { return }
editable.phoneNumbers.append(
    CNLabeledValue(label: CNLabelHome, value: CNPhoneNumber(stringValue: "+15550…")))
let upd = CNSaveRequest(); upd.update(editable); try store.execute(upd)

// DELETE
let del = CNSaveRequest(); del.delete(editable); try store.execute(del)
```

- `CNMutableContact` is a `class` (reference type). Build new contacts fresh; edit existing ones only via `mutableCopy()` of a **fetched** contact so its `identifier` is preserved.
- To update, the mutable copy must have been fetched with the keys you intend to touch — otherwise you overwrite unfetched fields or crash reading them.
- Addresses: `CNMutablePostalAddress` (`street`, `city`, `postalCode`, `country`) wrapped in a `CNLabeledValue`.
- Batch many changes into **one** `CNSaveRequest` — it's a single transaction and one permission-tracked write.
- `execute` throws `CNError` (`.authorizationDenied`, `.insertedRecordAlreadyExists`, `.validationMultipleErrors`, …). Map to user-facing errors; see `references/change-history.md`.

<a id="contactsui"></a>
## ContactsUI (picker, detail, access button)

`ContactsUI` is UIKit — wrap each controller in a `UIViewControllerRepresentable` for SwiftUI (`swiftui-uikit-interop`). Full, ready-to-paste wrappers live in `references/contactsui.md`; the essentials:

- **`CNContactPickerViewController`** — the out-of-process picker. **No permission needed.**
  - Delegate `CNContactPickerDelegate`: `contactPicker(_:didSelect: CNContact)` (single), `contactPicker(_:didSelect: [CNContact])` (multi — implementing the array method switches the picker to multi-select), `contactPicker(_:didSelect: CNContactProperty)` / `didSelect: [CNContactProperty]` (property/value selection), `contactPickerDidCancel(_:)`.
  - `displayedPropertyKeys` limits which fields the detail shows; `predicateForEnablingContact` greys out non-qualifying rows; `predicateForSelectionOfContact` decides whether a tap returns the contact vs drills in.
  - Contacts returned are pre-fetched with a fixed key set — request extra keys via a follow-up store fetch by `identifier` if you need more.
- **`CNContactViewController`** — the system detail/edit card.
  - `init(for:)` (display; the contact must be fetched with `descriptorForRequiredKeys()`), `init(forNewContact:)` (create sheet, prefilled optional), `init(forUnknownContact:)` (add-to-contacts flow). Set `contactStore` and `delegate` (`CNContactViewControllerDelegate`).
- **Limited access (iOS 18+)** — SwiftUI `ContactAccessButton(queryString:)` (from `ContactsUI`) lets a user grant *additional specific* contacts to a `.limited` app inline, without escalating to full access. Use it instead of nagging toward Settings when you only need a few more cards. (UIKit access-picker API for expanding the limited set: verify the exact selector against current docs before use.)

<a id="change-history"></a>
## Change history (incremental sync)

To sync contacts into your own store, persist a token and fetch only deltas instead of re-enumerating everything.

```swift
// 1. Persist this after any full sync (opaque Data — store in your DB/Keychain).
let token: Data = store.currentHistoryToken

// 2. Later, fetch only what changed since `token`.
let req = CNChangeHistoryFetchRequest()
req.startingToken = savedToken
let result = try store.enumeratorForChangeHistoryFetchRequest(req)   // CNFetchResult<NSEnumerator>
for case let event as CNChangeHistoryEvent in result.value {
    switch event {
    case let e as CNChangeHistoryAddContactEvent:    /* e.contact */    break
    case let e as CNChangeHistoryUpdateContactEvent: /* e.contact */    break
    case let e as CNChangeHistoryDeleteContactEvent: /* e.contactIdentifier */ break
    default: break
    }
}
let newToken = result.currentHistoryToken   // save for next round
```

- Also observe `CNContactStoreDidChange` (NSNotification) to know *when* to run the delta fetch; the notification carries no payload — the token diff is the source of truth.
- The event enumerator is Objective-C-flavoured (`NSEnumerator` of `CNChangeHistoryEvent` subclasses) and awkward in Swift — cast each event. Set `req.shouldUnifyResults = true` for unified-contact events. Details, event subclasses, and a `CNContactStoreDidChange` observer in `references/change-history.md`.

<a id="checklist"></a>
## Correctness checklist

- [ ] `NSContactsUsageDescription` present and specific — else `requestAccess` crashes.
- [ ] Handle all `CNAuthorizationStatus` cases; treat `.limited` (iOS 18+) as success, `.denied`/`.restricted` route to Settings (no re-prompt).
- [ ] Every property read is covered by `keysToFetch`; guard optional reads with `isKeyAvailable` — never touch an unfetched key.
- [ ] Use `descriptorForRequiredKeys()` before `CNContactFormatter` / `CNContactViewController`.
- [ ] Full scans use `enumerateContacts` (streaming); targeted reads use `unifiedContacts(matching:)` — no compound predicates.
- [ ] Prefer the picker (no permission, out-of-process) when you only need a contact or property.
- [ ] Updates edit a `mutableCopy()` of a *fetched* contact (preserves `identifier`); creates use a fresh `CNMutableContact`.
- [ ] Batch mutations into one `CNSaveRequest`; catch `CNError` from `execute`.
- [ ] Persist the contact `identifier`, never the `CNContact` object, across launches.
- [ ] Sync with `currentHistoryToken` + `CNChangeHistoryFetchRequest`, not repeated full enumerations; observe `CNContactStoreDidChange`.
- [ ] Marshal `enumerateContacts` / `requestAccess` results back to `@MainActor` before touching UI.
