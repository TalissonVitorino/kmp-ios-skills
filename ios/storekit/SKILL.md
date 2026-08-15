---
name: storekit
description: "In-app purchases and subscriptions on iOS/iPadOS/macOS with StoreKit 2 (iOS 26 era) — fetch products with Product.products(for:), buy with Product.purchase and switch on PurchaseResult (.success/.pending/.userCancelled), always unwrap VerificationResult (.verified/.unverified), gate access from Transaction.currentEntitlements, and reconcile out-of-app changes via the Transaction.updates listener. Covers Product.SubscriptionInfo status/RenewalState/RenewalInfo, SwiftUI SubscriptionStoreView/StoreView/ProductView with subscriptionStatusTask/currentEntitlementTask, intro/promotional/win-back offers + offer-code redemption, beginRefundRequest, manageSubscriptionsSheet, Ask to Buy, Family Sharing, the .storekit test config, and server-side trust via App Store Server Notifications V2 / App Store Server API. Use for paywalls, entitlement checks, restore, or subscription status. For money/decimal math use kmp-money; for currency display use swift-formatstyle; for Apple Pay / Wallet passes use passkit; for pre-submission IAP review use app-store-review; for the KMP entitlement boundary use expect-actual and kmp-ios-integration."
---

# StoreKit 2 (In-App Purchases & Subscriptions)

Modern async StoreKit for a fintech iOS app: sell products, verify transactions,
gate entitlements, and keep the server as the source of truth. Grounded in Apple's
StoreKit, StoreKit Views, and StoreKit Test frameworks (iOS 15+ APIs; iOS 26 era).

- **Use StoreKit 2** (`import StoreKit`, `Product`/`Transaction`), not the deprecated
  `SKPaymentQueue`/`SKProduct` StoreKit 1 API, for any new code.
- **Digital goods and subscriptions only.** Real-world goods/services and money
  movement go through Apple Pay / your PSP — see `passkit`. Mixing them up is an
  App Store rejection (see `app-store-review`).
- **KMP boundary:** IAP is Apple-native — keep it in `iosMain`/Swift. Expose a
  `commonMain` `interface EntitlementStore { fun isSubscribed(): Boolean }` and bind
  an `actual` that reads the verified StoreKit entitlement; see `expect-actual` and
  `kmp-ios-integration`. Never let shared code decide purchase validity.
- **Trust the server, not the client.** The device signal is for UX; grant paid
  features from a server that validates transactions (App Store Server API) and
  reacts to App Store Server Notifications V2 — see `references/server-and-security.md`.

## Contents

