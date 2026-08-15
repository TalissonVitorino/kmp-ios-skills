---
name: device-integrity
description: "iOS device-legitimacy and anti-fraud for a fintech app — DeviceCheck (DCDevice.generateToken, the two per-device bits, query_two_bits / update_two_bits server API) and App Attest (DCAppAttestService isSupported / generateKey / attestKey / generateAssertion, Secure-Enclave-backed keys), the server-side attestation + assertion verification flow (nonce, App-ID/RP-ID hash, cert chain, monotonic signCount), receipt / risk-metric refresh, and protecting sensitive API endpoints with attested, assertion-signed requests. Use when hardening endpoints against bots / tampered or cloned clients, binding a device to a server-side account, throttling by device, or detecting fraud and replay. iOS-side; the Keychain / Secure Enclave / TLS-pinning primitives are in `swift-security`, biometric and passkey sign-in in `authentication`, the Android counterpart (Play Integrity + root detection) is `android-device-integrity`, and the KMP boundary is `expect-actual`."
---

# Device Integrity & Anti-Fraud (iOS)

Prove a request comes from a **genuine, unmodified build of your app on a real Apple
device** — not a script, emulator, repackaged clone, or instrumented copy. Two Apple
frameworks, different jobs:

- **App Attest** (`DCAppAttestService`) — cryptographic proof of app + device authenticity per
  request. A hardware key in the Secure Enclave signs your payloads; your server verifies. Use to
  gate money-moving and abuse-prone endpoints.
- **DeviceCheck** (`DCDevice`) — two persistent bits per device per developer, surviving reinstalls
  and factory resets. Use for coarse device-level flags (trial abused, promo redeemed, banned).

Neither is authentication or authorization — they answer *"is this a legitimate client instance?"*,
not *"who is the user?"*. Combine with real auth (`authentication`) and never treat client-side
results as trusted; **all verdicts are made on your server**.

- **Companion primitives:** Keychain, Secure Enclave, CryptoKit, and TLS/SPKI pinning live in `swift-security`.
- **Sign-in (Apple/passkeys/OAuth):** `authentication`. **Android counterpart:** Play Integrity + root/emulator detection in `android-device-integrity`.
- **KMP boundary:** expose a `commonMain` `interface DeviceIntegrity` and bind an `iosMain` `actual`; see `expect-actual`. Keep raw attestation objects out of shared code — pass opaque base64 through to your backend.

## Contents

