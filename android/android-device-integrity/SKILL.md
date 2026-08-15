---
name: android-device-integrity
description: "Android app/device integrity and anti-fraud for a fintech app — the Play Integrity API (com.google.android.play:integrity): Standard requests (StandardIntegrityManager.prepareIntegrityToken → StandardIntegrityTokenProvider.request with a requestHash → StandardIntegrityToken) vs Classic requests (IntegrityManager.requestIntegrityToken with a nonce), and when to use which; the decrypted verdict fields (appIntegrity.appRecognitionVerdict PLAY_RECOGNIZED/UNRECOGNIZED_VERSION, deviceIntegrity.deviceRecognitionVerdict MEETS_DEVICE/BASIC/STRONG/VIRTUAL_INTEGRITY, accountDetails.appLicensingVerdict, requestDetails), mandatory server-side token decryption/verification via playintegrity.googleapis.com decodeIntegrityToken (requestHash-binding + timestamp replay checks), plus defense-in-depth root / emulator / Frida-hook detection (bypassable, never a substitute for the server verdict). Use when gating money-moving endpoints on attested requests, hardening against bots/emulators/rooted-repackaged clients, or binding a device to a server-side account. SafetyNet Attestation is shut down — Play Integrity replaces it. The iOS counterpart is `device-integrity`; Android Keystore / EncryptedFile / network-security config are in `mobile-security`; sign-in in `authentication`."
---

# Android Device Integrity & Anti-Fraud

Prove a request comes from a **genuine, unmodified build of your app, installed by Google Play,
running on a real non-tampered Android device** — not an emulator, a repackaged clone, a bot farm,
or an instrumented (Frida/Xposed) copy. The hardware-backed root of trust is the **Play Integrity
API**; everything else on this page is defense-in-depth around it.

- **SafetyNet Attestation is dead.** `SafetyNetApi.attest` was deprecated and the service is fully
  shut down. Do **not** call it or copy old SafetyNet code — **Play Integrity is the replacement**.
- **Not authentication.** Integrity answers *"is this a legitimate app instance on a genuine device?"*,
  not *"who is the user?"*. Combine with real sign-in (`authentication`) and a backend risk engine.
- **The verdict is made on your server, never on the client.** A rooted device can patch any local
  check to return "clean". Trust only a token your backend decrypted and verified.

- **iOS counterpart:** `device-integrity` (App Attest / DeviceCheck).
- **Android primitives:** Keystore, `EncryptedFile`, network-security config, TLS pinning → `mobile-security`.
- **KMP boundary:** expose a `commonMain` `interface DeviceIntegrity` returning an opaque token string;
  bind an `androidMain` `actual` that calls Play Integrity. Keep raw tokens out of shared code — pass
  the base64 through to your backend. See `expect-actual`.

## Contents

