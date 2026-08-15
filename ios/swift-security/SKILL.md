---
name: swift-security
description: "iOS/macOS security for a fintech app — Keychain Services (SecItem, kSecAttrAccessible, kSecAttrAccessControl / SecAccessControlCreateWithFlags), LocalAuthentication (LAContext, Face ID / Touch ID / Optic ID, evaluatePolicy), CryptoKit (AES-GCM / ChaChaPoly, SymmetricKey, ECDH Curve25519/P256, ECDSA/EdDSA, HKDF, HMAC, SHA-256/512, HPKE, and iOS 26 post-quantum ML-KEM/ML-DSA), Secure Enclave keys, secure token/credential storage, certificate/SPKI pinning with URLSession + SecTrust, App Transport Security, and OWASP MASVS framing. Use when storing tokens/keys, gating secrets behind biometrics, encrypting/signing/deriving keys, pinning TLS, or migrating secrets off UserDefaults/plist. The Android/KMP counterpart is `mobile-security` (Keystore, EncryptedFile); for the KMP boundary see `expect-actual`."
---

# Swift Security (iOS / macOS)

Security building blocks for a fintech iOS/macOS app: secret storage, biometric
gating, cryptography, and transport pinning. Grounded in Apple's Security,
LocalAuthentication, and CryptoKit frameworks.

- **Android/KMP counterpart:** `mobile-security` (Android Keystore, `EncryptedFile`, network security config).
- **KMP boundary:** expose a `commonMain` `interface SecureStorage` and bind it to a
  Keychain-backed `actual` in `iosMain`; see `expect-actual`. Never let shared code hold plaintext secrets.

## Contents

