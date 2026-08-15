# Server-side token decryption & verification

Turning the client's opaque `.token()` into a trusted verdict. Everything here runs on **your
backend**. Two paths: **Google-managed decryption** (recommended, Standard + Classic) and **Classic
self-decryption** (in-house AES-GCM + ES256).

## Path A — Google-managed decryption (recommended)

Google decrypts server-to-server, so you never hold Play's encryption keys.

### Setup

1. In the Google Cloud project linked to your app, enable the **Play Integrity API**.
2. Create a **service account** (or reuse one), grant it access, and obtain OAuth2 credentials.
3. On your backend, mint an access token for scope
   `https://www.googleapis.com/auth/playintegrity` (Google auth libraries handle this from the
   service-account JSON).

### Request

```
POST https://playintegrity.googleapis.com/v1/{packageName}:decodeIntegrityToken
Authorization: Bearer <oauth2-access-token>
Content-Type: application/json

{ "integrity_token": "<token the app sent you>" }
```

`{packageName}` is your app's application id (e.g. `com.yourbank.app`).

### Response

```json
{
  "tokenPayloadExternal": {
    "requestDetails": {
      "requestPackageName": "com.yourbank.app",
      "requestHash": "aGVsbG8...",
      "timestampMillis": "1675655009345"
    },
    "appIntegrity": {
      "appRecognitionVerdict": "PLAY_RECOGNIZED",
      "packageName": "com.yourbank.app",
      "certificateSha256Digest": ["6a6a14..."],
      "versionCode": "42"
    },
    "deviceIntegrity": { "deviceRecognitionVerdict": ["MEETS_DEVICE_INTEGRITY"] },
    "accountDetails": { "appLicensingVerdict": "LICENSED" },
    "environmentDetails": {
      "playProtectVerdict": "NO_ISSUES",
      "appAccessRiskVerdict": { "appsDetected": [] }
    }
  }
}
```

(Classic tokens carry `nonce` in `requestDetails` instead of `requestHash`.)

## Path B — Classic self-decryption (in-house)

Only for Classic requests, when you must keep decryption fully on your infrastructure. In Play Console
you choose to **manage the response encryption keys yourself**; you receive:

- an **AES key** (base64) for AES-256-GCM decryption of the token, and
- an **EC public key** (base64) for verifying the ES256 (ECDSA P-256 + SHA-256) signature.

The token is a **compact JWE** (`Base64Url(header).encryptedKey.iv.ciphertext.tag`) wrapping a compact
**JWS**. Steps:

1. Split the JWE on `.`; base64url-decode the parts.
2. AES-256-GCM **decrypt** the ciphertext (using the IV and auth tag) with your AES key → a JWS string.
3. Split the JWS; **verify** the ES256 signature over `header.payload` with your EC public key.
4. Base64url-decode the JWS payload → the same JSON `tokenPayloadExternal` shape as Path A.

Use a vetted JOSE library (Nimbus JOSE+JWT, `jose4j`, google-auth) — do **not** hand-roll JWE/JWS.

## Verification (both paths) — in order

```kotlin
fun verify(payload: TokenPayload, expected: ExpectedRequest, now: Long): Decision {
    val rd = payload.requestDetails

    // 1. Request binding.
    if (rd.requestPackageName != expected.packageName) return Decision.REJECT
    // Standard: recompute the hash from the bytes you received and compare.
    if (rd.requestHash != expected.recomputedRequestHash) return Decision.REJECT
    // Classic: if (rd.nonce != expected.issuedNonce || nonceAlreadyUsed(rd.nonce)) return REJECT

    // 2. Freshness / replay.
    if (now - rd.timestampMillis.toLong() > ALLOWED_WINDOW_MS) return Decision.REJECT   // e.g. 2 min

    // 3. App verdict.
    if (payload.appIntegrity.appRecognitionVerdict != "PLAY_RECOGNIZED") return Decision.STEP_UP
    if (expected.signingCertSha256 !in payload.appIntegrity.certificateSha256Digest) return Decision.REJECT

    // 4. Device verdict (array).
    val device = payload.deviceIntegrity.deviceRecognitionVerdict
    val trusted = "MEETS_DEVICE_INTEGRITY" in device || "MEETS_STRONG_INTEGRITY" in device
    if (!trusted) return Decision.STEP_UP    // empty / BASIC / VIRTUAL → your policy

    // 5. Authorize.
    return Decision.ALLOW
}
```

Notes:

- **`ALLOWED_WINDOW_MS`** should be short (minutes). Combined with single-use `requestHash`/nonce this
  is your replay defense.
- **Standard tokens are single-use** — Google clears the verdict if the same token is decoded twice; a
  repeated decode returning empty verdicts means a replayed token.
- **Classic replay** is on you: persist issued nonces and reject reuse.
- Decide policy explicitly for `MEETS_BASIC_INTEGRITY` (weaker device), `MEETS_VIRTUAL_INTEGRITY`
  (sanctioned emulator), and empty array (failed all checks).
- `appLicensingVerdict`, `playProtectVerdict`, and `appAccessRiskVerdict` are extra risk inputs — feed
  your risk engine, don't hard-gate on them.
- Rate limits: default **10,000 requests/day** for `decodeIntegrityToken` (raise via Play Console).
  Cache nothing sensitive; the verdict is per-request.
