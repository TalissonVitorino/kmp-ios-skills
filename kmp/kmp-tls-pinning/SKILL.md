---
name: kmp-tls-pinning
description: "TLS certificate / SPKI public-key pinning for a SHARED Ktor client across Android + iOS — one pin set, two engine mechanisms via expect/actual. Android (Ktor OkHttp engine): okhttp3 CertificatePinner.Builder().add(host, \"sha256/<spki>\") applied in engine { config { certificatePinner(...) } } or a preconfigured OkHttpClient, plus the Network Security Config XML alternative. iOS (Ktor Darwin engine): the built-in io.ktor.client.engine.darwin.certificates.CertificatePinner or a custom handleChallenge ChallengeHandler that evaluates SecTrust and matches the SPKI SHA-256. Covers pin hygiene (pin the SPKI not the leaf, >=2 pins incl. backup, rotation, fail-closed), openssl pin extraction, and why MockEngine cannot test pinning. Use when pinning a KMP/Ktor client, adding backup pins, planning rotation, or configuring per-engine trust. Cross-refs kmp-networking, swift-security, mobile-security, expect-actual."
---

# KMP TLS / SPKI pinning for a shared Ktor client

Pin the server's **public key (SPKI SHA-256)** for a Ktor client shared in
`commonMain`. Grounded in Ktor 3.6.x (`ktor-client-okhttp`, `ktor-client-darwin`),
OkHttp's `CertificatePinner`, and Apple's Security framework.

- **The client is shared, the trust mechanism is not.** A KMP Ktor client uses a
  different engine per target — **OkHttp** on Android, **Darwin** (`NSURLSession`)
  on iOS — so pinning is applied per engine. Same pin set, two mechanisms, joined
  with `expect`/`actual` (see `expect-actual`).
- Builds on `kmp-networking` (the shared `HttpClient` factory). iOS SecTrust/SPKI
  details live in `swift-security`; the Android declarative alternative in
  `mobile-security`.

## Contents

