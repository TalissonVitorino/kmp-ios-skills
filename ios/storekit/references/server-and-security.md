# Server-side trust: App Store Server API & Notifications V2

The device is convenient but spoofable. For anything that unlocks paid value, the
server validates transactions and reacts to state changes out of band. Two Apple
services do this; both use **JWS (JSON Web Signature)** payloads you verify against
Apple's certificate chain.

## Why not trust the client alone

- On-device `VerificationResult.verified` proves Apple signed the JWS — it does not
  prove the transaction is still valid (refund, chargeback, family removal, or a
  subscription that lapsed after the app cached a "subscribed" flag).
- A jailbroken device or MITM StoreKit shim can feed your app forged state. The
  server, talking to Apple directly, cannot be lied to the same way.

## App Store Server API (pull)

REST API your backend calls (JWT-authenticated with a key from App Store Connect >
Users and Access > Integrations > In-App Purchase) to query Apple:

- `GET /inApps/v1/subscriptions/{transactionId}` — all subscription statuses for the
  customer (mirrors on-device `Product.SubscriptionInfo.Status`).
- `GET /inApps/v2/history/{transactionId}` — transaction history.
- `GET /inApps/v1/transactions/{transactionId}` — a single signed transaction.
- `GET /inApps/v1/lookup/{orderId}` — look up a customer's transactions from an order ID (Production only).
- Send-test-notification and refund-lookup endpoints for ops.

Responses contain `signedTransactionInfo` / `signedRenewalInfo` (JWS). Decode and
verify with **Apple's App Store Server Library** (Swift/Java/Python/Node) rather than
hand-rolling JWT verification.

## App Store Server Notifications V2 (push)

Apple POSTs to your **Production** and **Sandbox** notification URLs (set in App
Store Connect) whenever purchase/subscription/refund state changes. Near-real-time;
the authoritative trigger for granting/revoking access.

Payload shape:

```
{ "signedPayload": "<JWS>" }
```

Base64URL-decode the JWS payload to `responseBodyV2DecodedPayload`:

- `notificationType` — e.g. `SUBSCRIBED`, `DID_RENEW`, `DID_FAIL_TO_RENEW`,
  `EXPIRED`, `DID_CHANGE_RENEWAL_STATUS`, `DID_CHANGE_RENEWAL_PREF`, `GRACE_PERIOD_EXPIRED`,
  `OFFER_REDEEMED`, `PRICE_INCREASE`, `REFUND`, `REFUND_DECLINED`, `REVOKE`,
  `CONSUMPTION_REQUEST`, `RENEWAL_EXTENDED`, `ONE_TIME_CHARGE`.
- `subtype` — qualifier, e.g. `INITIAL_BUY`, `RESUBSCRIBE`, `UPGRADE`, `DOWNGRADE`,
  `AUTO_RENEW_ENABLED`/`AUTO_RENEW_DISABLED`, `VOLUNTARY`, `BILLING_RETRY`,
  `GRACE_PERIOD`, `BILLING_RECOVERY`.
- `data` — carries `signedTransactionInfo` (JWSTransaction) and, for subscriptions,
  `signedRenewalInfo` (JWSRenewalInfo), plus `environment` (`Sandbox`/`Production`),
  `appAppleId`, `bundleId`.

Verification steps (server):

1. Extract the x5c certificate chain from the JWS header.
2. Validate the chain up to Apple's root CA (pin Apple's root).
3. Verify the JWS signature with the leaf public key.
4. Only then trust `notificationType` / transaction data. Use the App Store Server
   Library's verifier — do not skip chain validation.

Operational notes:

- **Respond `200` fast**; do heavy work async. Apple retries failed deliveries on a
  backoff for up to several days — make handlers idempotent (dedupe on
  transaction/notification ID).
- Reconcile with a periodic App Store Server API poll to catch any missed
  notification — push + pull, not push alone.
- Match `appAccountToken` (the UUID you sent in `.appAccountToken`) back to your user.
- Keep Sandbox and Production URLs distinct; test-notification endpoint verifies wiring.

## AppTransaction (app-level receipt)

`try await AppTransaction.shared` returns a `VerificationResult<AppTransaction>` with
`bundleID`, `appVersion`, `originalAppVersion`, `originalPurchaseDate` — used for
paid-app / "free for existing users" gating. Verify like any other result. Refresh
with `AppTransaction.refresh()`.

## Fintech guardrails

- Grant entitlement from server state; the client entitlement only pre-renders UI.
- Never store the signing key (`.p8`) or offer-signing key in the app binary — keep
  it server-side (see `swift-security` for why embedded secrets are extractable).
- Log purchase events without PII; `appAccountToken` is a random UUID, not a user ID.
