# Apple Pay — depth

Companion to `passkit/SKILL.md`. All `import PassKit`.

## Full delegate with dynamic recosting

```swift
extension ApplePayCoordinator {

    // User picked a different shipping method → adjust total.
    func paymentAuthorizationController(
        _ controller: PKPaymentAuthorizationController,
        didSelectShippingMethod shippingMethod: PKShippingMethod
    ) async -> PKPaymentRequestShippingMethodUpdate {
        let items = summaryItems(withShipping: shippingMethod.amount)
        return PKPaymentRequestShippingMethodUpdate(paymentSummaryItems: items)
    }

    // User picked a shipping address → recompute tax/shipping, or reject the region.
    func paymentAuthorizationController(
        _ controller: PKPaymentAuthorizationController,
        didSelectShippingContact contact: PKContact
    ) async -> PKPaymentRequestShippingContactUpdate {
        guard let region = contact.postalAddress?.isoCountryCode, region == "US" else {
            let err = PKPaymentRequest.paymentShippingAddressUnserviceableError(
                withLocalizedDescription: "We only ship within the US.")
            return PKPaymentRequestShippingContactUpdate(
                errors: [err], paymentSummaryItems: currentItems, shippingMethods: [])
        }
        let items = summaryItems(forState: contact.postalAddress?.state)
        return PKPaymentRequestShippingContactUpdate(
            errors: nil, paymentSummaryItems: items, shippingMethods: shippingOptions)
    }

    // User switched card (e.g. credit → debit) → surcharge/discount if applicable.
    func paymentAuthorizationController(
        _ controller: PKPaymentAuthorizationController,
        didSelectPaymentMethod paymentMethod: PKPaymentMethod
    ) async -> PKPaymentRequestPaymentMethodUpdate {
        let items = summaryItems(forFunding: paymentMethod.type)   // .debit / .credit / .prepaid / .store
        return PKPaymentRequestPaymentMethodUpdate(paymentSummaryItems: items)
    }

    // Coupon typed in the sheet (needs request.supportsCouponCode = true).
    func paymentAuthorizationController(
        _ controller: PKPaymentAuthorizationController,
        didChangeCouponCode couponCode: String
    ) async -> PKPaymentRequestCouponCodeUpdate {
        guard let discounted = try? await backend.apply(coupon: couponCode) else {
            let err = PKPaymentRequest.paymentCouponCodeInvalidError(
                localizedDescription: "That code isn't valid.")
            return PKPaymentRequestCouponCodeUpdate(errors: [err],
                paymentSummaryItems: currentItems, shippingMethods: shippingOptions)
        }
        return PKPaymentRequestCouponCodeUpdate(paymentSummaryItems: discounted.items)
    }
}
```

## Field-level errors

Return these in the `errors:` array of a `...Update` or in `PKPaymentAuthorizationResult(status: .failure, errors:)` so the sheet highlights the exact field instead of failing opaquely.

- `PKPaymentRequest.paymentBillingAddressInvalidError(withKey: CNPostalAddress.Keys..., localizedDescription:)`
- `PKPaymentRequest.paymentShippingAddressInvalidError(withKey:localizedDescription:)`
- `PKPaymentRequest.paymentShippingAddressUnserviceableError(withLocalizedDescription:)`
- `PKPaymentRequest.paymentContactInvalidError(withContactField: PKContactField, localizedDescription:)`
- `PKPaymentRequest.paymentCouponCodeInvalidError(localizedDescription:)` / `paymentCouponCodeExpiredError(localizedDescription:)`

Keys come from Contacts: `CNPostalAddress.postalCodeKey`, `.cityKey`, `.stateKey`, `.countryKey`, `.streetKey`.

## Merchant validation (session update)

Some PSP/web flows require your server to validate an Apple Pay merchant session before the sheet can finish.