- [Why per-platform](#why)
- [The pin set (commonMain)](#pinset)
- [expect/actual boundary](#boundary)
- [Android — OkHttp engine](#android)
- [iOS — Darwin engine](#ios)
- [Pin hygiene & rotation](#hygiene)
- [Testing pinning](#testing)
- [Checklist](#checklist)
- References: `references/pin-extraction.md` (openssl, custom Darwin handler, Android NSC XML)

<a id="why"></a>
## Why per-platform

`HttpClient(engine) { engine { … } }` exposes an **engine-specific** config type
(`OkHttpConfig`, `DarwinClientEngineConfig`). From a `HttpClientConfig<*>` you can
only reach the *base* `HttpClientEngineConfig` — not `config { certificatePinner() }`
or `handleChallenge { }`. So an `HttpClientConfig<*>.installPinning()` extension
**cannot** reach the pinning APIs; the boundary must sit where the concrete engine
type is known. Use an `expect`/`actual` factory instead.

<a id="pinset"></a>
## The pin set (commonMain)

One host → its pins, expressed once in shared code. A pin is `sha256/` + base64 of
`SHA-256(DER SubjectPublicKeyInfo)`; both engines accept exactly this string form.

```kotlin
// commonMain/kotlin/network/pinning/PinSet.kt
data class PinSet(
    /** host pattern (e.g. "api.example.com" or "*.example.com") -> pins ("sha256/…") */
    val pins: Map<String, List<String>>,
) {
    init {
        require(pins.values.all { it.size >= 2 }) { "Keep >=2 pins per host (current + backup)." }
        require(pins.values.flatten().all { it.startsWith("sha256/") || it.startsWith("sha1/") }) {
            "Pins must start with 'sha256/' or 'sha1/'."
        }
    }
}

val ProductionPins = PinSet(
    mapOf(
        "api.example.com" to listOf(
            "sha256/47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=", // current leaf/intermediate SPKI
            "sha256/633lt352PKRXbOwf4xSEa1M517scpD3l+2VknLXvGWk=", // OFFLINE backup key SPKI
        ),
    ),
)
```

See `references/pin-extraction.md` for the `openssl` one-liner that produces these.

<a id="boundary"></a>
## expect/actual boundary

Return a fully-configured client; the shared install block (`ContentNegotiation`,
`Auth`, `HttpTimeout` from `kmp-networking`) is passed through and composes with the
per-engine pinning.

```kotlin
// commonMain/kotlin/network/pinning/PinnedHttpClient.kt
import io.ktor.client.*

expect fun createPinnedHttpClient(
    pins: PinSet,
    configure: HttpClientConfig<*>.() -> Unit = {},   // shared plugins from kmp-networking
): HttpClient
```

<a id="android"></a>
## Android — OkHttp engine

OkHttp has first-class pinning: `okhttp3.CertificatePinner`. Feed it into the Ktor
OkHttp engine via `engine { config { … } }` (the `config` receiver **is** an
`OkHttpClient.Builder`).

```kotlin
// androidMain/kotlin/network/pinning/PinnedHttpClient.android.kt
import io.ktor.client.*
import io.ktor.client.engine.okhttp.*
import okhttp3.CertificatePinner

private fun PinSet.toOkHttpPinner(): CertificatePinner =
    CertificatePinner.Builder()
        .apply { pins.forEach { (host, hashes) -> add(host, *hashes.toTypedArray()) } }
        .build()

actual fun createPinnedHttpClient(
    pins: PinSet,
    configure: HttpClientConfig<*>.() -> Unit,
): HttpClient = HttpClient(OkHttp) {
    engine {
        config { certificatePinner(pins.toOkHttpPinner()) }   // OkHttpClient.Builder.certificatePinner(...)
    }
    configure()
}
```

- `CertificatePinner.Builder.add(pattern: String, vararg pins: String)` — pattern may
  be an exact host, `*.example.com` (one label) or `**.example.com` (any depth).
- On mismatch OkHttp throws `SSLPeerUnverifiedException` (surfaces through Ktor as the
  request's cause) — it **fails closed** by default. Good.
- Alternative: build the `OkHttpClient` yourself and hand Ktor a `preconfigured =
  okHttpClient` (with `.certificatePinner(pinner)` already set) when you share one
  OkHttp instance with non-Ktor code.
- **Declarative alternative:** Android Network Security Config XML (`<pin-set>`) pins
  the same SPKI hashes with no engine code — see `references/pin-extraction.md` and
  `mobile-security`. Pick one enforcement point as the source of truth.

<a id="ios"></a>
## iOS — Darwin engine

Ktor's Darwin engine ships an OkHttp-shaped pinner:
`io.ktor.client.engine.darwin.certificates.CertificatePinner`. It implements
`ChallengeHandler` and is installed with `handleChallenge`.

```kotlin
// iosMain/kotlin/network/pinning/PinnedHttpClient.ios.kt
import io.ktor.client.*
import io.ktor.client.engine.darwin.*
import io.ktor.client.engine.darwin.certificates.CertificatePinner

private fun PinSet.toDarwinPinner(): CertificatePinner =
    CertificatePinner.Builder()
        .apply { pins.forEach { (host, hashes) -> add(host, *hashes.toTypedArray()) } }
        .validateTrust(true)     // evaluate the system chain BEFORE checking pins (keep true)
        .build()

actual fun createPinnedHttpClient(
    pins: PinSet,
    configure: HttpClientConfig<*>.() -> Unit,
): HttpClient = HttpClient(Darwin) {
    engine {
        handleChallenge(pins.toDarwinPinner())   // DarwinClientEngineConfig.handleChallenge(ChallengeHandler)
    }
    configure()
}
```

- Same pin strings as Android — the builder validates the `sha256/` / `sha1/` prefix
  and rejects anything else.
- `validateTrust = true` (the default) makes the pinner run standard `SecTrust`
  evaluation first, then match the SPKI — never set it `false` in production.
- Under the hood it extracts each cert's key with `SecCertificateCopyKey`, prepends the
  ASN.1 SPKI header, and `CC_SHA256`s it — the same computation as `swift-security`.
- **Need custom logic** (soft-fail telemetry, pinning a specific chain position,
  logging)? Write a raw `ChallengeHandler`:
  `(NSURLSession, NSURLSessionTask, NSURLAuthenticationChallenge, (NSURLSessionAuthChallengeDisposition, NSURLCredential?) -> Unit) -> Unit`.
  Evaluate `challenge.protectionSpace.serverTrust`, compute the SPKI hash, then call the
  completion handler with `NSURLSessionAuthChallengeUseCredential` +
  `NSURLCredential(forTrust = trust)` on success or
  `NSURLSessionAuthChallengeCancelAuthenticationChallenge` on failure (fail closed).
  Full Kotlin/Native handler in `references/pin-extraction.md`; SecTrust/SPKI details in
  `swift-security`.

<a id="hygiene"></a>
## Pin hygiene & rotation

- **Pin the SPKI, not the certificate.** The public key survives a cert renewal with the
  same key pair, so a routine renewal won't break the app; a leaf-cert pin breaks on
  every reissue.
- **Always ship >=2 pins.** One current, one **backup** whose private key is generated
  offline now and kept in cold storage. Without a backup already in shipped binaries, a
  forced key change (compromise, CA change) bricks every installed app until an update
  propagates.
- **Rotation is ship-ahead:** add the new key's pin to the app and release it *before*
  the server switches to that key. Only retire the old pin after the new build's adoption
  is high enough. Pins are enforced by the *installed* binary — you cannot fix a bad pin
  set server-side.
- **Fail closed** on money-moving APIs: a pin mismatch must reject the connection, not
  fall back to unpinned TLS. Both `CertificatePinner`s do this by default.
- **What to pin — trade-offs:**
  - *Leaf SPKI* — tightest, but rotates most often (short-lived / ACME certs → high
    breakage risk). Pin only if you control renewal and always reuse the key.
  - *Intermediate CA SPKI* — common sweet spot: survives leaf renewals under the same
    issuing CA; breaks only if the CA changes.
  - *Root CA SPKI* — most durable, weakest guarantee (trusts any leaf that CA issues).
  - Pinning **two positions** (e.g. current leaf + issuing intermediate) plus the offline
    backup is a robust default.
- Don't pin hosts you don't operate (third-party/analytics domains, CDNs you don't
  control) — their rotation schedule will break you.

<a id="testing"></a>
## Testing pinning

- **`MockEngine` cannot exercise pinning.** It short-circuits the transport — no real
  engine, no TLS handshake, no `SecTrust`/`CertificatePinner` — so it proves nothing
  about pins. Keep MockEngine for API/serialization tests (see `kmp-networking`).
- **Unit-test the pin *computation*** as a pure function: feed a known cert's DER SPKI to
  your `sha256/…` producer and assert the base64 equals the `openssl`-derived value in
  `references/pin-extraction.md`. This is the piece most likely to be wrong.
- **Integration-test the enforcement** against a real endpoint:
  - *Negative:* point the client at a host served through a MITM proxy (mitmproxy /
    Charles with its own root installed). A correctly pinned client must **reject** it —
    Android surfaces `SSLPeerUnverifiedException`; iOS cancels the challenge and the Ktor
    call fails. If the request succeeds, pinning is not wired up.
  - *Positive:* the genuine host with correct pins must succeed; flip one pin character
    and confirm it now fails.
  - Run these as Android instrumented tests / iOS device-or-simulator tests, not in
    `commonTest` (no real engine there).
- Add a **backup-pin regression test**: assert every host has >=2 pins so a refactor
  can't silently drop the backup (the `PinSet.init` guard above enforces it at runtime).

<a id="checklist"></a>
## Correctness checklist

- [ ] Pins are **SPKI SHA-256** (`sha256/<base64>`), not leaf-cert fingerprints.
- [ ] **>=2 pins per host**, including an offline-generated backup key already in the binary.
- [ ] Same `PinSet` drives both engines; Android and iOS pin byte-identical hashes.
- [ ] Android: `CertificatePinner` applied via `engine { config { certificatePinner(...) } }` (or `preconfigured`).
- [ ] iOS: built-in Darwin `CertificatePinner` via `handleChallenge`, `validateTrust(true)`; system trust evaluated before the pin check.
- [ ] Boundary is an `expect`/`actual` **factory** (engine type known), not a `HttpClientConfig<*>` extension.
- [ ] **Fails closed** on mismatch — no fallback to unpinned TLS.
- [ ] Rotation plan: new pin shipped *before* the server key changes; old pin retired only after adoption.
- [ ] Only first-party hosts you operate are pinned; third-party/CDN domains left unpinned.
- [ ] Pin computation unit-tested against an `openssl`-derived value; enforcement integration-tested via a MITM proxy (MockEngine does **not** count).
- [ ] Backup-pin guard in place so a refactor can't drop below 2 pins.
