# Keychain Services — deep reference

Framework: `Security`. C APIs operate on `CFDictionary`; bridge Swift `[String: Any]` with `as CFDictionary`.

## The four primitives

| Function | Purpose |
|---|---|
| `SecItemAdd(_:_:)` | Insert a new item. Returns `errSecDuplicateItem` if the identity already exists. |
| `SecItemCopyMatching(_:_:)` | Query. With `kSecReturnData`/`kSecReturnAttributes`/`kSecReturnRef` controls what comes back. |
| `SecItemUpdate(_:_:)` | Update matched items with an attributes dictionary (2nd arg has **only** changed attrs, never `kSecClass`). |
| `SecItemDelete(_:)` | Delete all items matching the query. |

## `kSecClass` values

- `kSecClassGenericPassword` — arbitrary app secrets. Identity = `kSecAttrService` + `kSecAttrAccount`.
- `kSecClassInternetPassword` — server credentials. Extra attrs: `kSecAttrServer`, `kSecAttrProtocol` (`kSecAttrProtocolHTTPS`), `kSecAttrPort`, `kSecAttrPath`, `kSecAttrAuthenticationType`.
- `kSecClassKey` — raw cryptographic keys. Attrs: `kSecAttrKeyClass` (`kSecAttrKeyClassSymmetric`/`Public`/`Private`), `kSecAttrKeyType` (`kSecAttrKeyTypeECSECPrimeRandom`, `kSecAttrKeyTypeRSA`), `kSecAttrApplicationTag` (your identifier `Data`).
- `kSecClassCertificate`, `kSecClassIdentity` (cert + private key pair).

## Internet password example

```swift
let query: [String: Any] = [
    kSecClass as String: kSecClassInternetPassword,
    kSecAttrServer as String: "api.bank.example",
    kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
    kSecAttrAccount as String: "session",
    kSecValueData as String: tokenData,
    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    kSecUseDataProtectionKeychain as String: true,
]
let status = SecItemAdd(query as CFDictionary, nil)
```

## Storing a CryptoKit key with `kSecClassKey`

Simplest portable approach: serialize to `Data` and store as a generic password.

```swift
let key = SymmetricKey(size: .bits256)
let raw = key.withUnsafeBytes { Data($0) }
try keychain.set(raw, account: "fileEncryptionKey")   // generic-password wrapper

// restore
if let raw = try keychain.get(account: "fileEncryptionKey") {
    let key = SymmetricKey(data: raw)
}
```

For a `SecKey` (EC/RSA) use `SecKeyCreateWithData` / `SecKeyCopyExternalRepresentation`, or store the CryptoKit `.rawRepresentation`.

## Batch delete for a service (logout)

```swift
func wipe(service: String) throws {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecUseDataProtectionKeychain as String: true,
    ]
    let status = SecItemDelete(query as CFDictionary)   // deletes ALL accounts for service
    guard status == errSecSuccess || status == errSecItemNotFound
    else { throw KeychainError.unexpectedStatus(status) }
}
```

## Access groups / sharing

- Entitlement `keychain-access-groups` (array). Xcode "Keychain Sharing" capability manages it.
- Effective group IDs are `<AppIdentifierPrefix>.<group>`; App-Group-prefixed groups (`$(TeamIdentifierPrefix)group.com.acme.shared`) let unrelated apps by the same team share.
- Reading: set `kSecAttrAccessGroup` to the exact group. Writing without it uses the **first** entitlement group.
- Query `kSecReturnAttributes` + no `kSecAttrAccessGroup` to discover which group an item landed in during debugging.
- Extensions (Notification Service, Share, Widget) that share a token must (a) be in the same team, (b) list the same access group, (c) use the same `service`/`account`.

## Reading a biometry-gated item without a double prompt

```swift
let context = LAContext()
try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your wallet")

var query = baseQuery(account: "refresh_token")
query[kSecReturnData as String] = true
query[kSecUseAuthenticationContext as String] = context   // reuse the fresh auth
query[kSecMatchLimit as String] = kSecMatchLimitOne
var out: CFTypeRef?
let status = SecItemCopyMatching(query as CFDictionary, &out)
```

Set `kSecUseAuthenticationUI: kSecUseAuthenticationUIFail` to probe whether an item exists without prompting (returns `errSecInteractionNotAllowed` instead of showing UI).

## Common OSStatus codes

| Code | Constant | Meaning |
|---|---|---|
| 0 | `errSecSuccess` | OK |
| -25291 | `errSecNotAvailable` | Keychain unavailable (no data protection) |
| -25299 | `errSecDuplicateItem` | Identity already exists — update instead |
| -25300 | `errSecItemNotFound` | No match (treat as absent) |
| -25293 | `errSecAuthFailed` | Auth failed / item invalidated by settings change |
| -25308 | `errSecInteractionNotAllowed` | Locked / needs UI not permitted now |
| -128 | `errSecUserCanceled` | User canceled the biometric/passcode prompt |
| -34018 | `errSecMissingEntitlement` | Access-group / data-protection entitlement missing |

`SecCopyErrorMessageString(status, nil)` → human-readable string.
