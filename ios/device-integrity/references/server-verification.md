# App Attest — server-side verification (depth)

Verification happens entirely on **your** server. Apple offers no "verify this attestation"
endpoint (only the optional risk-metric receipt exchange). Language-agnostic; sketches use
`swift-crypto` (server-side CryptoKit parity) but the byte layout is universal.

## Attestation object layout (CBOR)

```
{
  "fmt":     "apple-appattest",
  "attStmt": { "x5c": [ credCert, intermediateCert ], "receipt": <bytes> },
  "authData": <bytes>
}
```

### authData byte layout (min 37 bytes for an assertion; longer for attestation)

| Offset | Len | Field |
|---|---|---|
| 0 | 32 | `rpIdHash` = SHA256(App ID) |
| 32 | 1 | flags |
| 33 | 4 | signCount (big-endian) |
| 37 | 16 | AAGUID (attestation only) |
| 53 | 2 | credentialIdLength L (attestation only) |
| 55 | L | credentialId (== keyId) (attestation only) |
| … | … | CBOR-encoded public key (attestation only) |

App ID string is `"<TeamID>.<BundleID>"`, e.g. `A1B2C3D4E5.com.example.bank`.

## Full attestation verification (ordered)

1. **Decode CBOR** → `x5c`, `receipt`, `authData`.
2. **Certificate chain.** Build credCert (`x5c[0]`) → intermediate (`x5c[1]`) → **Apple App Attest Root CA**
   (download from Apple's certificate page; pin its SPKI). Reject if the chain doesn't validate or is expired.
3. **Nonce.**
   - `clientDataHash` = SHA256(challenge you issued).
   - `nonce = SHA256( authData || clientDataHash )`.
   - Extract credCert extension **OID `1.2.840.113635.100.8.2`** → it's a DER `SEQUENCE` wrapping an
     `OCTET STRING`. Decode and require the inner 32 bytes `== nonce`.
4. **Key identifier.** `SHA256( credCert.publicKey rawRepresentation )` `== base64Decode(keyId)`.
5. **RP ID hash.** `authData[0..<32]` `== SHA256("<TeamID>.<BundleID>")`.
6. **Counter.** big-endian `authData[33..<37]` `== 0`.
7. **AAGUID.** `authData[37..<53]`:
   - production → ASCII `"appattest"` + `0x00 * 7`
   - development → ASCII `"appattestdevelop"`
   - Must match the environment you provisioned; a production server should reject development AAGUIDs.
8. **Credential ID.** `authData[55..<55+L]` `== base64Decode(keyId)`.

On success: persist the credCert **public key** (P-256) for this user/device, initialize stored
`signCount = 0`, mark the challenge consumed, optionally store the `receipt` for risk queries.

```swift
// Sketch — nonce check with swift-crypto
import Crypto
let clientDataHash = SHA256.hash(data: challenge)          // Data
var composite = Data(authData); composite.append(contentsOf: clientDataHash)
let nonce = Data(SHA256.hash(data: composite))
guard nonceFromCertExtension(credCert, oid: "1.2.840.113635.100.8.2") == nonce else { throw .badNonce }
```

## Assertion verification (per sensitive request)

Assertion CBOR: `{ "signature": <bytes>, "authenticatorData": <bytes> }`.

1. `clientDataHash = SHA256( requestBody || challenge )` — recompute from the exact bytes received.
2. `nonce = SHA256( authenticatorData || clientDataHash )`.
3. Verify `signature` over `nonce` using the **stored P-256 public key** (ECDSA, DER signature).
4. `authenticatorData[0..<32] == SHA256(App ID)`.
5. `signCount` (`authenticatorData[33..<37]`, big-endian) **strictly greater** than the stored value;
   then persist the new value. Non-increasing ⇒ replay/clone ⇒ reject.

```swift
let clientDataHash = SHA256.hash(data: requestBody + challenge)
var comp = Data(authenticatorData); comp.append(contentsOf: clientDataHash)
let nonce = Data(SHA256.hash(data: comp))
let sig = try P256.Signing.ECDSASignature(derRepresentation: signature)
guard storedPublicKey.isValidSignature(sig, for: nonce) else { throw .badSignature }
guard newSignCount > storedSignCount else { throw .replay }
```

## Gotchas

- Development and production use **different root CAs and AAGUIDs**. A single server verifying both
  must branch on the app's environment; never accept a development attestation in production.
- The challenge must be **single-use and expiring**. Store issued challenges server-side; delete on use.
- `attestKey` succeeds once per key. A client that re-attests must `generateKey()` first; your server
  should replace the stored key atomically.
- Public key format: credCert carries an uncompressed P-256 point; import via
  `P256.Signing.PublicKey(x963Representation:)` (0x04 prefix) after extracting from the cert.
- Clock skew: validate cert `notBefore`/`notAfter` with a small tolerance.
