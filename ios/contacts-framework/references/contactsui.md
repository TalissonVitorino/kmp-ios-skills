# ContactsUI in SwiftUI — full wrappers

`ContactsUI` ships UIKit controllers. Bridge each with `UIViewControllerRepresentable`
and a `Coordinator` that owns the delegate. General bridging rules: `swiftui-uikit-interop`.

## Contact picker (single selection)

The picker runs **out-of-process** and needs **no Contacts permission** — the user
grants exactly what they tap. Ideal for "attach a contact" flows.

```swift
import SwiftUI
import ContactsUI

struct ContactPicker: UIViewControllerRepresentable {
    var onSelect: (CNContact) -> Void
    var onCancel: () -> Void = {}

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        // Optional: restrict the detail view and which rows are selectable.
        picker.displayedPropertyKeys = [CNContactPhoneNumbersKey, CNContactEmailAddressesKey]
        // Only enable contacts that have at least one phone number:
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        return picker
    }

    func updateUIViewController(_ vc: CNContactPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let parent: ContactPicker
        init(_ parent: ContactPicker) { self.parent = parent }

        func contactPicker(_ picker: CNContactPickerViewController,
                           didSelect contact: CNContact) {
            parent.onSelect(contact)
        }
        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            parent.onCancel()
        }
    }
}
```

Present with `.sheet(isPresented:)`. The `CNContact` handed back is pre-fetched with a
fixed key set (name, all values); if you need extra keys (e.g. postal addresses),
re-fetch by `contact.identifier` against a `CNContactStore` (needs authorization).

## Contact picker (multi-selection / property selection)

Implementing the **array** delegate method switches the same controller to multi-select:

```swift
func contactPicker(_ picker: CNContactPickerViewController,
                   didSelect contacts: [CNContact]) { parent.onSelectMany(contacts) }

// Single property (e.g. user taps one phone number):
func contactPicker(_ picker: CNContactPickerViewController,
                   didSelect contactProperty: CNContactProperty) {
    // contactProperty.key == CNContactPhoneNumbersKey
    // contactProperty.value as? CNPhoneNumber
}
```

- `predicateForSelectionOfProperty` — when it evaluates true, tapping a contact returns a
  single `CNContactProperty` (via `didSelect: CNContactProperty`) instead of the whole card.
- `predicateForSelectionOfContact` — when true, a tap returns the contact immediately;
  when false (default `nil`), tapping opens the detail card first.
- These property/selection predicates and the multi-array method are mutually exclusive in
  behaviour — pick the interaction you want and implement only its matching delegate methods.

## Contact detail / edit card

```swift
struct ContactDetailView: UIViewControllerRepresentable {
    let contact: CNContact          // fetch with CNContactViewController.descriptorForRequiredKeys()
    let store: CNContactStore

    func makeUIViewController(context: Context) -> UINavigationController {
        let vc = CNContactViewController(for: contact)
        vc.contactStore = store
        vc.delegate = context.coordinator
        vc.allowsEditing = true
        return UINavigationController(rootViewController: vc)
    }
    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, CNContactViewControllerDelegate {
        // Return false to suppress the default action (e.g. dialing) on a property tap.
        func contactViewController(_ vc: CNContactViewController,
            shouldPerformDefaultActionFor property: CNContactProperty) -> Bool { true }
        // Called when the user finishes editing (contact == nil if deleted).
        func contactViewController(_ vc: CNContactViewController,
            didCompleteWith contact: CNContact?) {}
    }
}
```

- **Display** an existing contact: `init(for:)` — it needs a *heavily* fetched contact, so
  use `descriptorForRequiredKeys()` as (one of) the keys.
- **Create**: `init(forNewContact: CNContact?)` — pass `nil` for a blank card, or a
  `CNMutableContact` to prefill. The controller saves via its `contactStore`.
- **Add-to-existing** ("Unknown" card, e.g. a phone number from elsewhere):
  `init(forUnknownContact: CNContact)` — offers "Create New Contact" / "Add to Existing".

## Limited access (iOS 18+)

When the app holds `.limited` authorization, let the user widen the visible set inline
rather than sending them to Settings:

```swift
import ContactsUI   // SwiftUI ContactAccessButton is here (iOS 18+)

struct AddMoreContacts: View {
    @State private var query = ""
    var body: some View {
        ContactAccessButton(queryString: query) { identifiers in
            // identifiers the user just granted access to; fetch them from the store.
        }
    }
}
```

- `ContactAccessButton` surfaces matching contacts the app can't yet see and, on tap, adds
  them to the app's authorized subset — no full-access escalation.
- There is also a UIKit contact-access-picker presentation for expanding the limited set
  programmatically; confirm its exact selector/signature against current Apple docs before
  relying on it, as this area moved between iOS 18 point releases.
