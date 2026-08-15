# CryptoKit — deep reference

`import CryptoKit`. Server parity: `apple/swift-crypto` (same API surface). Availability: core primitives iOS 13+ / macOS 10.15+; HPKE iOS 17+; SHA-3 and post-quantum ML-KEM/ML-DSA iOS 26+.

## AEAD details

```swift
// AAD binds ciphertext to a context (e.g. record id) without encrypting it.
let sealed = try AES.GCM.seal(plaintext, using: key,
                              nonce: AES.GCM.Nonce(),          // random; omit to auto-gen
                              authenticating: contextData)
let opened = try AES.GCM.open(sealed, using: key, authenticating: contextData)

// SealedBox anatomy
sealed.nonce        // 12 bytes
sealed.ciphertext   // same length as plaintext
sealed.tag          // 16-byte auth tag
sealed.combined     // nonce + ciphertext + tag (nil for user-supplied 8-byte nonces)
```

- `open` throws `CryptoKitError.authenticationFailure` on any tamper — never returns bad plaintext.
- ChaChaPoly has the identical shape; pick it when AES hardware isn't guaranteed (rare on modern Apple HW).

## Key derivation

```swift
// Password-based: derive a key from a passphrase (use a random per-secret salt, ≥16 bytes).
let ikm = SymmetricKey(data: Data(passphrase.utf8))
let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt,
                                 info: Data("bank.v1.wrap".utf8), outputByteCount: 32)
```

HKDF is for high-entropy input (e.g. an ECDH shared secret). For low-entropy user passwords, prefer a memory-hard KDF via a vetted library (CryptoKit does not ship Argon2/scrypt/PBKDF2 — PBKDF2 lives in CommonCrypto `CCKeyDerivationPBKDF`).

## Key agreement + derive in one step

```swift
let a = P256.KeyAgreement.PrivateKey()
let shared = try a.sharedSecretFromKeyAgreement(with: bPub)
let sym = shared.hkdfDerivedSymmetricKey(using: SHA256.self,
                                         salt: salt, sharedInfo: Data(), outputByteCount: 32)
// or shared.x963DerivedSymmetricKey(...) to match an X9.63 peer
```

Curves: `Curve25519` (X25519 agreement / Ed25519 signing), `P256`, `P384`, `P521`.

## HPKE (iOS 17+)

```swift
// Sender
var sender = try HPKE.Sender(recipientKey: recipientPublicKey,
                             ciphersuite: .Curve25519_SHA256_AES_GCM_256,
                             info: Data("bank.channel".utf8))
let encapsulated = sender.encapsulatedKey
let ct = try sender.seal(plaintext)

// Recipient
var recipient = try HPKE.Recipient(privateKey: recipientPrivateKey,
                                   ciphersuite: .Curve25519_SHA256_AES_GCM_256,
                                   info: Data("bank.channel".utf8),
                                   encapsulatedKey: encapsulated)
let pt = try recipient.open(ct)
```

## Post-quantum (iOS 26+)

```swift
// ML-DSA signatures (FIPS 204). Software key; SecureEnclave.MLDSA65 for hardware.
let signer = MLDSA65.PrivateKey()
let sig = try signer.signature(for: data)
let ok = signer.publicKey.isValidSignature(sig, for: data)

// ML-KEM key encapsulation (FIPS 203).
let kem = MLKEM768.PrivateKey()
let pub = kem.publicKey
let result = try pub.encapsulate()          // -> (sharedSecret, encapsulated)
let secret = try kem.decapsulate(result.encapsulated)

// Hybrid post-quantum HPKE — recommended: security never falls below X25519 baseline.
// Type XWingMLKEM768X25519, ciphersuite .XWingMLKEM768X25519_SHA256_AES_GCM_256
```

- Sizes are large: ML-DSA-65 signature ≈ 3.3 KB, ML-KEM-768 public key ≈ 1.2 KB — budget storage/bandwidth.
- All PQ types have `SecureEnclave.MLKEM768/1024` and `SecureEnclave.MLDSA65/87` variants for non-exportable keys.
- Quantum-secure TLS (X-Wing) is on by default for system-backed `URLSession` / Network framework connections — no code change needed for transport.

## Signature serialization

```swift
let sk = P256.Signing.PrivateKey()
sk.publicKey.rawRepresentation     // 64 bytes (X||Y) for P256
sk.publicKey.x963Representation    // 65 bytes (0x04||X||Y)
sk.publicKey.pemRepresentation     // PEM string (iOS 14+)
sk.publicKey.derRepresentation
// restore: P256.Signing.PublicKey(rawRepresentation:) / (x963Representation:) / (pemRepresentation:)
```

## Constant-time comparison

`HMAC.isValidAuthenticationCode(...)` and `Digest`/signature comparisons are constant-time. Never compare secret bytes with `==` on `Data` in a security decision path.
