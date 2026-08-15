# AppEntity & EntityQuery — depth

Grounded in Apple's App Intents documentation. All symbols verified against
`developer.apple.com/documentation/appintents`.

## Query protocol menu

`EntityQuery` (required base) resolves entities from ids. Layer in the refinement
that matches how the system needs to find your data:

| Protocol | Adds requirement | Use when |
|---|---|---|
| `EntityQuery` | `entities(for: [ID])` | Always — id round-trip. |
| `EnumerableEntityQuery` | `allEntities()` | The full set is small and bounded (e.g. account types). |
| `EntityStringQuery` | `entities(matching: String)` | Free-text search in the Shortcuts picker. |
| `EntityPropertyQuery` | property/comparator/sort spec + `entities(matching:)` | Structured "find X where property …" filtering. |

```swift
struct PayeeQuery: EntityStringQuery {
    @Dependency var directory: PayeeDirectory

    func entities(for ids: [PayeeEntity.ID]) async throws -> [PayeeEntity] {
        try await directory.payees(ids: ids)
    }
    func entities(matching string: String) async throws -> [PayeeEntity] {
        try await directory.search(string)
    }
    func suggestedEntities() async throws -> [PayeeEntity] {
        try await directory.frequent(limit: 5)
    }
}
```

### EntityPropertyQuery skeleton

```swift
struct TransactionQuery: EntityPropertyQuery {
    static var properties = QueryProperties {
        Property(\TransactionEntity.$amount) {
            LessThanComparator { NSPredicate(format: "amount < %@", $0 as NSNumber) }
            GreaterThanComparator { NSPredicate(format: "amount > %@", $0 as NSNumber) }
        }
        Property(\TransactionEntity.$date) {
            EqualToComparator { NSPredicate(format: "date == %@", $0 as NSDate) }
        }
    }
    static var sortingOptions = SortingOptions {
        SortableBy(\TransactionEntity.$date)
    }

    func entities(for ids: [TransactionEntity.ID]) async throws -> [TransactionEntity] { … }
    func entities(matching comparators: [NSPredicate],
                  mode: ComparatorMode,
                  sortedBy: [Sort<TransactionEntity>],
                  limit: Int?) async throws -> [TransactionEntity] { … }
    func suggestedEntities() async throws -> [TransactionEntity] { … }
}
```

## @Property vs plain stored fields

- `@Property(title:)` — visible to the system: shown in pickers, usable in
  `EntityPropertyQuery` filters and in `parameterSummary`. Only value types the
  framework understands (String, numbers, Bool, Date, Measurement, etc.).
- Plain `let`/`var` — internal to your code; the system never sees them.
- `@ComputedProperty` — a get-only property backed by your model; combine with
  `indexingKey:` / `customIndexingKey:` for Spotlight (see `system-surfaces.md`).

## DisplayRepresentation

```swift
var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
        title: "\(name)",
        subtitle: "\(kind)",
        image: .init(systemName: "creditcard"))
}
static let typeDisplayRepresentation = TypeDisplayRepresentation(
    name: "Account", numericFormat: "\(placeholder: .int) accounts")
```

- `title` is what the user sees in pickers, snippets, and Siri readouts. Keep it
  human, localized, and free of sensitive data.

## AppEnum

```swift
enum AccountKind: String, AppEnum {
    case checking, savings, credit
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Account Kind"
    static let caseDisplayRepresentations: [AccountKind: DisplayRepresentation] = [
        .checking: "Checking", .savings: "Savings", .credit: "Credit Card",
    ]
}
```

- Backed by a `String`/`Int` raw value that persists inside saved shortcuts — don't
  renumber/rename cases without a migration story.

## Identifier discipline (fintech)

- `id` must be a stable business key (account id, payee id) — **never** an array
  index or a value that changes on reorder.
- Do not embed secrets in `id`; it is stored by the system inside saved shortcuts
  and Spotlight records.
- `entities(for:)` should tolerate ids that no longer exist (deleted account) by
  returning fewer entities, not throwing.