- [Setup](#setup)
- [Fetch products](#fetch-products)
- [Purchase + PurchaseResult](#purchase)
- [Verification (VerificationResult)](#verification)
- [Entitlements + the updates listener](#entitlements)
- [Subscriptions (status / RenewalState)](#subscriptions)
- [SwiftUI store views](#swiftui-views)
- [Offers (intro / promotional / win-back / offer codes)](#offers)
- [Refunds & manage subscriptions](#refunds)
- [Ask to Buy & Family Sharing](#family)
- [StoreKit testing (.storekit)](#testing)
- [Correctness checklist](#checklist)
- References: `references/server-and-security.md`, `references/offers-and-testing.md`

<a id="setup"></a>
## Setup

- Add the **In-App Purchase** capability; configure products in App Store Connect
  (or a `.storekit` file for local testing — see below).
- Product IDs are opaque strings; keep them in one typed source of truth:

```swift
import StoreKit

enum ProductID {
    static let proMonthly = "com.example.pro.monthly"
    static let proYearly  = "com.example.pro.yearly"
    static let all: [String] = [proMonthly, proYearly]
    static let subscriptionGroupID = "21387428"   // App Store Connect group ID
}
```

- Do purchase work in an `@Observable` store object (`swiftui-observation`) owned at
  app scope, and start the transaction listener **at launch**, before any UI.

<a id="fetch-products"></a>
## Fetch products

`Product.products(for:)` is `async throws` and returns `[Product]` (unordered; the
array omits IDs the App Store doesn't recognize).

```swift
let products = try await Product.products(for: ProductID.all)
let sorted = products.sorted { $0.price < $1.price }
```

- Each `Product` exposes `id`, `type` (`.consumable`, `.nonConsumable`,
  `.autoRenewable`, `.nonRenewable`), `displayName`, `description`, `price`
  (`Decimal`), and `displayPrice` (already localized — prefer it for UI).
- `product.subscription` is a `Product.SubscriptionInfo?` — non-nil only for
  `.autoRenewable` products (see [Subscriptions](#subscriptions)).
- To format `price` yourself, use `Decimal.formatted(.currency(code:))` from
  `swift-formatstyle`; for shared-layer money math use `kmp-money`. **Never** move
  `price` through a `Double`.

<a id="purchase"></a>
## Purchase + PurchaseResult

`product.purchase(options:)` presents the system sheet and returns a
`Product.PurchaseResult` — a three-case enum you must switch over exhaustively.

```swift
@discardableResult
func buy(_ product: Product) async throws -> Transaction? {
    let result = try await product.purchase(options: [
        .appAccountToken(currentUserToken),   // UUID linking the purchase to your account
    ])

    switch result {
    case .success(let verification):
        let transaction = try checkVerified(verification)   // see below
        await grantAccess(for: transaction)
        await transaction.finish()                          // REQUIRED — see note
        return transaction

    case .pending:
        // Deferred: Ask to Buy (parental approval) or SCA. No entitlement yet;
        // the transaction will arrive later via Transaction.updates.
        return nil

    case .userCancelled:
        return nil

    @unknown default:
        return nil
    }
}
```

- **Always `await transaction.finish()`** once you've delivered the content and
  recorded it server-side. Unfinished transactions are redelivered on every launch
  via `Transaction.updates` (StoreKit's built-in retry) and consumables stay stuck.
- `.appAccountToken(_:)` is a `UUID` that ties the transaction to your user account
  and flows through to server notifications — use it, never put a raw user ID in a
  product ID or URL.
- Purchase options also carry offers and quantities — see [Offers](#offers).
- `PurchaseError`/`StoreKitError` are thrown for network/system failures; treat a
  thrown error as "not purchased", surface a retry, and do not grant access.

<a id="verification"></a>
## Verification (VerificationResult)

StoreKit wraps `Transaction`, `Product.SubscriptionInfo.RenewalInfo`, and
`AppTransaction` in `VerificationResult<T>`, which is `.verified(T)` or
`.unverified(T, VerificationError)`. It performs on-device JWS signature checking
for you — but you must **unwrap and reject `.unverified`**.

```swift
enum StoreError: Error { case failedVerification }

func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
    switch result {
    case .verified(let safe):
        return safe
    case .unverified(_, let error):
        throw StoreError.failedVerification    // tampered / untrusted — do not honor
    }
}
```

- On-device verification proves the JWS is validly signed by Apple; it does **not**
  prove the transaction wasn't refunded or shared. For entitlements that unlock
  paid value, confirm against your server (App Store Server API) too.
- `Transaction` fields you'll use: `productID`, `id`, `originalID`, `purchaseDate`,
  `expirationDate` (subscriptions), `revocationDate`/`revocationReason` (refund or
  family removal), `ownershipType` (`.purchased` / `.familyShared`), `isUpgraded`,
  `appAccountToken`.

<a id="entitlements"></a>
## Entitlements + the updates listener

Two things every app needs: (1) read current access, (2) listen for changes that
happen outside a purchase call.

**Current access** — `Transaction.currentEntitlements` is an async sequence of the
customer's active, non-revoked entitlements (latest transaction per product):

```swift
func isEntitled(to productID: String) async -> Bool {
    for await result in Transaction.currentEntitlements {
        guard case .verified(let t) = result else { continue }
        if t.productID == productID && t.revocationDate == nil { return true }
    }
    return false
}
```

**The listener** — `Transaction.updates` emits transactions from renewals, Ask to
Buy approvals, purchases on other devices, refunds, and offer redemptions. Start it
at launch and never stop it; missing it means missed purchases.

```swift
final class TransactionObserver {
    private var task: Task<Void, Never>?

    init() {
        // Detached at launch so no transaction is missed before UI exists.
        task = Task.detached(priority: .background) { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
    }
    deinit { task?.cancel() }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        if transaction.revocationDate != nil {
            await revokeAccess(for: transaction.productID)      // refunded / family-revoked
        } else if let exp = transaction.expirationDate, exp < .now {
            // expired subscription — no action
        } else {
            await grantAccess(for: transaction.productID)
        }
        await transaction.finish()
    }
}
```

- Use `Transaction.latest(for:)` for the most recent transaction of one product, and
  `Transaction.all` for full history (e.g. receipt reconstruction).
- `AppStore.sync()` forces a manual restore; wire it to an explicit "Restore
  Purchases" button only. Routine access should come from `currentEntitlements` —
  restore is not a per-launch call.

<a id="subscriptions"></a>
## Subscriptions (status / RenewalState)

For auto-renewables, `product.subscription` (`Product.SubscriptionInfo`) gives group,
period, offers, and live status.

```swift
guard let sub = product.subscription else { return }

// Group-wide status (one entry per subscription in the group / family member):
let statuses = try await sub.status                       // [Product.SubscriptionInfo.Status]
for status in statuses {
    let renewalState = status.state                       // RenewalState (below)
    let info = try checkVerified(status.renewalInfo)      // RenewalInfo (verify it!)
    let txn  = try checkVerified(status.transaction)      // current period's Transaction

    if renewalState == .subscribed && !info.willAutoRenew {
        // Active but set to cancel at period end — good moment for a win-back offer.
    }
}
```

- `Product.SubscriptionInfo.RenewalState` cases: `.subscribed`, `.expired`,
  `.inBillingRetryPeriod`, `.inGracePeriod`, `.revoked`. Treat `.inGracePeriod` and
  `.inBillingRetryPeriod` as **still entitled** (bill is being retried); `.expired`
  and `.revoked` lose access.
- `RenewalInfo` carries `willAutoRenew`, `autoRenewPreference` (the product it will
  renew to — reflects upgrades/downgrades/crossgrades), `expirationReason`,
  `gracePeriodExpirationDate`, and `currentProductID`. **Verify it** like any
  `VerificationResult`.
- Intro-offer eligibility: `await sub.isEligibleForIntroOffer` (Bool), or
  `Product.SubscriptionInfo.isEligibleForIntroOffer(for: groupID)`.
- Multiple entries in `status` mean Family Sharing — see [Family](#family).

<a id="swiftui-views"></a>
## SwiftUI store views

StoreKit ships ready-made, StoreKit-connected views — prefer them over hand-rolled
paywalls; they localize price, handle purchase/restore, and meet review guidelines.

```swift
import StoreKit
import SwiftUI

// Full subscription paywall for one group:
SubscriptionStoreView(groupID: ProductID.subscriptionGroupID) {
    MyMarketingContent()                    // your header/branding
}
.subscriptionStoreControlStyle(.prominentPicker)   // or .buttons, .picker, .pagedProminentPicker
.storeButton(.visible, for: .restorePurchases)
.subscriptionStoreControlIcon { product, info in Image(systemName: "star.fill") }

// A grid/collection of one-time products:
StoreView(ids: ProductID.all)
    .storeButton(.hidden, for: .cancellation)
    .productViewStyle(.compact)

// A single product cell:
ProductView(id: ProductID.proYearly)
    .productViewStyle(.large)
```

- Drive your own UI from these declarative task modifiers (they subscribe and
  refresh automatically):
  - `.subscriptionStatusTask(for: groupID) { state in … }` — `state.value` is
    `[Product.SubscriptionInfo.Status]`.
  - `.currentEntitlementTask(for: productID) { state in … }` — reacts to the current
    entitlement (`VerificationResult<Transaction>?`).
  - `.storeProductsTask(for: ids) { … }` — load products for custom layouts.
- Handle completed purchases from a view with `.onInAppPurchaseCompletion { product, result in … }`.
- `EntitlementTaskState` exposes `.loading` / `.success(value)` / `.failure(error)` —
  render a spinner while `.loading`, never assume "not subscribed" mid-load.

<a id="offers"></a>
## Offers (intro / promotional / win-back / offer codes)

Pass offers as `Product.PurchaseOption`s to `purchase(options:)`. Details and full
signatures in `references/offers-and-testing.md`.

- **Introductory offer** — automatic when the customer is eligible
  (`isEligibleForIntroOffer`); no purchase option needed in production. Only one
  intro per subscription group, ever.
- **Promotional offer** (existing/lapsed subscribers) — requires a signature your
  **server** generates (product ID, offer ID, nonce, timestamp, signed with your
  subscription key). Production API:
  `.promotionalOffer(offerID:keyID:nonce:signature:timestamp:)`. In StoreKit-test
  only, the unsigned `.promotionalOffer(id:)` form simulates redemption.
- **Win-back offer** (iOS 18+) — target churned subscribers. Discover with
  `product.subscription?.winBackOffers`, then
  `.winBackOffer(_ offer: Product.SubscriptionOffer)`. The App Store can also surface
  these automatically.
- **Offer codes** — redeem App Store Connect codes with the SwiftUI modifier
  `.offerCodeRedemption(isPresented:onCompletion:)`, or
  `AppStore.presentOfferCodeRedeemSheet(from:)` in UIKit. Redemption arrives via
  `Transaction.updates`.

```swift
// Promotional offer (signature comes from YOUR server, never hardcoded):
let signed = try await backend.signPromotionalOffer(productID: product.id, offerID: "winter25")
let result = try await product.purchase(options: [
    .promotionalOffer(offerID: signed.offerID, keyID: signed.keyID,
                      nonce: signed.nonce, signature: signed.signature,
                      timestamp: signed.timestamp),
])
```

<a id="refunds"></a>
## Refunds & manage subscriptions

```swift
// Customer-initiated refund request (SwiftUI needs a UIWindowScene):
let status = try await Transaction.beginRefundRequest(for: transaction.id, in: windowScene)
switch status {
case .success:      break   // App Store received the request (decision takes ≤48h)
case .userCancelled: break
@unknown default:    break
}
```

- **Don't revoke access on request** — the refund is not final. Wait for the
  `revocationDate` to appear via `Transaction.updates` (and the `REFUND` server
  notification) before removing entitlement.
- Manage/cancel subscription: SwiftUI `.manageSubscriptionsSheet(isPresented:)`;
  UIKit `AppStore.showManageSubscriptions(in:)`. This is Apple's UI — you cannot
  cancel a subscription programmatically.

<a id="family"></a>
## Ask to Buy & Family Sharing

- **Ask to Buy** surfaces as `PurchaseResult.pending`. Grant nothing; the approved
  (or declined) transaction later flows through `Transaction.updates`. Show a
  "waiting for approval" state, not an error.
- **Family Sharing** (enable per product in App Store Connect): a transaction from a
  family member has `ownershipType == .familyShared`. Treat it as fully entitled;
  don't special-case features by owner. When a member loses access, you get a
  transaction with a `revocationDate` (family revocation) — handle it like any
  revocation in the listener.
- `Product.SubscriptionInfo.status` returns one `Status` per family member; the
  customer is entitled if **any** entry is in an active state.

<a id="testing"></a>
## StoreKit testing (.storekit)

- **Xcode / local:** add a **StoreKit Configuration** file (`.storekit`) defining
  products, offers, and subscription groups; select it in the scheme's Run > Options.
  Runs entirely on-device with no App Store Connect round-trip; supports Ask to Buy,
  refunds, and time-rate acceleration for renewals.
- **Automated (`StoreKitTest`):** `SKTestSession` drives purchases, refunds, and
  `askToBuyEnabled` / `approveAskToBuyTransaction(identifier:)` in unit tests. See
  `references/offers-and-testing.md` and `ios-testing` for harness setup.
- **Sandbox:** real App Store Connect sandbox accounts exercise the true purchase
  flow (offer signing, server notifications) before release.
- `.simulatesAskToBuyInSandbox(true)` as a purchase option forces the pending path in
  sandbox for testing parental approval.

<a id="checklist"></a>
## Correctness checklist

- [ ] StoreKit 2 (`Product`/`Transaction`), not deprecated `SKPaymentQueue`/`SKProduct`.
- [ ] `Transaction.updates` listener started at launch (detached), before UI, never cancelled while running.
- [ ] Every `VerificationResult` unwrapped; `.unverified` is rejected, not honored.
- [ ] `PurchaseResult` switched exhaustively incl. `.pending` (Ask to Buy) and `@unknown default`.
- [ ] `transaction.finish()` called after content delivered + recorded — no unfinished transactions.
- [ ] Access read from `currentEntitlements`; `AppStore.sync()` only behind an explicit Restore button.
- [ ] Server is source of truth: validate via App Store Server API, react to App Store Server Notifications V2.
- [ ] Grace period / billing retry states treated as still-entitled; refunds revoked only on `revocationDate`.
- [ ] Promotional-offer signatures generated server-side, never embedded in the app.
- [ ] `.appAccountToken` (UUID) links purchases to accounts; no user IDs in product IDs or URLs.
- [ ] Prices via `displayPrice` / `FormatStyle`, never through `Double` (`swift-formatstyle`, `kmp-money`).
- [ ] Family-shared transactions (`ownershipType == .familyShared`) entitled like owned ones.
- [ ] Tested against a `.storekit` config and Sandbox before shipping (`app-store-review` pass done).
