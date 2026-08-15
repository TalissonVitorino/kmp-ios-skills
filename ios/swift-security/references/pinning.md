# Certificate / SPKI pinning — deep reference

Pin the **SubjectPublicKeyInfo (SPKI)** hash, not the leaf certificate. Certs rotate on renewal; the key usually persists, and if you rotate the key you can ship a backup pin ahead of time.

## Why validate default trust first

Pinning is an *addition* to, not a replacement for, normal chain validation. Always run `SecTrustEvaluateWithError` so revoked/expired/mis-issued chains are rejected, then apply the pin as an extra gate.

## Full SPKI pinning delegate

```swift
import Foundation
import CryptoKit
import Security

final class SPKIPinningDelegate: NSObject, URLSessionDelegate {
    let pinnedSPKIHashes: Set<String>          // base64(SHA256(DER SPKI)); include a backup
    init(pins: Set<String>) { pinnedSPKIHashes = pins }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {

        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return completionHandler(.performDefaultHandling, nil)
        }

        // 1. Standard chain validation against the system trust store.
        var err: CFError?
        guard SecTrustEvaluateWithError(trust, &err) else {
            return completionHandler(.cancelAuthenticationChallenge, nil)
        }

        // 2. Hash the leaf's SPKI and compare against pins.
        guard let key = SecTrustCopyKey(trust),
              let spkiHash = Self.spkiSHA256Base64(for: key),
              pinnedSPKIHashes.contains(spkiHash) else {
            return completionHandler(.cancelAuthenticationChallenge, nil)
        }

        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    /// SecKeyCopyExternalRepresentation gives the RAW key, not the ASN.1 SPKI.
    /// Prepend the algorithm-specific SPKI header, then SHA-256, then base64.
    static func spkiSHA256Base64(for key: SecKey) -> String? {
        guard let raw = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        guard let header = spkiHeader(for: key) else { return nil }
        let spki = header + raw
        return Data(SHA256.hash(data: spki)).base64EncodedString()
    }

    /// ASN.1 SPKI headers (DER) by key type/size. Add rows as needed.
    static func spkiHeader(for key: SecKey) -> Data? {
        guard let attrs = SecKeyCopyAttributes(key) as? [CFString: Any],
              let type = attrs[kSecAttrKeyType] as? String,
              let bits = attrs[kSecAttrKeySizeInBits] as? Int else { return nil }

        switch (type, bits) {
        case (kSecAttrKeyTypeECSECPrimeRandom as String, 256):   // P-256
            return Data([0x30,0x59,0x30,0x13,0x06,0x07,0x2a,0x86,0x48,0xce,0x3d,0x02,0x01,
                         0x06,0x08,0x2a,0x86,0x48,0xce,0x3d,0x03,0x01,0x07,0x03,0x42,0x00])
        case (kSecAttrKeyTypeRSA as String, 2048):
            return Data([0x30,0x82,0x01,0x22,0x30,0x0d,0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,
                         0x0d,0x01,0x01,0x01,0x05,0x00,0x03,0x82,0x01,0x0f,0x00])
        case (kSecAttrKeyTypeRSA as String, 4096):
            return Data([0x30,0x82,0x02,0x22,0x30,0x0d,0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,
                         0x0d,0x01,0x01,0x01,0x05,0x00,0x03,0x82,0x02,0x0f,0x00])
        default:
            return nil
        }
    }
}
```

Wire it up:

```swift
let delegate = SPKIPinningDelegate(pins: ["YLh1dUR9y6Kja30RrAn7JKnbQG/uEtLMkBgFF2Fuihg=",  // current
                                          "Vjs8r4z+80wjNcr1YKepWQboSIRi63WsWXhIMN+eWys="]) // backup
let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
```

## Computing a pin from a host (dev tooling)

```bash
openssl s_client -connect api.bank.example:443 -servername api.bank.example </dev/null 2>/dev/null \
  | openssl x509 -pubkey -noout \
  | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary \
  | openssl enc -base64
```

## ATS `NSPinnedDomains` (declarative alternative)

Enforced by App Transport Security without delegate code. SPKI pins go in `Info.plist`:

```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSPinnedDomains</key>
  <dict>
    <key>api.bank.example</key>
    <dict>
      <key>NSIncludesSubdomains</key><true/>
      <key>NSPinnedLeafIdentities</key>
      <array>
        <dict><key>SPKI-SHA256-BASE64</key><string>YLh1dUR9y6Kja30RrAn7JKnbQG/uEtLMkBgFF2Fuihg=</string></dict>
        <dict><key>SPKI-SHA256-BASE64</key><string>Vjs8r4z+80wjNcr1YKepWQboSIRi63WsWXhIMN+eWys=</string></dict>
      </array>
    </dict>
  </dict>
</dict>
```

- Prefer `NSPinnedDomains` when you just need static SPKI pins — less code, harder to disable accidentally, still layered on normal ATS/trust evaluation.
- Prefer the delegate when you need dynamic pins, per-environment pins, or to log/telemeter pin failures.

## Operational rules

- Always ship **≥2 pins** (current + next). Deploy the backup pin *before* rotating the server key.
- Never disable ATS (`NSAllowsArbitraryLoads`) to "make pinning work" — pinning sits on top of ATS.
- Keep pins updatable via a signed remote config or app update so a forced rotation can't brick clients.
