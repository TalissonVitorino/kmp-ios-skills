# FinanceKit — data model & predicates (depth)

Companion to `SKILL.md`. Field lists reflect the FinanceKit model; treat every
`?`/"may not be available" field as genuinely optional.

## CurrencyAmount

```swift
struct CurrencyAmount {
    let amount: Decimal        // exact — never bridge to Double
    let currencyCode: String   // ISO 4217
}
```

- Bridge to a shared `Money` type at the boundary (`kmp-money`); format for display with `swift-formatstyle` (`Decimal.formatted(.currency(code:))`).

## Account

```swift
struct Account {
    var id: UUID
    var displayName: String            // user-given name
    var institutionName: String
    var currencyCode: String
    var accountDescription: String?
    var openingDate: Date?
    var assetAccount: AssetAccount?        // exactly one of asset / liability is set
    var liabilityAccount: LiabilityAccount?
}
```

- **AssetAccount** — Apple Cash, Savings. Same descriptive fields (`institutionName`, `displayName`, `currencyCode`, `id`, `accountDescription`, `openingDate`).
- **LiabilityAccount** — Apple Card. Adds `creditInformation: AccountCreditInformation`:
  - `creditLimit: CurrencyAmount?`
  - `nextPaymentDueDate: Date?`
  - `minimumNextPaymentAmount: CurrencyAmount?` (minimum non-overdue payment)
  - `overduePaymentAmount: CurrencyAmount?`
- Branch on `assetAccount` vs `liabilityAccount` to decide which UI to show; don't assume Apple Card.

## AccountBalance

```swift
struct AccountBalance {
    let id: UUID
    let accountID: UUID
    let currencyCode: String
    let currentBalance: CurrentBalance   // available, booked, or both
    let available: Balance?
    let booked: Balance?
}

struct Balance {
    let amount: CurrencyAmount
    let asOfDate: Date
    let creditDebitIndicator: CreditDebitIndicator  // .credit / .debit
}
```

- `booked` = all posted transactions, excludes pending. `available` = immediately spendable. They diverge whenever pending activity exists — choose per feature (e.g. "spendable now" → available; "statement balance" → booked).
- Amounts are unsigned; direction comes from `creditDebitIndicator`. A debit balance on a liability account is money owed.

## Transaction

```swift
struct Transaction {
    let id: UUID
    let accountID: UUID
    let transactionAmount: CurrencyAmount
    let creditDebitIndicator: CreditDebitIndicator
    let status: TransactionStatus          // e.g. .pending / .booked
    let transactionType: TransactionType   // .purchase / .refund / .transfer / ... (may be unavailable)
    let transactionDate: Date
    let postedDate: Date?
    let merchantName: String?
    let merchantCategoryCode: MerchantCategoryCode?   // ISO 18245
    let transactionDescription: String
    let originalTransactionDescription: String        // unmodified
    let foreignCurrencyAmount: CurrencyAmount?         // when carried out in FX
    let foreignCurrencyExchangeRate: Decimal?
}
```

- Use `transactionDate` for "when it happened," `postedDate` for "when it cleared" (nil while pending).
- `merchantName`/`merchantCategoryCode` are frequently nil for transfers, fees, and interest — never force-unwrap.
- FX: when `foreignCurrencyAmount != nil`, `transactionAmount` is the settled home-currency amount and `foreignCurrencyExchangeRate` relates the two.

## Predicates

Two ways to filter, combinable:

### 1. Built-in factory predicates (preferred)

```swift
TransactionQuery.predicate(forTransactionTypes: [.purchase, .refund])
TransactionQuery.predicate(forStatuses: [.booked])
TransactionQuery.predicate(forMerchantCategoryCodes: [mcc1, mcc2])
```

These map to fields FinanceKit can filter server-side/in-store efficiently.

### 2. Swift `#Predicate` on stored fields

```swift
let p = #Predicate<Transaction> { tx in
    tx.accountID == id && tx.transactionDate >= start && tx.transactionDate < end
}
let q = TransactionQuery(
    sortDescriptors: [SortDescriptor(\.transactionDate, order: .reverse)],
    predicate: p, limit: 100, offset: 0)
```

- Keep `#Predicate` bodies to comparisons/`&&`/`||` over stored properties. Closures over derived/computed values or unsupported operators may fail to translate.
- For anything richer (regex on descriptions, grouping, running totals), fetch a bounded set and finish the work in Swift.
- Combine factory + custom by composing two queries or intersecting results in Swift; a single query takes one `predicate`.

## Sorting & paging

- `sortDescriptors: [SortDescriptor<Model>]` using key paths, e.g. `SortDescriptor(\.transactionDate, order: .reverse)`.
- Page with `limit` + `offset`. For steady incremental sync prefer **history tokens** over offset paging — offsets shift as new data lands.