- [Threat model / do-not list](#threat-model)
- [Keychain Services](#keychain-services)
- [Access control (biometrics / passcode)](#access-control)
- [LocalAuthentication](#localauthentication)
- [CryptoKit](#cryptokit)
- [Secure Enclave](#secure-enclave)
- [Secure token / credential storage](#secure-token-storage)
- [Certificate / SPKI pinning](#pinning)
- [Compliance (OWASP MASVS)](#compliance)
- [Correctness checklist](#checklist)
- References: `references/keychain.md`, `references/cryptokit.md`, `references/pinning.md`

<a id="threat-model"></a>
## Threat model / do-not list

- **Never** store tokens, PANs, keys, or PII in `UserDefaults`, plist, or unencrypted files — all are world-readable in a backup / jailbreak. Use Keychain or CryptoKit-sealed blobs.
- **Never** hardcode API keys / secrets in the binary — they are trivially extractable with `strings`.
- **Never** log secrets, or put them in URL query strings, crash reports, or analytics.
- Prefer **`...ThisDeviceOnly`** accessibility for secrets that must not migrate to a new device via iCloud/iTunes backup.
- Gate high-value secrets (payment auth, keys that move money) behind biometrics via `kSecAttrAccessControl` — not app-side checks alone.

<a id="keychain-services"></a>
## Keychain Services

`SecItem*` C APIs take/return `CFDictionary`. In Swift, build `[String: Any]` and bridge with `as CFDictionary`. Always set `kSecUseDataProtectionKeychain: true` for consistent iOS-style data-protection semantics (required on macOS to use the modern keychain).

### Query keys

- `kSecClass`: `kSecClassGenericPassword` (app secrets/tokens), `kSecClassInternetPassword` (server creds with host/port/protocol), `kSecClassKey` (raw crypto keys), `kSecClassCertificate`, `kSecClassIdentity`.
- Identity attributes (generic password): `kSecAttrService` (your namespace) + `kSecAttrAccount` (the key). The pair is the unique identity.
- `kSecValueData`: the secret `Data`.
- `kSecAttrAccessible` **or** `kSecAttrAccessControl` (mutually exclusive): protection level.
- `kSecAttrAccessGroup`: sharing group (see below).
- Retrieval: `kSecReturnData: true`, `kSecMatchLimit: kSecMatchLimitOne`.

### `kSecAttrAccessible` levels (no access control needed)

| Value | Unlocked required | Migrates to new device |
|---|---|---|
| `kSecAttrAccessibleWhenUnlocked` | yes (device unlocked) | yes |
| `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` | yes | **no** |
| `kSecAttrAccessibleAfterFirstUnlock` | after first unlock post-boot (background access) | yes |
| `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` | after first unlock | **no** |
| `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` | passcode must be set; item deleted if passcode removed | **no**, non-migratable |

- **Fintech default:** `...WhenUnlockedThisDeviceOnly` for interactive secrets; `...AfterFirstUnlockThisDeviceOnly` only when a background task (push, refresh) must read it while locked.
- `...WhenPasscodeSetThisDeviceOnly` is the strongest; the item is destroyed if the user removes their passcode.

### Idiomatic wrapper (generic password)

```swift
import Foundation
import Security

enum KeychainError: Error { case unexpectedStatus(OSStatus) }

struct Keychain {
    let service: String
    var accessGroup: String? = nil

    private func baseQuery(account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    /// Insert-or-update. Upsert avoids errSecDuplicateItem races.
    func set(_ data: Data, account: String,
             accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly) throws {
        var query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query.merge(attributes) { _, new in new }
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    func get(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError.unexpectedStatus(status)
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound
        else { throw KeychainError.unexpectedStatus(status) }
    }
}
```

### OSStatus handling

- `errSecSuccess (0)`, `errSecItemNotFound (-25300)`, `errSecDuplicateItem (-25299)`, `errSecAuthFailed (-25293)`, `errSecUserCanceled (-128)`, `errSecInteractionNotAllowed (-25308)` (item needs unlock but device is locked / no UI), `errSecNotAvailable`.
- Get a readable message: `SecCopyErrorMessageString(status, nil)`.
- Treat `errSecItemNotFound` as "no value", not an error. Surface `errSecInteractionNotAllowed` as "try again after unlock".

### Access groups / sharing (app + extensions)

- Add a Keychain Sharing entitlement; group IDs are prefixed with your App ID team prefix (or an App Group's).
- Set `kSecAttrAccessGroup` to share one item across your app, its widget, and app extensions (e.g. share the auth token with a Notification Service Extension).
- Omit `kSecAttrAccessGroup` on writes to use the app's default (first) group; you must specify it to read/write another shared group.
- More detail and `internetPassword` / `kSecClassKey` usage in `references/keychain.md`.

<a id="access-control"></a>
## Access control (biometrics / passcode)

Use `kSecAttrAccessControl` instead of `kSecAttrAccessible` to require user presence at access time. Build a `SecAccessControl` with `SecAccessControlCreateWithFlags`.

```swift
func biometricAccessControl() throws -> SecAccessControl {
    var error: Unmanaged<CFError>?
    guard let ac = SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, // protection class
        [.biometryCurrentSet],                            // flags
        &error
    ) else { throw error!.takeRetainedValue() as Error }
    return ac
}
```

- Flags (`SecAccessControlCreateFlags`):
  - `.biometryAny` — any currently enrolled Face ID / Touch ID.
  - `.biometryCurrentSet` — **invalidates the item if the enrolled biometric set changes** (finger/face added or removed). Strongest binding; preferred for money-moving secrets.
  - `.devicePasscode` — passcode only.
  - `.userPresence` — biometry, falling back to passcode (system chooses).
  - `.and` / `.or` — combine, e.g. `[.biometryCurrentSet, .or, .devicePasscode]`.
  - `.privateKeyUsage` — for Secure Enclave key operations (see below).
- Store with `kSecAttrAccessControl: ac` (do **not** also set `kSecAttrAccessible`).
- Reading such an item triggers the biometric/passcode prompt automatically. Provide context: set `kSecUseOperationPrompt` (or pass an `LAContext` via `kSecUseAuthenticationContext` to reuse a fresh evaluation and avoid a double prompt).
- Changing security settings (passcode/biometry) can render access-control items inaccessible — handle `errSecAuthFailed` by re-provisioning.

<a id="localauthentication"></a>
## LocalAuthentication

`LAContext` drives Face ID / Touch ID / Optic ID and passcode.

- **Info.plist:** `NSFaceIDUsageDescription` is **required** or Face ID calls crash.
- Policies:
  - `.deviceOwnerAuthenticationWithBiometrics` — biometrics only; fails if none enrolled.
  - `.deviceOwnerAuthentication` — biometrics **with passcode fallback** (recommended for re-auth so users are never locked out).
  - `.deviceOwnerAuthenticationWithWristDetection` (watchOS), `.deviceOwnerAuthenticationWithBiometricsOrCompanion` (macOS: Watch/biometrics).

```swift
import LocalAuthentication

func authenticate(reason: String) async throws {
    let context = LAContext()
    context.localizedFallbackTitle = "Enter Passcode"

    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
        throw error ?? LAError(.biometryNotAvailable)
    }
    // biometryType is only valid AFTER canEvaluatePolicy: .none/.touchID/.faceID/.opticID
    try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
}
```

- `evaluatePolicy` has an `async throws` form (iOS 15+) and a completion-handler form. The reply runs on a private queue — hop to `@MainActor` for UI.
- Common `LAError` cases: `.authenticationFailed`, `.userCancel`, `.userFallback`, `.biometryNotAvailable`, `.biometryNotEnrolled`, `.biometryLockout` (too many failures — requires passcode to re-enable), `.passcodeNotSet`, `.appCancel`, `.invalidContext`. Error domain: `LAError.errorDomain` / `LAErrorDomain`.
- Re-auth patterns:
  - Set `context.touchIDAuthenticationAllowableReuseDuration` to skip re-prompting within a short window.
  - A single `LAContext` caches one successful evaluation — reuse it via `kSecUseAuthenticationContext` to read an access-control-gated Keychain item without a second prompt.
  - Create a **fresh** `LAContext` per sensitive operation you want to force re-auth for; call `context.invalidate()` when done.
- **Do not** treat a plain `evaluatePolicy` success as authorization for a secret. The strong pattern is to keep the secret in a **biometry-gated Keychain item** (or Secure Enclave key), so the crypto material itself is unreachable without a live authentication — not merely a boolean your code can be patched to skip.

<a id="cryptokit"></a>
## CryptoKit

`import CryptoKit`. Core primitives iOS 13+; HPKE iOS 17+; SHA-3 and post-quantum iOS 26+. Server-side parity via `swift-crypto`.

### Symmetric AEAD (encrypt-at-rest)

```swift
import CryptoKit

let key = SymmetricKey(size: .bits256)               // random 256-bit key

// AES-GCM
let sealed = try AES.GCM.seal(plaintext, using: key) // nonce auto-generated
let combined = sealed.combined!                       // nonce | ciphertext | tag — persist this
let opened = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key)

// ChaChaPoly — prefer on devices without AES hardware acceleration
let box = try ChaChaPoly.seal(plaintext, using: key)
let clear = try ChaChaPoly.open(box, using: key)
```

- **Never reuse a (key, nonce) pair.** Let CryptoKit generate the nonce; only supply your own if you can guarantee uniqueness.
- Bind context with Additional Authenticated Data: `seal(_, using:, authenticating:)`.
- Persist the `SymmetricKey` in the Keychain (`kSecClassKey` or as generic-password `Data` from `key.withUnsafeBytes { Data($0) }`), or derive it — never hardcode it.

### Hashing / HMAC / HKDF

```swift
let digest = SHA256.hash(data: data)                 // also SHA512, SHA384; SHA3_256 (iOS 26+)
let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
let ok  = HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: data, using: key)

let derived = HKDF<SHA256>.deriveKey(
    inputKeyMaterial: sharedSecret,                  // SymmetricKey or SharedSecret
    salt: salt, info: Data("app.v1.encryption".utf8),
    outputByteCount: 32)
```

- Compare MACs with `isValidAuthenticationCode` (constant-time), never `==` on raw bytes.

### Key agreement (ECDH)

```swift
let priv = Curve25519.KeyAgreement.PrivateKey()      // or P256/P384/P521.KeyAgreement
let shared = try priv.sharedSecretFromKeyAgreement(with: peerPublicKey)
let symKey = shared.hkdfDerivedSymmetricKey(
    using: SHA256.self, salt: salt,
    sharedInfo: Data(), outputByteCount: 32)
```

### Signatures

```swift
// EdDSA (Ed25519)
let sk = Curve25519.Signing.PrivateKey()
let sig = try sk.signature(for: data)
let valid = sk.publicKey.isValidSignature(sig, for: data)

// ECDSA (P-256)
let p = P256.Signing.PrivateKey()
let s = try p.signature(for: data)
```

- Serialize public keys with `.rawRepresentation` / `.x963Representation` / `.pemRepresentation`; restore with the matching initializer.

### HPKE (iOS 17+) and post-quantum (iOS 26+)

- `HPKE.Sender` / `HPKE.Recipient` for RFC 9180 hybrid public-key encryption (classical ciphersuites like `.Curve25519_SHA256_AES_GCM_256`).
- **Post-quantum (iOS 26+):** key encapsulation `MLKEM768` / `MLKEM1024`; signatures `MLDSA65` / `MLDSA87`; hybrid HPKE type `XWingMLKEM768X25519` with ciphersuite `.XWingMLKEM768X25519_SHA256_AES_GCM_256`. All have `SecureEnclave.*` counterparts. Prefer the **hybrid** (X-Wing) suite so security never regresses below the classical baseline.
- Quantum-secure TLS is enabled by default in `URLSession` / Network framework for system-backed connections. See `references/cryptokit.md` for HPKE and PQC snippets.

<a id="secure-enclave"></a>
## Secure Enclave

Hardware-isolated coprocessor; private keys are **non-exportable** — you only ever hold a `dataRepresentation` wrapped blob to reconstruct the handle, never the raw key.

```swift
guard SecureEnclave.isAvailable else { /* simulator / older HW: fall back */ return }

let access = try biometricAccessControl()            // .biometryCurrentSet, etc.
let key = try SecureEnclave.P256.Signing.PrivateKey(
    accessControl: access,
    authenticationContext: LAContext())               // optional pre-authorized context
let signature = try key.signature(for: data)          // triggers biometric prompt
// Persist for later:
let blob = key.dataRepresentation                      // store in Keychain (ThisDeviceOnly)
let restored = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
```

- Types: `SecureEnclave.P256.Signing` (ECDSA) and `SecureEnclave.P256.KeyAgreement` (ECDH); plus PQ `SecureEnclave.MLKEM768/1024` and `SecureEnclave.MLDSA65/87` (iOS 26+).
- Only P-256 for classical curves. Not available in the Simulator — always guard `SecureEnclave.isAvailable` and provide a software fallback for dev.
- Use for keys that must never leave the device: device-binding / attestation keys, signing payment authorizations. The Secure Enclave enforces the access control at the hardware level, so a compromised app process still cannot use the key without a live biometric.

<a id="secure-token-storage"></a>
## Secure token / credential storage

- OAuth access/refresh tokens, API keys, session cookies → **Keychain generic password**, keyed by `service` + `account` (e.g. account = user id or `"refresh_token"`).
- Access token: `...WhenUnlockedThisDeviceOnly`. Refresh token (higher value, longer-lived): consider `kSecAttrAccessControl` with `.userPresence` so re-issuing a session requires the user.
- Clear all tokens on logout (`SecItemDelete` per item, or delete the whole service query).
- **Migration off UserDefaults/plist:** on launch, read any legacy secret from `UserDefaults`, write it to the Keychain, then remove it:

```swift
if let legacy = UserDefaults.standard.string(forKey: "authToken") {
    try keychain.set(Data(legacy.utf8), account: "authToken")
    UserDefaults.standard.removeObject(forKey: "authToken")
}
```

- Encrypt any large secret blobs at rest with an `AES.GCM`-sealed file whose `SymmetricKey` lives in the Keychain — keep only small secrets directly in the Keychain.

<a id="pinning"></a>
## Certificate / SPKI pinning

Pin the server's **public key (SPKI hash)**, not the leaf certificate — the cert rotates, the key can persist across renewals. Implement in a `URLSessionDelegate`.

```swift
final class PinningDelegate: NSObject, URLSessionDelegate {
    // SHA-256 of the DER SubjectPublicKeyInfo, base64. Pin ≥2 (current + backup).
    let pinnedSPKIHashes: Set<String>

    init(pins: Set<String>) { self.pinnedSPKIHashes = pins }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return completionHandler(.performDefaultHandling, nil)
        }
        // 1. Validate the chain against the system trust store FIRST.
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            return completionHandler(.cancelAuthenticationChallenge, nil)
        }
        // 2. Extract the leaf public key and compare its SPKI hash.
        guard let leafKey = SecTrustCopyKey(trust),
              let spki = SecKeyCopyExternalRepresentation(leafKey, nil) as Data?,
              pinnedSPKIHashes.contains(sha256Base64(spkiHeader(for: leafKey) + spki)) else {
            return completionHandler(.cancelAuthenticationChallenge, nil)
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
```

- **Always evaluate default trust first** (`SecTrustEvaluateWithError`), then add the pin — pinning replaces trust decisions only after the chain is otherwise valid.
- `SecKeyCopyExternalRepresentation` returns the raw key, not full SPKI DER; prepend the correct ASN.1 SPKI header for the key type before hashing (`spkiHeader(for:)` helper in `references/pinning.md`).
- Pin at least two keys (current + backup) so a key rotation doesn't brick the app. Ship pin updates ahead of rotation.
- **App Transport Security (ATS):** on by default — TLS 1.2+, forward secrecy, no weak ciphers. Do **not** add `NSAllowsArbitraryLoads`. For pinning you can additionally declare `NSPinnedDomains` in `Info.plist` (`NSPinnedCAIdentities` / `NSPinnedLeafIdentities`) to let ATS enforce SPKI pins without delegate code — simpler, but less flexible than the delegate approach.
- Full delegate + ASN.1 header helper and `NSPinnedDomains` plist in `references/pinning.md`.

<a id="compliance"></a>
## Compliance (OWASP MASVS)

For a fintech app, map controls to OWASP MASVS (Mobile Application Security Verification Standard) and test against MASTG:

- **MASVS-STORAGE:** secrets in Keychain / Secure Enclave, `ThisDeviceOnly`, nothing sensitive in `UserDefaults`/plist/logs/pasteboard.
- **MASVS-CRYPTO:** platform CryptoKit primitives, no home-rolled crypto, strong AEAD, no hardcoded keys, PQC-ready.
- **MASVS-AUTH:** biometric-gated keys (not app-side booleans), passcode fallback, re-auth on sensitive actions.
- **MASVS-NETWORK:** ATS enforced, TLS 1.2+/1.3, SPKI pinning with backups.
- **MASVS-PLATFORM:** minimal Keychain access-group sharing, jailbreak/tamper signals as defense-in-depth (see `device-integrity`).
- **MASVS-RESILIENCE:** obfuscation and integrity checks are secondary — they slow, not stop, an attacker; never the primary control.

<a id="checklist"></a>
## Correctness checklist

- [ ] No secret in `UserDefaults`, plist, source, logs, analytics, or URL params.
- [ ] `kSecUseDataProtectionKeychain: true` on every query (mandatory on macOS).
- [ ] Accessibility is `...ThisDeviceOnly` unless cross-device sync is explicitly required.
- [ ] Money-moving / high-value secrets use `kSecAttrAccessControl` (`.biometryCurrentSet`), not app-side checks.
- [ ] Upsert (update-then-add) instead of blind add — no `errSecDuplicateItem`.
- [ ] `errSecItemNotFound` treated as absent, not failure; `errSecInteractionNotAllowed` surfaced as "unlock and retry".
- [ ] `NSFaceIDUsageDescription` present in Info.plist.
- [ ] `.deviceOwnerAuthentication` (with passcode fallback) for re-auth; handle `.biometryLockout`.
- [ ] `biometryType` read only after `canEvaluatePolicy`.
- [ ] CryptoKit only — no CommonCrypto hand-rolling; AES-GCM/ChaChaPoly with unique nonces; MACs verified constant-time.
- [ ] Secure Enclave guarded by `SecureEnclave.isAvailable` with a software fallback for the Simulator.
- [ ] Keys stored/derived, never hardcoded; new PQC-capable designs use hybrid (X-Wing) suites where relevant.
- [ ] Pinning validates system trust first, hashes SPKI (with correct ASN.1 header), pins ≥2 keys, never disables ATS.
- [ ] Tokens cleared on logout; legacy secrets migrated off insecure stores at launch.
