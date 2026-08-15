# Pin extraction, custom Darwin handler, Android NSC XML

Companion to `kmp-tls-pinning/SKILL.md`. Everything here is optional depth — the
built-in `CertificatePinner` on both engines is the primary path.

## Compute the SPKI SHA-256 pin (`sha256/<base64>`)

A pin is the base64 of `SHA-256(DER SubjectPublicKeyInfo)` — the **whole** SPKI
block (algorithm id + public key), not the bare key bytes and not the whole cert.

### From a live host

```bash
openssl s_client -servername api.example.com -connect api.example.com:443 </dev/null 2>/dev/null \
  | openssl x509 -pubkey -noout \
  | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary \
  | openssl enc -base64
# => e.g. 47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=  → pin "sha256/47DEQ...FU="
```

### From a certificate or CSR file (for the OFFLINE backup key)

```bash
# From a cert (.pem/.crt)
openssl x509 -in leaf.pem -pubkey -noout \
  | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl enc -base64

# From a CSR you generated for the not-yet-deployed backup key
openssl req  -in backup.csr -pubkey -noout \
  | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl enc -base64
```

Pin the intermediate CA's SPKI the same way (`-pubkey` on the intermediate cert)
if you choose to pin higher up the chain — see the trade-off table in the SKILL.

### Cross-check against the engines

OkHttp emits the *expected* pin in the `SSLPeerUnverifiedException` message on a
mismatch, so a quick way to discover a pin is to set a deliberately wrong pin,
run once, and read the reported hashes. Do this only against a trusted network.

## Custom Darwin `ChallengeHandler` (Kotlin/Native)

Use only when the built-in `CertificatePinner` is not enough (e.g. you need
custom logging, soft-fail telemetry, or to pin a specific chain position). The
handler runs in `iosMain` against the Security framework bindings; the SPKI/SecTrust
mechanics mirror `swift-security` → `references/pinning.md` (same ASN.1 headers).

```kotlin
// iosMain
import io.ktor.client.engine.darwin.*
import platform.Foundation.*
import platform.Security.*

fun pinnedChallengeHandler(pinnedSpkiSha256: Set<String>): ChallengeHandler =
    { _: NSURLSession, _: NSURLSessionTask,
      challenge: NSURLAuthenticationChallenge,
      completionHandler: (NSURLSessionAuthChallengeDisposition, NSURLCredential?) -> Unit ->

        val space = challenge.protectionSpace
        val trust = space.serverTrust
        if (space.authenticationMethod != NSURLAuthenticationMethodServerTrust || trust == null) {
            completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, null)
            return@ChallengeHandler
        }

        // 1. Validate the chain against the system trust store FIRST.
        val systemValid = SecTrustEvaluateWithError(trust, null)
        // 2. Extract the leaf public key, build SPKI, SHA-256, compare to the pin set.
        val leafKey = SecTrustCopyKey(trust)                       // iOS 14+ (else SecTrustCopyPublicKey)
        val matches = leafKey != null && spkiSha256Base64(leafKey) in pinnedSpkiSha256

        if (systemValid && matches) {
            completionHandler(NSURLSessionAuthChallengeUseCredential, NSURLCredential(forTrust = trust))
        } else {
            completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, null)  // fail closed
        }
    }
```

`spkiSha256Base64(SecKeyRef)` = `SecKeyCopyExternalRepresentation` (raw key) → prepend
the correct ASN.1 SPKI header for the key type (RSA-2048 / RSA-4096 / EC P-256 each
have a distinct header) → `CC_SHA256` → base64. The header bytes and a full Swift
implementation are in `swift-security/references/pinning.md`; the Ktor `CertificatePinner`
does exactly this internally via `SecCertificateCopyKey` + `CC_SHA256`, which is why
you normally never write this by hand.

Apply it: `HttpClient(Darwin) { engine { handleChallenge(pinnedChallengeHandler(pins)) } }`.

## Android Network Security Config (declarative alternative)

Instead of (or in defense-in-depth alongside) the OkHttp `CertificatePinner`, Android
can enforce SPKI pins declaratively in XML — no engine code. Cross-ref `mobile-security`.

```xml
<!-- res/xml/network_security_config.xml -->
<network-security-config>
    <domain-config>
        <domain includeSubdomains="true">api.example.com</domain>
        <pin-set expiration="2027-01-01">
            <!-- base64 SHA-256 of the SPKI — same value as the "sha256/..." pin -->
            <pin digest="SHA-256">47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=</pin>
            <pin digest="SHA-256">633lt352PKRXbOwf4xSEa1M517scpD3l+2VknLXvGWk=</pin> <!-- backup -->
        </pin-set>
    </domain-config>
</network-security-config>
```

```xml
<!-- AndroidManifest.xml -->
<application android:networkSecurityConfig="@xml/network_security_config" ... />
```

Trade-offs vs OkHttp `CertificatePinner`:

- **NSC pro:** applies to every HTTP stack in the process (WebView, other libraries),
  survives even if someone swaps the Ktor engine, and `expiration` makes a stale pin
  set *stop* pinning (fail-open on expiry) rather than brick the app.
- **NSC con:** only `SHA-256` digest, no wildcard host patterns beyond `includeSubdomains`,
  no programmatic rotation, and `expiration` fail-open is the opposite of the fail-closed
  posture you usually want for money-moving APIs.
- iOS has an analogous declarative option — `NSPinnedDomains` in `Info.plist`
  (`NSPinnedLeafIdentities` / `NSPinnedCAIdentities`); see `swift-security`.

Pick one enforcement point per platform as the source of truth; if you use both,
keep the pin sets byte-identical or you will get confusing partial failures.