```swift
func paymentAuthorizationController(
    _ controller: PKPaymentAuthorizationController,
    didRequestMerchantSessionUpdate handler: @escaping (PKPaymentRequestMerchantSessionUpdate) -> Void
) {
    Task {
        // Your server POSTs to Apple's merchant-validation URL and returns the opaque session JSON.
        let session = try await backend.validateMerchantSession()   // PKPaymentMerchantSession
        handler(PKPaymentRequestMerchantSessionUpdate(status: .success, merchantSession: session))
    }
}
```

In-app payments through a PSP SDK that manages its own merchant identity usually do **not** need this; it is mainly for `ApplePay JS`-style or direct-decryption flows.

## Recurring / deferred / automatic-reload — full setup

```swift
// RECURRING (fixed cadence, optional trial)
let regular = PKRecurringPaymentSummaryItem(label: "Monthly", amount: NSDecimalNumber(string: "9.99"))
regular.intervalUnit  = .month        // NSCalendar.Unit: .day/.month/.year/...
regular.intervalCount = 1
regular.startDate = Date()            // optional
let recurring = PKRecurringPaymentRequest(
    paymentDescription: "Pro subscription",
    regularBilling: regular,
    managementURL: URL(string: "https://example.com/manage")!)
recurring.billingAgreement    = "Renews monthly until cancelled."
recurring.tokenNotificationURL = URL(string: "https://example.com/apple-pay/token-updates")
// recurring.trialBilling = PKRecurringPaymentSummaryItem(label: "Free trial", amount: .zero)
request.recurringPaymentRequest = recurring

// DEFERRED (charge on a future date; iOS 16.4+)
let deferredItem = PKDeferredPaymentSummaryItem(
    label: "Pre-order", amount: NSDecimalNumber(string: "199.00"))
deferredItem.deferredDate = Calendar.current.date(byAdding: .day, value: 30, to: Date())!
let deferred = PKDeferredPaymentRequest(
    paymentDescription: "Pre-order charge",
    deferredBilling: deferredItem,
    managementURL: URL(string: "https://example.com/manage")!)
deferred.billingAgreement = "Charged when the item ships."
request.deferredPaymentRequest = deferred

// AUTOMATIC RELOAD (top up on low balance)
let reloadItem = PKAutomaticReloadPaymentSummaryItem(
    label: "Auto-reload", amount: NSDecimalNumber(string: "25.00"))
reloadItem.thresholdAmount = NSDecimalNumber(string: "5.00")   // reload when balance < 5.00
let reload = PKAutomaticReloadPaymentRequest(
    paymentDescription: "Wallet top-up",
    automaticReloadBilling: reloadItem,
    managementURL: URL(string: "https://example.com/manage")!)
reload.billingAgreement = "We reload $25 when your balance drops below $5."
request.automaticReloadPaymentRequest = reload
```

- Attach **at most one** of the three per request.
- All need `.threeDSecure` in `merchantCapabilities` and a PSP that supports Apple Pay merchant tokens; the token your server receives is reusable for the agreed schedule.
- `tokenNotificationURL` lets Apple notify your server when the underlying card/token changes so recurring charges don't break.

## `payment.token` anatomy

- `payment.token.paymentData: Data` — encrypted payment credential for the PSP. Opaque; forward as-is over pinned TLS.
- `payment.token.paymentMethod: PKPaymentMethod` — display-safe: `.displayName`, `.network`, `.type` (`.debit`/`.credit`/`.prepaid`/`.store`).
- `payment.token.transactionIdentifier: String` — for reconciliation/anti-replay on your server.
- `payment.billingContact` / `payment.shippingContact` — `PKContact` (the `CNPostalAddress`, name, email/phone you asked for). Treat as PII.

## Testing

- Apple Pay requires a **real device** with a provisioned card — the Simulator can render the sheet but cannot complete a live authorization end-to-end.
- Use your PSP's **sandbox** processing and Apple's Sandbox Tester accounts (test cards added to Wallet with a sandbox Apple ID).
- Assert on order/amount logic in unit tests; keep the sheet interaction in a thin, mockable coordinator behind a protocol (`swift-protocol-di-testing`).
