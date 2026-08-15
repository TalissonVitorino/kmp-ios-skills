---
name: passkit
description: "Apple Pay and Wallet passes on iOS with PassKit — build a PKPaymentRequest (merchantIdentifier, supportedNetworks, merchantCapabilities .threeDSecure/.credit/.debit, PKPaymentSummaryItem, PKContactField shipping/billing), present PKPaymentAuthorizationController with its delegate (async didAuthorizePayment → PKPaymentAuthorizationResult, shipping/contact/coupon/merchant-session updates), the SwiftUI PayWithApplePayButton and UIKit PKPaymentButton, recurring/deferred/automatic-reload requests, and Wallet passes (PKPass, PKPassLibrary, PKAddPassesViewController, AddPassToWalletButton, .pkpass distribution). Use when adding an Apple Pay checkout, merchant-token handoff to a processor, subscriptions/top-ups via Apple Pay, or adding boarding passes / loyalty cards to Wallet. For DIGITAL goods & subscriptions use StoreKit (`storekit`) instead — Apple Pay is for physical goods/services. Money amounts come from `kmp-money`; format display with `swift-formatstyle`; read the user's own Wallet transactions/balances with `financekit`; protect the payment-token round-trip with `swift-security`."
---

# PassKit — Apple Pay & Wallet (iOS)

Apple Pay checkout and Apple Wallet pass integration for a fintech iOS app,
grounded in Apple's PassKit framework. `import PassKit` (and `import PassKitUI`
is not needed — SwiftUI controls ship in `PassKit`).

## Apple Pay vs StoreKit — pick the right one first

- **Apple Pay (this skill):** payment for **physical goods, physical services,
  donations, or transactions processed by your own payment processor** (card
  networks → your PSP → your bank). You receive an encrypted payment token.
- **StoreKit / IAP (`storekit`):** **digital** content, in-app currency, and
  app subscriptions. App Review **rejects** Apple Pay used for digital goods.
- **FinanceKit (`financekit`):** *read* the user's own Wallet transactions and
  balances — orthogonal to taking a payment.

## Contents

