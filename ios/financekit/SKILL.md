---
name: financekit
description: "Read Wallet financial data on iOS with FinanceKit + FinanceKitUI in a fintech app — FinanceStore.shared authorization (requestAuthorization / authorizationStatus, AuthorizationStatus) and availability (isDataAvailable), querying Transaction / Account / AccountBalance via TransactionQuery / AccountQuery / AccountBalanceQuery with Swift Predicate, incremental change tracking (transactionHistory / accountHistory returning FinanceStore.History<Model>, Changes, HistoryToken, isMonitoring), the FinanceKitUI TransactionPicker, Apple Card / Apple Cash / Savings + U.K. connected accounts, iOS 26 background delivery (BackgroundDeliveryExtension, enableBackgroundDelivery, BackgroundDataType, UpdateFrequency), Wallet orders (saveOrder / containsOrder, FullyQualifiedOrderIdentifier), and the com.apple.developer.financekit entitlement + NSFinancialDataUsageDescription. Use when reading transactions / balances / accounts from Wallet, gating on FinanceKit authorization, or monitoring financial-data changes. Persist fetched values with `swift-security`, model amounts with `kmp-money`, and render them with `swift-formatstyle`; for Apple Pay / Wallet passes see `passkit`, background execution see `background-processing`, and entitlement / privacy-manifest review see `app-store-review`."
---

# FinanceKit (iOS / iPadOS)

Read-only access to a person's Apple Wallet financial data — accounts, balances,
transactions, and orders — with explicit per-account consent. All data is
on-device; no network is involved in a query. Grounded in Apple's FinanceKit and
FinanceKitUI frameworks.

- **Availability:** U.S. iOS 17.4+ (Apple Card, Apple Cash, Savings); U.K. iOS 18.4+ (Open Banking "connected" cards/accounts). Background delivery extension is **iOS 26+**.
- **Access is gated, not free:** you must request the **managed** `com.apple.developer.financekit` entitlement from Apple (org-level account, approved use case) before any API returns data.
- **Sibling skills:** persist anything you fetch with `swift-security` (never `UserDefaults`); model/compute amounts with `kmp-money`; format for display with `swift-formatstyle`. Apple Pay & passes are `passkit`, not FinanceKit.

## Contents

