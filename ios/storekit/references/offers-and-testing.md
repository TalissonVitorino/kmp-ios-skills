# Offers & testing (StoreKit 2)

## Offer types at a glance

| Offer | Who | Signed? | How to apply |
|---|---|---|---|
| Introductory | New subscribers, once per group | No | Automatic when `isEligibleForIntroOffer` |
| Promotional | Existing / lapsed subscribers | **Yes (server)** | `.promotionalOffer(offerID:keyID:nonce:signature:timestamp:)` |
| Win-back (iOS 18+) | Churned subscribers | No (App Store or app) | `.winBackOffer(_:)` |
| Offer code | Anyone with a code | No | `.offerCodeRedemption` / redeem sheet |

## Introductory offers

```swift
if let sub = product.subscription, await sub.isEligibleForIntroOffer {
    // Show "7 days free" etc. `sub.introductoryOffer` describes the offer:
    if let intro = sub.introductoryOffer {
        // intro.type == .introductory; intro.paymentMode: .freeTrial / .payAsYouGo / .payUpFront
        // intro.period, intro.price, intro.displayPrice
    }
}
```

- Eligibility is per subscription **group**, not per product, and per Apple ID /
  family. StoreKit applies it automatically at purchase — you don't pass an option.

## Promotional offers (signature required in production)

Your server signs each offer with the subscription key (App Store Connect >
Integrations). The app never holds the key.

```swift
struct SignedOffer { let offerID, keyID, signature: String; let nonce: UUID; let timestamp: Int }

func purchasePromo(_ product: Product, _ s: SignedOffer) async throws -> Product.PurchaseResult {
    try await product.purchase(options: [
        .promotionalOffer(offerID: s.offerID, keyID: s.keyID,
                          nonce: s.nonce, signature: s.signature, timestamp: s.timestamp),
    ])
}
```

- The signature covers appBundleID, keyID, productID, offerID, appAccountToken (if
  any), nonce, and timestamp. A stale/replayed nonce is rejected.
- In a `.storekit` test config there are no real keys — use the unsigned
  `.promotionalOffer(id: "offerIdentifier")` form to simulate redemption.

## Win-back offers (iOS 18+)

```swift
guard let sub = product.subscription else { return }
let offers = sub.winBackOffers                       // [Product.SubscriptionOffer]
if let offer = offers.first {
    let result = try await product.purchase(options: [.winBackOffer(offer)])
}
```

- The App Store can also present win-back offers automatically (App Store surfaces,
  and via the `WIN_BACK_OFFER` App Store Connect config). Configure the offer in App
  Store Connect first; only eligible (previously-subscribed, now-lapsed) customers
  see them.

## Offer codes

```swift
// SwiftUI:
.offerCodeRedemption(isPresented: $showRedeem) { result in
    switch result {
    case .success(let verification): /* checkVerified + grant */ break
    case .failure(let error):        /* surface */ break
    }
}

// UIKit:
try await AppStore.presentOfferCodeRedeemSheet(from: windowScene)
```

- Codes are generated in App Store Connect (one-time or custom campaign codes).
- Redemption completes asynchronously and also surfaces via `Transaction.updates` —
  handle it there so a background redemption isn't missed.

## `.storekit` configuration file

- **New File > StoreKit Configuration File.** Either "synced" with App Store Connect
  (read-only mirror) or standalone (fully editable locally).
- Define products, prices, subscription groups, intro/promo offers, and localizations.
- Enable it: scheme > **Run > Options > StoreKit Configuration**.
- Editor tools: adjust **subscription renewal rate** (accelerate time), toggle
  **Ask to Buy**, simulate **refunds**, force **billing retry** / **grace period**,
  and clear the transaction history — all without App Store Connect.

## Automated tests with `SKTestSession`

```swift
import StoreKitTest

let session = try SKTestSession(configurationFileNamed: "Products")
session.clearTransactions()
session.askToBuyEnabled = true            // force pending / parental approval
// ... drive a purchase in the app under test ...
try session.approveAskToBuyTransaction(identifier: txnID)   // or declineAskToBuyTransaction
session.disableDialogs = true             // no interactive sheets in CI
```

- `SKTestSession` also supports `buyProduct`, `refundTransaction`,
  `expireSubscription`, `forceRenewalOfSubscription`, and setting
  `timeRate` for accelerated renewals.
- Pair with Swift Testing / XCTest (`ios-testing`). Keep entitlement-granting logic
  behind a protocol so it can be unit-tested with a fake store, and reserve
  `SKTestSession` for integration coverage of the real StoreKit path.

## Sandbox vs test config

- `.storekit` / `SKTestSession`: fast, offline, deterministic — daily dev + CI.
- **Sandbox** (App Store Connect sandbox testers): exercises real offer signing,
  server notifications, and Apple's actual purchase flow — required before release.
- The two report different `environment` values in server notifications
  (`Sandbox` vs `Production`); never grant production access from a Sandbox event.