- [Standard vs Classic — choosing](#choosing)
- [Prerequisites](#prereqs)
- [Standard request — client flow](#standard)
- [Classic request — client flow](#classic)
- [The integrity verdict](#verdict)
- [Server-side decryption & verification](#server)
- [Root / emulator / hook detection (defense-in-depth)](#rootbeer)
- [Fintech anti-fraud design](#antifraud)
- [Error handling](#errors)
- [Correctness checklist](#checklist)
- Reference: `references/server-verification.md`

<a id="choosing"></a>
## Standard vs Classic — choosing

Two request shapes on the same API. **Prefer Standard** for almost everything.

| | **Standard** | **Classic** |
|---|---|---|
| Tamper binding | `requestHash` (SHA-256 of your request params) | `nonce` (you supply the whole string) |
| Latency | ~hundreds of ms (warm provider) | a few seconds |
| Frequency | frequent / on-demand | **≤ 5 / minute** per app instance; use sparingly |
| Caching | protected on-device token caching by Play | not recommended |
| Replay defense | Google Play auto-prevents token reuse + your `requestHash` + timestamp | your own unique-nonce bookkeeping |
| Decryption | **Google-managed** (server-to-server) recommended | Google-managed **or** self-decrypt with your response keys |
| Use for | any action worth attesting — logins, transfers, payouts | only the highest-value actions needing an extra guarantee |

Both require Android 6.0 (API 23)+ and default to 10,000 requests/day (raise via Play Console).
Migrating off SafetyNet? Go straight to **Standard**.

<a id="prereqs"></a>
## Prerequisites

- **Play Console + Cloud project:** link your app to a Google Cloud project and enable the Play
  Integrity API response in Play Console. You need the **Cloud project number** (a long, not the
  project *ID* string).
- **Gradle dependency** (latest, verified 2025-11-20):

```kotlin
dependencies {
    implementation("com.google.android.play:integrity:1.6.0")
    // optional: await() extension for the Play Core Task API
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.11.0")
}
```

- **Distribution:** apps installed from Google Play get the strongest signals (`appLicensingVerdict`,
  `PLAY_RECOGNIZED`). Apps distributed elsewhere must call `setCloudProjectNumber(...)` and will get
  `UNEVALUATED` for Play-specific fields.
- **No device guarantee:** integrity can be temporarily unavailable (old Play Store, no network,
  GmsCore issues). Design a graceful fallback (stricter server limits / step-up), never a hard block.

<a id="standard"></a>
## Standard request — client flow

Two steps: **warm up** a token provider (network call to Google, cache it), then **request** a token
per protected action with a `requestHash` that binds it to that action's parameters.

```kotlin
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.StandardIntegrityManager
import com.google.android.play.core.integrity.StandardIntegrityManager.PrepareIntegrityTokenRequest
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityToken
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenProvider
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenRequest
import kotlinx.coroutines.tasks.await
import java.security.MessageDigest

class PlayIntegrity(context: Context, private val cloudProjectNumber: Long) {
    private val manager: StandardIntegrityManager =
        IntegrityManagerFactory.createStandard(context.applicationContext)

    @Volatile private var provider: StandardIntegrityTokenProvider? = null

    /** Warm up once (app launch / background). Refresh on INTEGRITY_TOKEN_PROVIDER_INVALID. */
    suspend fun warmUp() {
        provider = manager.prepareIntegrityToken(
            PrepareIntegrityTokenRequest.builder()
                .setCloudProjectNumber(cloudProjectNumber)
                .build()
        ).await()
    }

    /** Bind the token to the exact operation (amount, recipient, server nonce…). */
    suspend fun tokenFor(requestParams: ByteArray): String {
        val p = provider ?: run { warmUp(); provider!! }
        val requestHash = sha256Base64Url(requestParams)   // ≤ 500 bytes
        val response: StandardIntegrityToken = p.request(
            StandardIntegrityTokenRequest.builder()
                .setRequestHash(requestHash)
                .build()
        ).await()
        return response.token()   // opaque, encrypted — POST to YOUR backend
    }

    private fun sha256Base64Url(data: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(data)
        return android.util.Base64.encodeToString(
            digest, android.util.Base64.URL_SAFE or android.util.Base64.NO_WRAP or android.util.Base64.NO_PADDING
        )
    }
}
```

- `IntegrityManagerFactory.createStandard(context)` → `StandardIntegrityManager`.
- `prepareIntegrityToken(PrepareIntegrityTokenRequest)` returns a `Task<StandardIntegrityTokenProvider>`;
  **you may prepare up to 5×/minute** per app instance. Warm up early; a warm provider makes `request()`
  return in hundreds of ms.
- `provider.request(StandardIntegrityTokenRequest)` → `Task<StandardIntegrityToken>`; read the string
  with `.token()`.
- **`requestHash`** should be the SHA-256 (or any stable digest ≤ 500 bytes) of everything that defines
  the operation — amount, recipient, a **server-issued unique value** — so a captured token can't be
  replayed against a different request. Your backend recomputes it and compares (see below).
- Providers expire and are invalidated when the user clears Play Store data — handle
  `INTEGRITY_TOKEN_PROVIDER_INVALID` by re-running `warmUp()`.

<a id="classic"></a>
## Classic request — client flow

Use only for rare, highest-value actions. You pass a full `nonce`; there is no provider warm-up.

```kotlin
import com.google.android.play.core.integrity.IntegrityManager
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.IntegrityTokenRequest
import com.google.android.play.core.integrity.IntegrityTokenResponse
import kotlinx.coroutines.tasks.await

suspend fun classicToken(context: Context, nonce: String, cloudProjectNumber: Long): String {
    val manager: IntegrityManager = IntegrityManagerFactory.create(context.applicationContext)
    val response: IntegrityTokenResponse = manager.requestIntegrityToken(
        IntegrityTokenRequest.builder()
            .setNonce(nonce)                              // base64 URL-safe, no-wrap, 16–500 chars
            .setCloudProjectNumber(cloudProjectNumber)    // required if distributed outside Google Play
            .build()
    ).await()
    return response.token()
}
```

- `IntegrityManagerFactory.create(context)` → `IntegrityManager`;
  `requestIntegrityToken(IntegrityTokenRequest)` → `Task<IntegrityTokenResponse>`; read `.token()`.
- **Nonce rules:** URL-safe base64, non-wrapping, **16–500 characters**. It is sent in **cleartext** to
  Google — never put PII or a secret in it; hash instead.
- **Best-practice nonce** = digest of `(request params ‖ server-issued unique value)`. This gives you
  both tamper-binding *and* replay protection in one field. Classic requests are capped at **5/minute**
  per app instance — do not call on every foreground.

<a id="verdict"></a>
## The integrity verdict

After your server decrypts the token you get a JSON payload. The fields that matter for a fintech gate
(exact names and enum strings):

```json
{
  "requestDetails": {
    "requestPackageName": "com.yourbank.app",
    "requestHash": "aGVsbG8...",          // Standard only — MUST equal your recomputed hash
    "nonce": "hb2p...",                    // Classic only
    "timestampMillis": "1675655009345"     // token age — reject if too old (replay)
  },
  "appIntegrity": {
    "appRecognitionVerdict": "PLAY_RECOGNIZED",   // or UNRECOGNIZED_VERSION | UNEVALUATED
    "packageName": "com.yourbank.app",
    "certificateSha256Digest": ["6a6a14..."],
    "versionCode": "42"
  },
  "deviceIntegrity": {
    "deviceRecognitionVerdict": ["MEETS_DEVICE_INTEGRITY"]   // array, see below
  },
  "accountDetails": {
    "appLicensingVerdict": "LICENSED"     // or UNLICENSED | UNEVALUATED
  },
  "environmentDetails": {
    "playProtectVerdict": "NO_ISSUES",    // NO_DATA | POSSIBLE_RISK | MEDIUM_RISK | HIGH_RISK | UNEVALUATED
    "appAccessRiskVerdict": { "appsDetected": [] }
  }
}
```

- **`appIntegrity.appRecognitionVerdict`**
  - `PLAY_RECOGNIZED` — unmodified binary + signing key that Google Play recognizes. Require this for money movement.
  - `UNRECOGNIZED_VERSION` — modified, repackaged, or a build Play doesn't recognize (sideloaded/tampered).
  - `UNEVALUATED` — licensing/app info not evaluated (e.g. missing Play distribution signal).
- **`deviceIntegrity.deviceRecognitionVerdict`** — an **array** (may hold several labels, or be empty):
  - `MEETS_DEVICE_INTEGRITY` — genuine Android device with Google Play services; the baseline "trust this device" signal.
  - `MEETS_BASIC_INTEGRITY` — passes basic checks but not full device integrity (weaker; e.g. some rooted/older devices).
  - `MEETS_STRONG_INTEGRITY` — `MEETS_DEVICE_INTEGRITY` **plus** a hardware-backed boot guarantee (recent, locked-bootloader devices). Strongest.
  - `MEETS_VIRTUAL_INTEGRITY` — a **genuine Android emulator** on Google infrastructure (e.g. Play Games on PC). Treat as *not a physical device* for high-value flows; useful to distinguish sanctioned emulators from attacks.
  - **Empty array** — device fails all integrity checks (rooted/emulated/tampered). Reject or step up.
- **`accountDetails.appLicensingVerdict`** — `LICENSED` (Play account owns the app), `UNLICENSED`, or `UNEVALUATED`. Use for entitlement, not as the primary device gate.
- **`requestDetails`** — bind the token to *this* request: check `requestPackageName`, `requestHash` (Standard) / `nonce` (Classic), and reject stale `timestampMillis`.
- Optional signals: `environmentDetails.playProtectVerdict` (Play Protect state), `appAccessRiskVerdict` (screen-capturing/overlay apps active) — treat as risk inputs, not hard gates.

<a id="server"></a>
## Server-side decryption & verification (mandatory)

**Never** trust `.token()` on the client — it is opaque and encrypted precisely so the client can't
read or forge a verdict. Your **backend** turns it into a trusted JSON payload.

**Recommended — Google-managed decryption** (works for Standard and Classic):

```
POST https://playintegrity.googleapis.com/v1/{packageName}:decodeIntegrityToken
Authorization: Bearer <OAuth2 access token for the Play Integrity API service account>
Content-Type: application/json

{ "integrity_token": "<token from the app>" }
```

Google decrypts and returns `{ "tokenPayloadExternal": { requestDetails, appIntegrity, deviceIntegrity, accountDetails, environmentDetails } }`.
Then, **in this order**, on the server:

1. **Request binding:** `requestPackageName == your package`; **Standard:** `requestHash ==` the hash you recompute from the received request bytes; **Classic:** `nonce ==` the nonce you issued.
2. **Freshness / replay:** `now - timestampMillis` within a short window (e.g. a couple of minutes); for Classic also enforce single-use of the nonce. (Standard tokens are additionally single-use — Google clears the verdict on repeat decryption.)
3. **App verdict:** require `appRecognitionVerdict == PLAY_RECOGNIZED` for sensitive actions; verify `certificateSha256Digest` matches your signing cert.
4. **Device verdict:** require `MEETS_DEVICE_INTEGRITY` (or `MEETS_STRONG_INTEGRITY`) in the `deviceRecognitionVerdict` array; decide policy for `MEETS_BASIC_INTEGRITY` / `MEETS_VIRTUAL_INTEGRITY` / empty.
5. **Only then** authorize the operation. Any mismatch → reject and, if appropriate, step up.

**Classic self-decryption** is also available: decrypt with your **response encryption keys** from Play
Console (AES-GCM), then verify the ES256 signature and run the same checks. Only do this if you must
keep decryption fully in-house; Google-managed is simpler and less error-prone. Full request/response
shapes, OAuth scope, and a Kotlin server sketch are in `references/server-verification.md`.

<a id="rootbeer"></a>
## Root / emulator / hook detection (defense-in-depth)

These are **heuristics, not gates.** They are all bypassable (Magisk DenyList, Frida hiding, custom
ROMs) and run in an environment the attacker controls. Use them to add friction and feed your risk
engine — **the server-side Play Integrity verdict is the real control.** Never block a user on a local
root check alone (false positives: custom ROMs, dev devices).

```kotlin
object DeviceSignals {

    private val SU_PATHS = listOf(
        "/sbin/su", "/system/bin/su", "/system/xbin/su", "/data/local/xbin/su",
        "/data/local/bin/su", "/system/sd/xbin/su", "/system/bin/failsafe/su",
        "/data/local/su", "/su/bin/su"
    )
    private val ROOT_APPS = listOf(
        "com.topjohnwu.magisk", "eu.chainfire.supersu", "com.noshufou.android.su"
    )

    fun looksRooted(context: Context): Boolean =
        SU_PATHS.any { File(it).exists() } ||
        // Custom/test-signed ROM images ship "test-keys" instead of "release-keys".
        (Build.TAGS?.contains("test-keys") == true) ||
        // 'su' resolvable on PATH.
        runCatching { Runtime.getRuntime().exec(arrayOf("which", "su")).inputStream.bufferedReader().readLine() != null }
            .getOrDefault(false) ||
        // A normally read-only partition being writable is a strong tamper signal.
        listOf("/system", "/system/bin", "/vendor").any { File(it).canWrite() } ||
        ROOT_APPS.any { runCatching { context.packageManager.getPackageInfo(it, 0); true }.getOrDefault(false) }

    fun looksEmulated(): Boolean =
        Build.FINGERPRINT.startsWith("generic") || Build.FINGERPRINT.contains("vbox") ||
        Build.FINGERPRINT.contains("emulator") ||
        Build.MODEL.contains("Emulator") || Build.MODEL.contains("Android SDK built for") ||
        Build.MANUFACTURER.contains("Genymotion") ||
        Build.HARDWARE in setOf("goldfish", "ranchu", "vbox86") ||
        Build.PRODUCT in setOf("sdk", "sdk_google", "google_sdk", "sdk_gphone64_arm64") ||
        (Build.BRAND.startsWith("generic") && Build.DEVICE.startsWith("generic"))
}
```

- **Frida / Xposed / hooking:** you can scan `/proc/self/maps` for `frida`/`gadget`, watch default
  Frida ports, or check for the Xposed installer package — but a competent attacker hides all of these,
  and the scan itself can be hooked to lie. Treat any hit as high-signal, any miss as **no** guarantee.
- Prefer a **maintained library** (e.g. RootBeer) over hand-rolling the full matrix — but know it is
  still client-side and defeatable. It complements, never replaces, Play Integrity.
- Report these signals to your backend as *inputs* alongside the attested token; let the server decide.

<a id="antifraud"></a>
## Fintech anti-fraud design

- **Server-authoritative, always.** The only trustworthy verdict is one your backend produced by
  decrypting and verifying a token. Never branch on a client boolean.
- **Gate money-moving endpoints.** Attach a Standard token to logins, transfers, payouts, card
  provisioning, and account mutations — not to every read. Require `PLAY_RECOGNIZED` +
  `MEETS_DEVICE_INTEGRITY` (or STRONG) to authorize.
- **Bind the token to the operation.** Put amount, recipient, and a **server-issued unique value** into
  the `requestHash` (Standard) or `nonce` (Classic) so a captured token can't be replayed against a
  different transaction.
- **Layer signals, don't hard-gate on one.** Combine the integrity verdict + `authentication`
  (who the user is) + your backend risk/velocity engine + local root/emulator signals. Step up
  (extra verification) rather than instant-block, since integrity can be transiently unavailable.
- **Graceful degradation.** No Play Integrity ≠ malicious (old Play Store, offline, unsupported OEM).
  Serve those users under stricter server-side limits or a step-up, not a lockout.
- **Defense in depth.** Pair with TLS/SPKI pinning and Keystore-backed secrets (`mobile-security`),
  auth (`authentication`), and server-side rate limiting. Integrity raises the cost of automated abuse;
  it does not stop a determined attacker driving the real app on a genuine device.

<a id="errors"></a>
## Error handling

Play Integrity surfaces failures via `StandardIntegrityException` / the classic exception, carrying a
code from `StandardIntegrityErrorCode` / `IntegrityErrorCode`. Common cases:

- `INTEGRITY_TOKEN_PROVIDER_INVALID` (-19, Standard) — provider expired or Play Store data cleared.
  **Re-run `prepareIntegrityToken()`** and retry.
- `API_NOT_AVAILABLE` / `PLAY_SERVICES_NOT_FOUND` / `PLAY_STORE_NOT_FOUND` — Play Services/Store missing
  or too old. Fall back to stricter server-side controls; optionally prompt to update.
- `NETWORK_ERROR` — no/blocked connectivity. **Retry with exponential backoff.**
- `TOO_MANY_REQUESTS` — you exceeded the rate limit (prepare/classic 5/min; daily quota). Back off; warm
  up less aggressively.
- `CLOUD_PROJECT_NUMBER_IS_INVALID` — wrong/missing project number in the request builder.
- `APP_NOT_INSTALLED` / `APP_UID_MISMATCH` / `CLIENT_TRANSIENT_ERROR` — environment problems; retry once, then degrade.
- Newer Play Services can show a guided remediation dialog via `showDialog(...)`
  (`GET_INTEGRITY` / `GET_STRONG_INTEGRITY`) to help the user fix an integrity problem before retrying.

Wrap calls so a transient `NETWORK_ERROR`/`TOO_MANY_REQUESTS` doesn't strand the user, and so
`INTEGRITY_TOKEN_PROVIDER_INVALID` transparently re-warms the provider and retries the original request once.

<a id="checklist"></a>
## Correctness checklist

- [ ] **No SafetyNet.** `SafetyNetApi.attest` is shut down — not used anywhere; Play Integrity replaces it.
- [ ] `com.google.android.play:integrity` dependency present; app linked to a Cloud project; **Cloud project number** (not ID) used.
- [ ] Standard flow: `createStandard` → `prepareIntegrityToken` (warmed up, ≤5/min) → `provider.request(... setRequestHash ...)` → `.token()`.
- [ ] `requestHash` (Standard) / `nonce` (Classic) is a digest of the operation **plus a server-issued unique value**; nonce is URL-safe base64, 16–500 chars, no secrets in cleartext.
- [ ] Token decrypted **on the server** (Google-managed `decodeIntegrityToken`, or Classic self-decrypt) — never read on the client.
- [ ] Server checks, in order: `requestPackageName`, `requestHash`/`nonce` match, `timestampMillis` fresh (replay), `appRecognitionVerdict == PLAY_RECOGNIZED`, `certificateSha256Digest` matches, `deviceRecognitionVerdict` contains `MEETS_DEVICE_INTEGRITY`/`MEETS_STRONG_INTEGRITY`.
- [ ] Money-moving endpoints require an attested request; token bound to amount/recipient/request-id.
- [ ] `MEETS_BASIC_INTEGRITY` / `MEETS_VIRTUAL_INTEGRITY` / empty-array policies decided explicitly.
- [ ] Root/emulator/hook checks are **inputs to the risk engine**, not the gate; users not hard-blocked on a local check.
- [ ] Verdicts layered with `authentication`, pinning/Keystore (`mobile-security`), and server rate limiting.
- [ ] `INTEGRITY_TOKEN_PROVIDER_INVALID` re-warms the provider; `NETWORK_ERROR`/`TOO_MANY_REQUESTS` retried with backoff; unsupported Play Services degrade gracefully, not blocked.