- [Entitlement & Info.plist](#setup)
- [Authorization & availability](#auth)
- [Data model](#model)
- [Querying accounts, balances, transactions](#query)
- [Predicates](#predicates)
- [Incremental change tracking (history)](#history)
- [TransactionPicker (FinanceKitUI)](#picker)
- [Wallet orders](#orders)
- [Background delivery (iOS 26)](#background)
- [Correctness checklist](#checklist)
- Depth: `references/history-and-background.md`, `references/predicates-and-model.md`

<a id="setup"></a>
## Entitlement & Info.plist

- **Entitlement:** `com.apple.developer.financekit` — a *managed* entitlement. Apply through your Apple Developer account; approval is required and gated on eligibility (see "Get started with FinanceKit"). Without it, `requestAuthorization()` fails as not-entitled.
- **Info.plist:** `NSFinancialDataUsageDescription` (String) — **required**; missing it crashes the authorization request. Explain plainly what the app does with the data (e.g. "Categorizes your Apple Card transactions to show monthly spending.").
- Orders APIs (`saveOrder` / `containsOrder`) work from iOS 17.0 and do **not** require the financial-data authorization; account/balance/transaction reads do.
- `import FinanceKit` for the store and models; `import FinanceKitUI` for `TransactionPicker`.

<a id="auth"></a>
## Authorization & availability

Everything goes through the singleton `FinanceStore.shared`.

```swift
import FinanceKit

let store = FinanceStore.shared

// 1. Is the feature even present on this device/region?
guard FinanceStore.isDataAvailable(.financialData) else {
    // Unsupported region, unsupported device, or no eligible accounts.
    return
}

// 2. Check, then request only if undecided — requesting shows the system
//    consent sheet plus the per-account picker.
var status = try await store.authorizationStatus()
if status == .notDetermined {
    status = try await store.requestAuthorization()
}

switch status {
case .authorized:   break            // proceed to queries
case .denied:       return           // route the user to Settings; do not re-prompt in a loop
case .notDetermined: return          // user dismissed without choosing
@unknown default:   return
}
```

- `authorizationStatus() async throws -> AuthorizationStatus` and `requestAuthorization() async throws -> AuthorizationStatus`. Cases: `.notDetermined`, `.denied`, `.authorized`.
- `requestAuthorization()` is a one-time system prompt **plus** an account-selection screen — the user shares *specific* accounts, so an authorized app may still see a subset of what's in Wallet. Never assume you see every account.
- `static func isDataAvailable(_:) -> Bool` takes a `FinanceStore.DataType` (e.g. `.financialData`); call it before touching the store so you can hide UI on unsupported devices/regions.
- Re-check `authorizationStatus()` on each launch — the user can revoke or change shared accounts in Settings at any time.

<a id="model"></a>
## Data model

All money is `CurrencyAmount { let amount: Decimal; let currencyCode: String }` — a **`Decimal`**, so keep it exact end-to-end (bridge to `kmp-money`'s `Money`, never to `Double`).

- **`Account`** — `id: UUID`, `displayName: String`, `institutionName: String`, `currencyCode: String`, `accountDescription: String?`, `openingDate: Date?`, plus one of:
  - `assetAccount: AssetAccount?` — Apple Cash, Savings (funds you hold).
  - `liabilityAccount: LiabilityAccount?` — Apple Card; carries `creditInformation: AccountCreditInformation` (`creditLimit`, `nextPaymentDueDate`, `minimumNextPaymentAmount`, `overduePaymentAmount` — all `CurrencyAmount?`/`Date?`).
- **`AccountBalance`** — `id: UUID`, `accountID: UUID`, `currencyCode: String`, `currentBalance: CurrentBalance`, plus `available: Balance?` and `booked: Balance?`. A `Balance` is `{ amount: CurrencyAmount; asOfDate: Date; creditDebitIndicator: CreditDebitIndicator }`.
  - **Read the `creditDebitIndicator`** (`.credit` / `.debit`) — the amount is unsigned; direction lives in the indicator. **Booked** excludes pending; **available** reflects immediately spendable funds. They differ; pick deliberately.
- **`Transaction`** — `id: UUID`, `accountID: UUID`, `transactionAmount: CurrencyAmount`, `creditDebitIndicator`, `status: TransactionStatus`, `transactionType: TransactionType`, `transactionDate: Date`, `postedDate: Date?`, `merchantName: String?`, `merchantCategoryCode: MerchantCategoryCode?` (ISO 18245), `transactionDescription` / `originalTransactionDescription: String`, and for FX: `foreignCurrencyAmount: CurrencyAmount?` + `foreignCurrencyExchangeRate: Decimal?`.
  - Many fields are optional or "may not be available" (`merchantName`, `merchantCategoryCode`, `postedDate`, `transactionType`) — code defensively.

Full field tables in `references/predicates-and-model.md`.

<a id="query"></a>
## Querying accounts, balances, transactions

Each query type is `init(sortDescriptors:predicate:limit:offset:)` over a Swift `SortDescriptor` and `Predicate`. Page with `limit` + `offset`.

```swift
// Accounts the user shared with this app.
let accountQuery = AccountQuery(
    sortDescriptors: [SortDescriptor(\.displayName)],
    predicate: nil,
    limit: nil,
    offset: nil)
let accounts: [Account] = try await store.accounts(query: accountQuery)

// Balances for one account.
let balanceQuery = AccountBalanceQuery(
    sortDescriptors: [SortDescriptor(\.available?.asOfDate)],
    predicate: #Predicate { $0.accountID == account.id })
let balances: [AccountBalance] = try await store.accountBalances(query: balanceQuery)

// Most recent 50 transactions on that account.
let txQuery = TransactionQuery(
    sortDescriptors: [SortDescriptor(\.transactionDate, order: .reverse)],
    predicate: #Predicate { $0.accountID == account.id },
    limit: 50,
    offset: 0)
let transactions: [Transaction] = try await store.transactions(query: txQuery)
```

- `accounts(query:) async throws -> [Account]`, `accountBalances(query:) async throws -> [AccountBalance]`, `transactions(query:) async throws -> [Transaction]`.
- A one-shot query returns the current snapshot. For "keep me updated," use history (below), not polling.
- These are `async throws` and can be interrupted — run off the main actor and treat a thrown error as "no data this pass," not a crash.

<a id="predicates"></a>
## Predicates

Filter with Swift's `#Predicate` on the model's own fields, or with FinanceKit's built-in factory predicates:

```swift
// Built-in factories on TransactionQuery:
let byType     = TransactionQuery.predicate(forTransactionTypes: [.purchase, .refund])
let byStatus   = TransactionQuery.predicate(forStatuses: [.booked])           // vs .pending
let byCategory = TransactionQuery.predicate(forMerchantCategoryCodes: [groceriesMCC])

// Or hand-rolled #Predicate over Transaction fields:
let recentLarge = #Predicate<Transaction> { tx in
    tx.transactionDate > cutoff && tx.accountID == account.id
}
```

- `predicate(forTransactionTypes:)`, `predicate(forStatuses:)`, `predicate(forMerchantCategoryCodes:)` are the supported factory predicates — prefer them over reconstructing the same logic by hand.
- Not every Swift operator/keypath is translatable in a FinanceKit `#Predicate`; keep predicates to simple comparisons on stored fields. Do heavy/derived filtering in Swift after fetch. See `references/predicates-and-model.md`.

<a id="history"></a>
## Incremental change tracking (history)

Instead of re-querying, ask for changes since a saved `HistoryToken`. The call returns a `FinanceStore.History<Model>` — an **`AsyncSequence`** whose elements are `FinanceStore.Changes<Model>`.

```swift
// Persist the token (Keychain — see swift-security) between launches.
let history = store.transactionHistory(
    forAccountID: account.id,
    since: savedToken,          // nil = from the beginning
    isMonitoring: true)         // keep yielding as new data arrives

for try await changes in history {
    apply(inserted: changes.inserted,        // [Transaction]
          updated:  changes.updated,         // [Transaction]
          deleted:  changes.deleted)         // [Transaction.ID] — IDs only
    save(token: changes.newToken)            // resume point for next time
}
```

- `transactionHistory(forAccountID:since:isMonitoring:) -> FinanceStore.History<Transaction>` and `accountHistory(since:isMonitoring:) -> FinanceStore.History<Account>`.
- `Changes<Model>`: `inserted: [Model]`, `updated: [Model]`, `deleted: [Model.ID]` (identifiers, not full objects), `newToken: HistoryToken`. **Always persist `newToken`** after applying a batch — it is your resume point and prevents reprocessing.
- `isMonitoring: true` (the default) keeps the sequence live, delivering changes as the store updates — the `for await` loop does not end. Use `false` for a bounded "catch me up since token, then stop" drain.
- `deleted` gives IDs only; reconcile against your local store by ID.
- Not `Sendable`-free-for-all: iterate on a well-defined actor and hand results to your model layer. More in `references/history-and-background.md`.

<a id="picker"></a>
## TransactionPicker (FinanceKitUI)

A SwiftUI view (iOS 18.0+) that lets the user pick transactions **without** your app holding full transaction authorization — good for "attach a transaction to this expense/dispute" flows.

```swift
import SwiftUI
import FinanceKitUI

struct AttachTransactions: View {
    @State private var selection: [Transaction] = []

    var body: some View {
        TransactionPicker(selection: $selection) {
            Label("Choose transactions", systemImage: "creditcard")
        }
        .onChange(of: selection) { _, picked in
            // picked: [Transaction] the user explicitly chose
        }
    }
}
```

- `init(selection: Binding<[Transaction]>, @ViewBuilder label: () -> Label)`. `@MainActor`.
- The picker is user-mediated consent per selection — a lighter footprint than requesting full read authorization when you only need a few transactions.

<a id="orders"></a>
## Wallet orders

Save and check merchant **orders** in Wallet (order tracking). Distinct from financial-data reads — available from iOS 17.0, no financial-data entitlement needed.

```swift
let id = FullyQualifiedOrderIdentifier(
    orderTypeIdentifier: "com.example.store.order",   // your registered order type
    orderIdentifier: "A1B2C3")

// Save/update from a signed PKPass-style order archive you built server-side.
let result = try await store.saveOrder(signedArchive: signedOrderData)
switch result {
case .added:          break          // stored
case .newerExisting:  break          // Wallet already has a newer version — no-op
case .cancelled:      break          // the user cancelled the add
@unknown default:     break
}

// Idempotency check before re-saving.
let contains = try await store.containsOrder(matching: id, updatedDate: lastUpdated)
// .exists / .notFound / .newerExists / .olderExists
```

- `saveOrder(signedArchive: Data) async throws -> FinanceStore.SaveOrderResult` (`.added` / `.cancelled` / `.newerExisting`).
- `containsOrder(matching:updatedDate:) async throws -> FinanceStore.ContainsOrderResult` (`.exists` / `.notFound` / `.newerExists` / `.olderExists`); returns `.notFound` for orders your process isn't entitled to see.
- The archive is a **signed** order package (build/sign server-side, akin to a pass) — see `passkit` for the signing/packaging story.

<a id="background"></a>
## Background delivery (iOS 26)

A dedicated app extension is woken when shared data changes — refresh a widget, precompute a spending summary, update a cache — without the main app running.

```swift
// In the main app: register interest, then Wallet wakes your extension.
store.enableBackgroundDelivery(for: [.transactions, .accounts], frequency: .daily)
// store.disableBackgroundDelivery(for: [.orders])
// store.disableAllBackgroundDelivery()
```

```swift
// In the extension target:
import FinanceKit

@main
struct SpendingRefreshExtension: BackgroundDeliveryExtension {
    func didReceiveData(for types: [FinanceStore.BackgroundDataType]) async {
        // Drain history with the saved token, update your cache/widget.
        // Keep it short — you get a limited window.
    }
    func willTerminate() async {
        // Flush/persist before the system tears the extension down.
    }
}
```

- `enableBackgroundDelivery(for: [BackgroundDataType], frequency: UpdateFrequency)`, `disableBackgroundDelivery(for:)`, `disableAllBackgroundDelivery()`.
- `BackgroundDataType`: `.transactions`, `.accounts`, `.orders`. `UpdateFrequency` is a floor (e.g. `.daily`) — once a delivery fires, further deliveries are suppressed until the interval elapses, and **no data change ⇒ no delivery**.
- Extension conforms to `BackgroundDeliveryExtension` (`: AppExtension, BackgroundDeliveryExtensionProviding`); implement `didReceiveData(for:) async` and `willTerminate() async`.
- Do incremental work via `HistoryToken` (persist it in a shared, biometric-free Keychain item so the extension can read it — see `swift-security` access groups). Long or blocking work will be killed; if you need general background execution unrelated to FinanceKit deltas, that's `background-processing`. Full extension wiring in `references/history-and-background.md`.

<a id="checklist"></a>
## Correctness checklist

- [ ] `com.apple.developer.financekit` managed entitlement requested/approved; `NSFinancialDataUsageDescription` present in Info.plist (missing string crashes auth).
- [ ] `FinanceStore.isDataAvailable(.financialData)` checked before showing FinanceKit UI (region/device gating).
- [ ] `authorizationStatus()` inspected first; `requestAuthorization()` only when `.notDetermined`; `.denied` routes to Settings, no re-prompt loop.
- [ ] Re-check authorization each launch; never assume you see every Wallet account — the user shares a subset.
- [ ] Amounts kept as `Decimal`/`CurrencyAmount` end-to-end (bridge to `kmp-money`, never `Double`); `creditDebitIndicator` read for sign; `available` vs `booked` chosen deliberately.
- [ ] Optional transaction fields (`merchantName`, `merchantCategoryCode`, `postedDate`) handled as possibly nil.
- [ ] Predicates use the built-in factory predicates or simple `#Predicate` comparisons; derived filtering done in Swift post-fetch.
- [ ] Change tracking uses `transactionHistory`/`accountHistory` + persisted `HistoryToken` (in Keychain), not polling; `deleted` reconciled by ID; `newToken` saved after each batch.
- [ ] Queries run off the main actor; thrown errors treated as "no data this pass."
- [ ] Fetched financial data stored via `swift-security` (Keychain / encrypted at rest), never `UserDefaults`/plist/logs; nothing sensitive in analytics or URLs.
- [ ] Background delivery registered only for needed `BackgroundDataType`s; extension work is short and idempotent; `willTerminate()` flushes state.
- [ ] Orders (`saveOrder`/`containsOrder`) treated as separate from financial-data reads; `containsOrder` used for idempotency before re-saving.
