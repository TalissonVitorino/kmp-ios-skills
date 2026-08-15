# Sign in with Apple — server validation & token exchange

The iOS client is untrusted. Whatever it sends to establish a session must be verified
server-side. Sign in with Apple gives you two artifacts from
`ASAuthorizationAppleIDCredential`:

- **`identityToken`** — a signed JWT (RS256) proving the sign-in. Verify it to authenticate.
- **`authorizationCode`** — a single-use code your server exchanges for Apple refresh/access tokens (needed if you want to detect account deletion or keep server-side session continuity).

## 1. Verify the identity token (JWT)

Apple publishes its signing keys as a JWKS you fetch and cache:

```
GET https://appleid.apple.com/auth/keys        → { "keys": [ { kid, alg: "RS256", n, e, ... } ] }
```

Verification steps (use a vetted JWT library — do not hand-roll):

1. Decode the JWT header, read `kid` and `alg` (`RS256`). Pick the matching JWKS key by `kid`; refresh the JWKS if unknown (keys rotate).
2. Verify the **signature** with that public key.
3. Verify claims:
   - `iss` == `https://appleid.apple.com`
   - `aud` == your app's **bundle identifier** (or Services ID for web)
   - `exp` is in the future (`iat`/`exp` sane); reject expired tokens
   - `nonce` == `SHA256(rawNonce)` — the raw nonce the client generated and sent to you out-of-band. This binds the token to this sign-in attempt (anti-replay).
4. Bind the account to the **`sub`** claim — this equals `cred.user` on the client and is stable per developer team. Do **not** key accounts on `email` (may be a private-relay address, and may be absent).
5. `email_verified` / `is_private_email` claims tell you whether Apple verified the address and whether it is a relay (`@privaterelay.appleid.com`). Relay mail must be routed through Apple's SMTP relay if you email the user.

```jsonc
// Example decoded identityToken payload (claims to check in bold: iss, aud, exp, sub, nonce)
{
  "iss": "https://appleid.apple.com",
  "aud": "com.example.fintechapp",
  "exp": 1735689600,
  "iat": 1735603200,
  "sub": "001234.aaaa....bbbb.5566",   // == cred.user
  "nonce": "<SHA256(rawNonce) hex>",
  "email": "user@example.com",
  "email_verified": "true",
  "is_private_email": "false",
  "real_user_status": 2                 // 2 = likelyReal
}
```

## 2. Exchange the authorization code (optional, server-to-server)

Do this only on your server — it needs your Apple private key. Yields a refresh token you can later use to check whether the user has revoked or deleted their Apple ID relationship.

```
POST https://appleid.apple.com/auth/token
Content-Type: application/x-www-form-urlencoded

client_id=<bundle or Services ID>
&client_secret=<a JWT you sign with your Apple key (ES256, kid = key id, iss = team id,
                aud = https://appleid.apple.com, sub = client_id, short exp)>
&code=<authorizationCode from the client>
&grant_type=authorization_code
```

- Response includes `access_token`, `refresh_token`, `id_token` (verify it the same way), `expires_in`.
- The `client_secret` is itself a short-lived ES256 JWT you generate from your Sign in with Apple key (`.p8`) — never a static string.
- Store the `refresh_token`; validate it periodically (`grant_type=refresh_token`) to detect revocation server-side, complementing the client's `getCredentialState`.

## 3. Server-notification webhooks

- Register a **server-to-server notification** endpoint in the Apple developer portal. Apple POSTs signed events (`email-disabled`, `email-enabled`, `consent-revoked`, `account-delete`) so you can react to revocation/deletion even when the app isn't running — required for a clean fintech offboarding.

## Nonce generation (client side)

```swift
import CryptoKit
import Foundation

static func randomNonceString(length: Int = 32) -> String {
    var bytes = [UInt8](repeating: 0, count: length)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
    return String(bytes.map { charset[Int($0) % charset.count] })
}

static func sha256(_ input: String) -> String {
    SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
}
```

- Send `sha256(rawNonce)` on `request.nonce`; keep `rawNonce` and hand it to the server so it can confirm the token's `nonce` claim.

## Checklist (server)

- [ ] JWKS fetched from `appleid.apple.com/auth/keys`, cached, key-selected by `kid`, refreshed on rotation.
- [ ] Signature verified (RS256) before trusting any claim.
- [ ] `iss`, `aud` (bundle id), `exp`, and `nonce == SHA256(rawNonce)` all checked.
- [ ] Account keyed on `sub` (== `cred.user`), not email.
- [ ] `client_secret` is a freshly signed ES256 JWT, not a constant.
- [ ] Server-to-server notification endpoint handles `consent-revoked` / `account-delete`.