- [Choosing App Attest vs DeviceCheck](#choosing)
- [Prerequisites](#prereqs)
- [App Attest — client flow](#appattest-client)
- [App Attest — server verification](#appattest-server)
- [Assertions — protecting an endpoint](#assertions)
- [Receipts & the fraud risk metric](#receipts)
- [DeviceCheck — two-bit device state](#devicecheck)
- [Anti-fraud design](#antifraud)
- [Error handling](#errors)
- [Correctness checklist](#checklist)
- References: `references/server-verification.md`, `references/devicecheck-server.md`

<a id="choosing"></a>
## Choosing App Attest vs DeviceCheck

| | **App Attest** | **DeviceCheck** |
|---|---|---|
| Question answered | Is this a genuine, unmodified instance of my app? | Have I seen this device before / flagged it? |
| Proof strength | Per-request cryptographic signature (Secure Enclave key) | Two opaque bits, no per-request proof |
| State | Stateless proof; server stores the attested public key | 2 bits + `last_update_time`, persisted by Apple |
| Survives reinstall / reset | Key is per-install (new key after reinstall) | **Yes** — bits persist across reinstall & factory reset |
| Server talks to Apple | Only for optional risk-metric receipts | Every query/update (`api.devicecheck.apple.com`) |
| Fintech use | Attest device on onboarding; assert every sensitive call | Enforce one-trial / one-bonus per device; soft ban |

Use **both**: App Attest to trust the request, DeviceCheck to remember the device.

<a id="prereqs"></a>
## Prerequisites

- **Capability:** add the **App Attest** / **DeviceCheck** entitlement (`com.apple.developer.devicecheck.appattest-environment`) in Xcode. App Attest environment is `development` in debug/TestFlight-from-Xcode and `production` for App Store / TestFlight builds — the two use **different root CAs and AAGUIDs**, so your server must know which to expect.
- **Hardware only:** both require a real device with a Secure Enclave. `isSupported` is `false` on the Simulator and unavailable HW — always branch to a graceful fallback (e.g. tighter server-side rate limits) rather than blocking the user.
- **Keys for the server API:** DeviceCheck's server endpoints need a **DeviceCheck private key** (`.p8`) + Key ID + Team ID from the Apple Developer portal, used to mint an ES256 JWT. App Attest verification needs no Apple key on the happy path (you verify certificates against Apple's App Attest root); the optional risk-metric endpoint reuses the same DeviceCheck key.
- Frameworks: `import DeviceCheck`. iOS 11+ for `DCDevice`; iOS 14+ for `DCAppAttestService`. `async` variants iOS 15+.

<a id="appattest-client"></a>
## App Attest — client flow

Two phases: **attest once** to register a device key with your server, then **assert** on every
sensitive request. The private key lives in the Secure Enclave and is never exported — you only ever
hold a `keyId` string.

```swift
import DeviceCheck

let service = DCAppAttestService.shared

func attestDevice() async throws {
    guard service.isSupported else {
        // Simulator / unsupported HW — fall back, don't hard-block.
        throw IntegrityError.unsupported
    }

    // 1. Generate a Secure Enclave key. Persist keyId (Keychain) — it maps this install to the server.
    let keyId = try await service.generateKey()

    // 2. Ask YOUR server for a fresh, single-use challenge (bind it to a user/session server-side).
    let challenge: Data = try await api.fetchAttestChallenge()

    // 3. Hash the challenge as clientDataHash. Apple re-hashes it into the attestation nonce.
    let clientDataHash = Data(SHA256.hash(data: challenge))

    // 4. Produce the attestation object (CBOR). This call hits Apple's attestation server once.
    let attestation = try await service.attestKey(keyId, clientDataHash: clientDataHash)

    // 5. Send { keyId, attestation (base64), challenge } to your server to verify & store the pubkey.
    try await api.registerAttestation(keyId: keyId, attestationObject: attestation)
    keychain.set(Data(keyId.utf8), account: "appattest.keyId")   // see swift-security
}
```

- `generateKey()` returns a base64 key identifier; the key is bound to your app's App ID and this device. **Persist `keyId`** (Keychain) — losing it means re-attesting.
- `attestKey` may **only be called once per key** for a successful attestation. If you need a fresh attestation (e.g. server lost the record), `generateKey()` a new key.
- `clientDataHash` must be `SHA256` of a **server-issued, single-use, time-bounded challenge** — this is what stops replay. Never let the client invent the challenge.
- Completion-handler forms exist too (`generateKey(completionHandler:)`, `attestKey(_:clientDataHash:completionHandler:)`); their replies run off the main thread — hop to `@MainActor` for UI.

<a id="appattest-server"></a>
## App Attest — server verification

The attestation object is **CBOR**: `{ fmt: "apple-appattest", attStmt: { x5c, receipt }, authData }`. Verify it
**entirely on your server** (Apple provides no "verify this" endpoint for attestations). Steps, in order:

1. **Decode** CBOR; extract the `x5c` certificate chain, the `receipt`, and `authData`.
2. **Chain:** verify `x5c` (credCert → intermediate) against **Apple's App Attest Root CA**. Reject on any chain failure.
3. **Nonce:** `nonce = SHA256( authData || clientDataHash )`. Read the credCert extension OID `1.2.840.113635.100.8.2`, decode the octet string, and require it **equals** `nonce`.
4. **Key ID:** `SHA256(credCert public key)` must equal the base64-decoded `keyId` the client sent.
5. **App ID (RP ID) hash:** first 32 bytes of `authData` must equal `SHA256("<TeamID>.<BundleID>")`.
6. **Counter:** `authData` sign counter must be `0`.
7. **AAGUID:** must be `appattestdevelop` (development) or `appattest` + seven `0x00` bytes (production) — and must match the environment you expect for this build.
8. **Credential ID:** the credential ID in `authData` must equal `keyId`.

On success, **store the credCert public key** against the user/device and mark the challenge consumed.
Reject and force re-attestation on any mismatch. Full byte-offset breakdown and a Swift/`swift-crypto`
sketch are in `references/server-verification.md`.

<a id="assertions"></a>
## Assertions — protecting an endpoint

Once a key is attested, every sensitive request carries an **assertion**: a Secure Enclave signature
over `SHA256(requestPayload || serverChallenge)`. This proves the request came from the same attested
install and wasn't tampered with in flight.

```swift
// Client: sign the exact bytes you're about to POST, plus a fresh server challenge.
func signedRequest(_ body: Data, challenge: Data) async throws -> Data {
    let keyId = String(decoding: keychain.get(account: "appattest.keyId")!, as: UTF8.self)
    let clientData = body + challenge
    let clientDataHash = Data(SHA256.hash(data: clientData))
    return try await service.generateAssertion(keyId, clientDataHash: clientDataHash)  // CBOR
}
```

**Server verification of an assertion** (CBOR `{ signature, authenticatorData }`):

1. `clientDataHash = SHA256(requestBody || challenge)` — recompute from the bytes you received.
2. `nonce = SHA256( authenticatorData || clientDataHash )`.
3. Verify `signature` over `nonce` with the **stored public key** from attestation (ECDSA P-256).
4. **RP ID hash:** first 32 bytes of `authenticatorData` == `SHA256(App ID)`.
5. **Counter:** the sign counter must be **strictly greater** than the last value you stored for this key; persist the new value. A non-increasing counter means replay or a cloned key — reject.

- Put attestation behind onboarding/first-launch; attach an assertion to **write / money-moving / account-mutation** endpoints, not every read.
- The `challenge` must be server-issued, single-use, and short-lived. Bind requests tightly: include amount, recipient, and a nonce in `body` so the signature covers the actual operation, not a generic token.
- Handle `DCError.invalidKey` on the client (key evicted after OS restore / migration) by transparently re-running the attest flow, then retrying.

<a id="receipts"></a>
## Receipts & the fraud risk metric

The attestation `receipt` (and refreshed receipts) can be exchanged with Apple for a **risk metric**
— how many times Apple has issued attestations for this device recently, a signal for cloning/farm
abuse.

- Server POSTs the base64 receipt to `https://data.appattest.apple.com/v1/attestationData` (production) or `https://data-development.appattest.apple.com/v1/attestationData` (development), authenticated with your DeviceCheck ES256 JWT.
- Response is a **new receipt** carrying an updated `Risk Metric` field and a fresh `Not Before` date.
- **Receipts expire** — refresh on a schedule (Apple guidance: roughly weekly, and before expiry) to keep a live risk signal; store the newest receipt per device.
- Treat a high/anomalous risk metric as *one* fraud input among many — step up (extra verification), don't auto-ban on it alone.

<a id="devicecheck"></a>
## DeviceCheck — two-bit device state

Two bits per device per developer, persisted by Apple across reinstall and factory reset. Classic use:
`bit0 = "has used free trial"`, `bit1 = "flagged/abusive"`.

```swift
import DeviceCheck

func deviceToken() async throws -> Data {
    let device = DCDevice.current
    guard device.isSupported else { throw IntegrityError.unsupported }  // Simulator returns false
    return try await device.generateToken()   // ephemeral, base64 when sent to your server
}
```

- `generateToken()` returns a short-lived, opaque token identifying *this* device to *your* developer account. It is **not** a stable device ID you can store — it's meaningless except through Apple's server API, which is the point (privacy-preserving).
- Your **server** exchanges the token (never the app) at Apple's endpoints with an ES256 JWT signed by your DeviceCheck key:
  - `POST https://api.devicecheck.apple.com/v1/query_two_bits` — read the two bits + `last_update_time`.
  - `POST https://api.devicecheck.apple.com/v1/update_two_bits` — set the bits.
  - `POST https://api.devicecheck.apple.com/v1/validate_device_token` — confirm a token is authentic.
  - Development/sandbox host: `https://api.development.devicecheck.apple.com/...`. Use the host matching the **token's** environment or you'll get `Bit State Not Found`.
- JWT + request/response shapes and error bodies are in `references/devicecheck-server.md`.
- **Privacy:** two bits carry no PII, but document their purpose in your privacy policy; don't repurpose them as a covert tracking ID.

<a id="antifraud"></a>
## Anti-fraud design

- **Server-authoritative, always.** The client can lie about everything. A verdict is only ever the outcome of *your server* verifying a signature or querying Apple. Never branch on a client boolean like `isSupported == true` as if it were trust.
- **Fresh challenge per operation.** Every attestation and assertion binds to a single-use, expiring, server-issued challenge. This is the entire replay defense — reuse breaks it.
- **Bind the signature to the operation.** Include the concrete request (amount, recipient, request-id) in the assertion's signed bytes, so a captured signature can't be replayed against a different transaction.
- **Layer signals; don't gate hard on one.** Combine App Attest verdict + DeviceCheck bits + risk metric + your own behavioral/velocity checks. Step up or review rather than instant-block, because false positives (OS restores, device migration, unsupported HW) are real.
- **Graceful degradation for unsupported devices.** No Secure Enclave ≠ malicious. Serve those users under stricter server-side limits instead of locking them out.
- **Defense in depth, not a silver bullet.** App Attest raises the cost of automated abuse; it does not stop a determined attacker with a genuine device driving the real app. Pair with TLS/SPKI pinning (`swift-security`), auth (`authentication`), and server-side rate limiting.
- Jailbreak/tamper heuristics are supplementary and bypassable — see MASVS-RESILIENCE framing in `swift-security`. Prefer attestation's hardware root of trust over on-device jailbreak checks.

<a id="errors"></a>
## Error handling

`DCError` (`DCError.Code`), domain `DCErrorDomain`:

- `.featureUnsupported` — no Secure Enclave / Simulator (mirror with `isSupported`). Fall back, don't block.
- `.invalidInput` — bad `keyId` or malformed `clientDataHash` (must be 32-byte SHA-256).
- `.invalidKey` — key unusable (evicted after OS restore/migration, or wrong key). Re-`generateKey()` + re-attest.
- `.serverUnavailable` — Apple attestation server unreachable/transient. **Retry with backoff**; do not discard the key.
- `.unknownSystemFailure` — generic; retry once, then surface.

Wrap calls so a transient `.serverUnavailable` during `attestKey` doesn't strand the user, and so `.invalidKey` during an assertion transparently re-attests then retries the original request once.

<a id="checklist"></a>
## Correctness checklist

- [ ] App Attest / DeviceCheck capability added; server knows whether to expect the **development** or **production** environment (root CA + AAGUID differ).
- [ ] `isSupported` checked before every App Attest / DeviceCheck call; unsupported devices degrade gracefully, not blocked.
- [ ] `clientDataHash` is `SHA256` of a **server-issued, single-use, expiring** challenge — never client-chosen, never reused.
- [ ] Attestation verified **entirely on the server**: cert chain to Apple root, nonce (OID `1.2.840.113635.100.8.2`), keyId == SHA256(pubkey), App-ID hash, counter == 0, AAGUID matches environment, credential-id == keyId.
- [ ] Attested **public key stored** server-side per device/user; challenge marked consumed after use.
- [ ] `keyId` persisted in Keychain; `attestKey` called at most once per key; `.invalidKey` triggers re-attest.
- [ ] Assertions gate sensitive/mutating endpoints; signed bytes include the actual operation (amount/recipient/request-id) + fresh challenge.
- [ ] Assertion sign **counter is strictly monotonic** per key and persisted; non-increasing → reject as replay/clone.
- [ ] DeviceCheck token exchanged only from the **server** with an ES256 JWT; host matches the token's environment; two-bit purpose documented for privacy.
- [ ] Risk-metric receipts refreshed on schedule and before expiry; used as one signal, not an auto-ban.
- [ ] Verdicts are server-authoritative; results layered with auth, pinning, and rate limiting — never a client-side boolean.
- [ ] `DCError.serverUnavailable` retried with backoff; `.featureUnsupported` handled as fallback path.