- [Setup & entitlements](#setup)
- [Availability checks](#availability)
- [PKPaymentRequest](#request)
- [Summary items & amounts](#summary-items)
- [Contact / shipping fields](#contact)
- [Present with PKPaymentAuthorizationController](#controller)
- [SwiftUI PayWithApplePayButton](#swiftui-button)
- [UIKit PKPaymentButton](#uikit-button)
- [Merchant validation & processing the token](#processing)
- [Recurring / deferred / automatic-reload](#merchant-tokens)
- [Wallet passes](#passes)
- [Correctness checklist](#checklist)
- References: `references/apple-pay.md`, `references/wallet-passes.md`

<a id="setup"></a>
## Setup & entitlements

- **Merchant ID:** create `merchant.<reverse-dns>` in the Apple Developer portal;
  add the **Apple Pay Payment Processing** capability in Xcode (writes the
  `com.apple.developer.in-app-payments` entitlement listing your merchant IDs).
- **Wallet passes:** the **Wallet** capability + a **Pass Type ID**
  (`pass.<reverse-dns>`) are needed to *sign* `.pkpass` files server-side and to
  scope `PKPassLibrary` reads to your passes.
- Register merchant IDs / process tokens with your payment service provider
  (Stripe, Adyen, Braintree, etc.) — they either decrypt the token or you do it
  with your Apple Pay Payment Processing certificate.
- `merchantIdentifier` in code must exactly match the entitlement value.

<a id="availability"></a>
## Availability checks

```swift
import PassKit

// Device supports Apple Pay at all (hardware + region).
let canPay = PKPaymentAuthorizationController.canMakePayments()

// User actually has a usable card for your networks/capabilities.
let ready = PKPaymentAuthorizationController.canMakePayments(
    usingNetworks: [.visa, .masterCard, .amex],
    capabilities: [.threeDSecure])
```

- `canMakePayments()` → device/region capable. `canMakePayments(usingNetworks:capabilities:)`
  → a provisioned card exists for those networks. Use the first to decide whether
  to *offer* Apple Pay, the second to decide **button vs. "Set up Apple Pay"**.
- If `canMakePayments()` is true but no card, the button may still lead the user
  to add a card — Apple's guidance is to show the button and let the sheet guide setup.

<a id="request"></a>
## PKPaymentRequest

```swift
let request = PKPaymentRequest()
request.merchantIdentifier = "merchant.com.example.wallet"   // == entitlement
request.merchantCapabilities = [.threeDSecure]               // see below
request.countryCode = "US"                                    // ISO 3166-1 alpha-2 (merchant country)
request.currencyCode = "USD"                                  // ISO 4217
request.supportedNetworks = [.visa, .masterCard, .amex, .discover]
request.paymentSummaryItems = [ /* see next section */ ]
```

- **`merchantCapabilities`** (`PKMerchantCapability`): `.threeDSecure` (**required**
  — always include), `.credit`, `.debit`, `.emv`. Include `.credit`/`.debit` only
  to *restrict* to those funding sources; omit to accept both.
- **`supportedNetworks`** (`[PKPaymentNetwork]`): e.g. `.visa`, `.masterCard`,
  `.amex`, `.discover`, `.maestro`, `.girocard`, plus regional (`.cartesBancaires`,
  `.interac`, …). Confirm your PSP supports each.
- `countryCode` is the **merchant's** country; `supportedCountries` (`Set<String>?`)
  optionally restricts issuing-card countries.
- `applicationData: Data?` — hashed into the token for your own correlation.

<a id="summary-items"></a>
## Summary items & amounts

The **last** item is the grand total shown on the sheet's "Pay" line; its label is
usually your company name.

```swift
// Amounts are NSDecimalNumber — build from a decimal STRING, never a Double.
func item(_ label: String, _ amount: String,
          _ type: PKPaymentSummaryItemType = .final) -> PKPaymentSummaryItem {
    PKPaymentSummaryItem(label: label, amount: NSDecimalNumber(string: amount), type: type)
}

request.paymentSummaryItems = [
    item("Subtotal", "42.00"),
    item("Shipping", "5.00"),
    item("Tax",      "3.76"),
    item("ACME, Inc.", "50.76"),          // grand total (last)
]
```

- `PKPaymentSummaryItemType`: `.final` (fixed) or `.pending` (amount not yet known —
  e.g. final shipping/tax computed after address selection; renders greyed).
- Amounts flow from your `Money` type (**`kmp-money`**): emit a plain decimal
  **string** in the currency's scale and pass `NSDecimalNumber(string:)`. Never
  build `NSDecimalNumber` from a `Double` — it reintroduces binary error.
- The total must equal the sum of the line items or the sheet rejects the request.

<a id="contact"></a>
## Contact / shipping fields

```swift
request.requiredShippingContactFields = [.postalAddress, .name, .phoneNumber]
request.requiredBillingContactFields  = [.postalAddress]
request.shippingType = .shipping                // .shipping/.delivery/.storePickup/.servicePickup
request.shippingMethods = [
    { let m = PKShippingMethod(label: "Standard", amount: NSDecimalNumber(string: "5.00"))
      m.identifier = "standard"; m.detail = "3–5 business days"; return m }(),
]
```

- `PKContactField`: `.emailAddress`, `.name`, `.phoneNumber`, `.postalAddress`,
  `.phoneticName`. Request the **minimum** you need — you get PII back in the token.
- Coupons (iOS 15+): `request.supportsCouponCode = true` and optionally seed
  `request.couponCode`; handle edits in the delegate's `didChangeCouponCode`.
- Only ask for shipping fields for **physical** fulfilment; for digital receipts an
  email is usually enough (and stay onside of the StoreKit rule above).

<a id="controller"></a>
## Present with PKPaymentAuthorizationController

The programmatic path (works from UIKit or SwiftUI). `PKPaymentAuthorizationController`
is not a view controller — it presents its own sheet on the active scene.

```swift
final class ApplePayCoordinator: NSObject, PKPaymentAuthorizationControllerDelegate {
    private var completion: ((Bool) -> Void)?

    func pay(_ request: PKPaymentRequest, completion: @escaping (Bool) -> Void) {
        guard PKPaymentAuthorizationController.canMakePayments() else { completion(false); return }
        self.completion = completion
        let controller = PKPaymentAuthorizationController(paymentRequest: request)
        controller.delegate = self
        controller.present { presented in
            if !presented { completion(false) }
        }
    }

    // Called after Face ID/Touch ID authorizes. Send the token to YOUR server here.
    func paymentAuthorizationController(
        _ controller: PKPaymentAuthorizationController,
        didAuthorizePayment payment: PKPayment
    ) async -> PKPaymentAuthorizationResult {
        do {
            try await backend.process(paymentToken: payment.token.paymentData,   // opaque, encrypted
                                      billing: payment.billingContact,
                                      shipping: payment.shippingContact)
            completion?(true)
            return PKPaymentAuthorizationResult(status: .success, errors: nil)
        } catch {
            completion?(false)
            // Surface field errors so the sheet highlights the offending row.
            return PKPaymentAuthorizationResult(status: .failure, errors: [error])
        }
    }

    // REQUIRED. Called on completion or cancel — dismiss and finish here, not above.
    func paymentAuthorizationControllerDidFinish(_ controller: PKPaymentAuthorizationController) {
        controller.dismiss()
    }
}
```

- **Two-phase contract:** return `.success` from `didAuthorizePayment` **only after**
  your processor confirms; the sheet then shows the checkmark. `didFinish` always
  fires (success *or* the user cancelling) — do teardown there.
- The delegate reply runs off the main actor; hop to `@MainActor` for UI.
- Dynamic updates (all `async`, all optional) let you recost when the user changes
  a selection in the sheet:
  - `didSelectShippingMethod` → `PKPaymentRequestShippingMethodUpdate`
  - `didSelectShippingContact` → `PKPaymentRequestShippingContactUpdate`
  - `didSelectPaymentMethod` → `PKPaymentRequestPaymentMethodUpdate`
  - `didChangeCouponCode` → `PKPaymentRequestCouponCodeUpdate`
  - each returns a fresh `paymentSummaryItems` (+ optional `errors` / `shippingMethods`).
- Build field-level errors with `PKPaymentRequest.paymentShippingAddressInvalidError(withKey:localizedDescription:)`,
  `paymentBillingAddressInvalidError(...)`, `paymentContactInvalidError(withContactField:...)`,
  `paymentCouponCodeInvalidError(...)` — see `references/apple-pay.md`.

<a id="swiftui-button"></a>
## SwiftUI PayWithApplePayButton (iOS 16+)

Uses the same `PKPaymentRequest`; the button owns presentation.

```swift
import SwiftUI
import PassKit

PayWithApplePayButton(.checkout, request: makeRequest()) { phase in
    switch phase {
    case .willAuthorize:
        break                                   // last chance to tweak before Face ID
    case let .didAuthorize(payment, resultHandler):
        Task {
            let ok = await backend.process(token: payment.token.paymentData)
            resultHandler(PKPaymentAuthorizationResult(status: ok ? .success : .failure,
                                                       errors: nil))
        }
    case .didFinish:
        break                                   // dismissed (paid or cancelled)
    @unknown default:
        break
    }
}
.payWithApplePayButtonStyle(.automatic)         // .black / .white / .whiteOutline / .automatic
.frame(height: 44)
```

- Label is `PayWithApplePayButtonLabel`: `.plain`, `.buy`, `.checkout`, `.book`,
  `.subscribe`, `.reload`, `.addMoney`, `.topUp`, `.order`, `.donate`, `.setUp`, …
  Pick the verb that matches the action (App Review checks this).
- The closure receives a `PayWithApplePayButtonPaymentAuthorizationPhase`; call the
  `resultHandler` from `.didAuthorize` with your `PKPaymentAuthorizationResult`.
- Initializer variants add merchant-session and per-selection handlers
  (`onMerchantSessionRequested`, `onShippingContactChanged`, …) and a `fallback:`
  view for devices that can't pay — mirror the delegate methods above.
- `PayWithApplePayButton` **auto-hides** where Apple Pay is unavailable, so an
  availability guard around it is optional (unlike the raw controller path).

<a id="uikit-button"></a>
## UIKit PKPaymentButton

```swift
let button = PKPaymentButton(paymentButtonType: .checkout, paymentButtonStyle: .automatic)
button.addTarget(self, action: #selector(startApplePay), for: .touchUpInside)
button.cornerRadius = 8    // property, not layer.cornerRadius
```

- `PKPaymentButtonType`: `.plain`, `.buy`, `.setUp`, `.inStore`, `.donate`,
  `.checkout`, `.book`, `.subscribe`, `.reload`, `.addMoney`, `.topUp`, `.order`,
  `.rent`, `.support`, `.contribute`, `.tip`.
- `PKPaymentButtonStyle`: `.white`, `.whiteOutline`, `.black`, `.automatic`
  (follows light/dark). Do **not** re-skin the button — Apple's HIG requires the
  system control.

<a id="processing"></a>
## Merchant validation & processing the token

- `payment.token.paymentData` is an **opaque, encrypted** blob for your PSP —
  never inspect, log, or persist it in plaintext; hand it straight to your backend
  over TLS (pin per `swift-security`). `payment.token.paymentMethod` gives display
  metadata (network, `.debit`/`.credit`, masked digits) safe for UI.
- **Merchant session (web/PSP flows):** some processors need a validated Apple Pay
  merchant session — implement `didRequestMerchantSessionUpdate` (controller) or
  `onMerchantSessionRequested` (SwiftUI): your server calls Apple's merchant-
  validation endpoint and returns a `PKPaymentRequestMerchantSessionUpdate`. In-app
  card flows through a PSP SDK usually don't need this.
- Return `.success` only after the charge/authorization is confirmed server-side;
  a premature `.success` shows the user a checkmark for a payment that may fail.

<a id="merchant-tokens"></a>
## Recurring / deferred / automatic-reload (merchant tokens, iOS 16+)

Attach exactly one of these to a `PKPaymentRequest` to request a **merchant token**
for future/variable charges. Each pairs with its own summary-item type and needs a
`managementURL` (where users manage the agreement in Wallet).

```swift
// Subscription (fixed cadence). PKRecurringPaymentSummaryItem carries the schedule.
let regular = PKRecurringPaymentSummaryItem(label: "Monthly", amount: NSDecimalNumber(string: "9.99"))
regular.intervalUnit = .month
regular.intervalCount = 1
// optional: regular.startDate / regular.endDate

let recurring = PKRecurringPaymentRequest(
    paymentDescription: "Pro subscription",
    regularBilling: regular,
    managementURL: URL(string: "https://example.com/manage")!)
recurring.billingAgreement = "Renews monthly until cancelled."
// optional: recurring.trialBilling = PKRecurringPaymentSummaryItem(...)
//           recurring.tokenNotificationURL = URL(...)  // server push on token changes
request.recurringPaymentRequest = recurring
```

- **Deferred** (charge later, e.g. pre-order): `PKDeferredPaymentRequest` with a
  `PKDeferredPaymentSummaryItem(label:amount:)` whose `deferredDate` property you set;
  supports `freeCancellationDate` / `freeCancellationDateTimeZone`. (iOS 16.4+.)
- **Automatic reload** (top up when a balance drops): `PKAutomaticReloadPaymentRequest`
  with a `PKAutomaticReloadPaymentSummaryItem(label:amount:)` whose `thresholdAmount`
  property you set — reload `amount` fires when the balance falls below `thresholdAmount`.
  Ideal for a stored-value wallet / transit card top-up.
- All require `merchantCapabilities` to include `.threeDSecure` and a PSP that
  supports Apple Pay merchant tokens. Full field-by-field setup in
  `references/apple-pay.md`.

<a id="passes"></a>
## Wallet passes (PKPass)

You **create & sign** `.pkpass` bundles on a **server** (your Pass Type ID cert);
the app only **presents and adds** them. Never ship the signing certificate.

```swift
import PassKit

let pass = try PKPass(data: pkpassData)          // bytes downloaded from your server

// Already added?
let library = PKPassLibrary()
let alreadyAdded = library.containsPass(pass)
```

### Add flow (UIKit)

```swift
let vc = PKAddPassesViewController(pass: pass)!   // or init(passes: [PKPass])
vc.delegate = self                                // PKAddPassesViewControllerDelegate
present(vc, animated: true)

func addPassesViewControllerDidFinish(_ controller: PKAddPassesViewController) {
    controller.dismiss(animated: true)
}
```

### Add flow (SwiftUI, iOS 16+)

```swift
AddPassToWalletButton(pass: pass) { error in       // completion/error handler
    if let error { /* log, show retry */ }
}
.addPassToWalletButtonStyle(.automatic)            // .automatic / .black / .blackOutline
.frame(height: 44)
```

- `PKPassLibrary`: `PKPassLibrary.isPassLibraryAvailable()`, `passes()`,
  `pass(withPassTypeIdentifier:serialNumber:)`, `containsPass(_:)`,
  `addPasses(_:withCompletionHandler:)` (`[PKPass]`, not `Data`), `replacePass(with:)`,
  `removePass(_:)`. Reading passes needs the `com.apple.developer.pass-type-identifiers`
  entitlement scoped to your Pass Type IDs.
- **Distribution:** host the signed `.pkpass` and serve it as
  `application/vnd.apple.pkpass`; a Safari/Mail tap opens the Add-to-Wallet sheet
  directly. For **updates**, implement the PassKit **web service** (registration +
  push via APNs) so Wallet pulls new versions — see `references/wallet-passes.md`.
- UIKit `PKAddPassButton(addPassButtonStyle:)` (`.black` / `.blackOutline`) is the
  pre-iOS-16 equivalent of `AddPassToWalletButton`.

## KMP boundary

- Keep Apple Pay in **`iosMain`/Swift** — PassKit has no Kotlin binding. Expose a
  `commonMain` `interface PaymentSheet { suspend fun pay(order: Order): PaymentResult }`
  and bind the `actual` to a Swift coordinator (see `expect-actual`,
  `kmp-ios-integration`).
- Shared code owns the **order/amount** (`Money` from `kmp-money`) and receives only
  a result/opaque reference — never the raw payment token.

<a id="checklist"></a>
## Correctness checklist

- [ ] Apple Pay used for **physical** goods/services only; digital goods go through StoreKit.
- [ ] `merchantIdentifier` matches the in-app-payments entitlement exactly.
- [ ] `merchantCapabilities` includes `.threeDSecure`.
- [ ] Amounts are `NSDecimalNumber(string:)` from a `Money` decimal — **never** from `Double`.
- [ ] Summary-item total equals the sum of the line items; company name on the last item.
- [ ] Only the `PKContactField`s you actually need are requested.
- [ ] `didAuthorizePayment` returns `.success` **only after** the processor confirms; field errors returned on `.failure`.
- [ ] `paymentAuthorizationControllerDidFinish` implemented and dismisses the sheet.
- [ ] `payment.token.paymentData` never logged/persisted in plaintext; sent to backend over pinned TLS (`swift-security`).
- [ ] Dynamic recosting handled if shipping/coupon/payment-method can change the total.
- [ ] Recurring/deferred/reload requests set a `managementURL` and a clear `billingAgreement`.
- [ ] `.pkpass` files signed **server-side**; the Pass Type ID certificate is never in the app bundle.
- [ ] `containsPass(_:)` checked before offering "Add to Wallet"; add-button label verb matches the action.
