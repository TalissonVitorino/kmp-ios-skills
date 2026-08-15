---
name: authentication
description: "iOS authentication flows for a fintech app with AuthenticationServices + LocalAuthentication — Sign in with Apple (ASAuthorizationAppleIDProvider, ASAuthorizationController, getCredentialState revocation), passkeys/WebAuthn (ASAuthorizationPlatformPublicKeyCredentialProvider register/assert, ASAuthorizationSecurityKeyPublicKeyCredentialProvider, AutoFill-assisted requests), ASWebAuthenticationSession OAuth/OIDC with .https + .customScheme callbacks and PKCE, Password AutoFill (textContentType, associated domains webcredentials), identity-token JWT server validation, and LAContext biometric re-auth for sensitive actions. Use when adding social/passwordless login, passkeys, or a hosted OAuth flow. For Keychain token storage, CryptoKit, and biometric-gated keys see swift-security; anti-fraud device signals see device-integrity; Apple Pay / Wallet see passkit; the KMP boundary see expect-actual."
---

# Authentication (iOS)

User-facing sign-in for a fintech iOS app, built on Apple's **AuthenticationServices**
(`ASAuthorization*`, `ASWebAuthenticationSession`) and **LocalAuthentication** (`LAContext`).
Targets the iOS 26 era. This skill covers *how the user proves identity*; storing the
resulting tokens/keys is a separate concern.

- **Token & key storage / crypto / biometric-gated Keychain items:** `swift-security` (Keychain, CryptoKit, Secure Enclave). Never keep tokens in `UserDefaults`.
- **Device legitimacy / anti-fraud (App Attest, DeviceCheck):** `device-integrity` — pairs with these flows to bind an account to a real device.
- **Apple Pay / Wallet passes:** `passkit`. **KMP boundary** (expose a `commonMain` `AuthService` interface, bind an `iosMain` actual): `expect-actual`.

## Contents

- [Choosing a method](#choosing)
- [Sign in with Apple](#siwa)
- [Passkeys / WebAuthn](#passkeys)
- [Password AutoFill](#autofill)
- [ASWebAuthenticationSession (hosted OAuth/OIDC)](#asweb)
- [Identity-token / server validation](#server)
- [Biometric re-auth for sensitive actions](#reauth)
- [Correctness checklist](#checklist)
- Depth: `references/passkeys.md`, `references/siwa-server-validation.md`

<a id="choosing"></a>
## Choosing a method

| Need | Use |
|---|---|
| First-party account, minimal friction, Apple-gated | Sign in with Apple |
| Passwordless, phishing-resistant, cross-device | Passkeys (platform) |
| Hardware 2FA / regulated step-up | Security-key passkeys |
| Third-party IdP (Auth0/Okta/Google) via web | `ASWebAuthenticationSession` + PKCE |
| Migrate existing username/password users | Password AutoFill |
| Re-confirm the *same* logged-in user before a payment | `LAContext` (see `swift-security`) |

- Prefer **passkeys** for new passwordless accounts and **Sign in with Apple** where an Apple-native identity fits. Both are phishing-resistant; passwords are not.
- All `ASAuthorization*` requests run through one `ASAuthorizationController` — you can offer Sign in with Apple *and* passkeys from a single controller and let the user pick.

<a id="siwa"></a>
## Sign in with Apple

Entitlement: **Sign in with Apple** capability. Server needs the identity-token check in `references/siwa-server-validation.md`.

```swift
import AuthenticationServices
import CryptoKit

final class AppleSignInCoordinator: NSObject {
    private var currentNonce: String?     // raw nonce, kept to match the token later

    func start(anchor: ASPresentationAnchor) {
        let nonce = Self.randomNonceString()
        currentNonce = nonce

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]        // only granted on FIRST sign-in
        request.nonce = Self.sha256(nonce)                    // send the HASH; server compares raw

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController,
                                didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = cred.identityToken,
              let token = String(data: tokenData, encoding: .utf8) else { return }

        // cred.user           — STABLE per-team user id; persist this as the account key.
        // cred.identityToken  — signed JWT → send to YOUR server to verify (see references).
        // cred.authorizationCode — one-time code your server exchanges for refresh token.
        // cred.fullName / cred.email — populated ONLY on the first authorization. Capture now.
        // cred.realUserStatus — .likelyReal / .unknown / .unsupported (anti-fraud signal).
        sendToServer(userID: cred.user, identityToken: token,
                     rawNonce: currentNonce, code: cred.authorizationCode)
    }

    func authorizationController(controller: ASAuthorizationController,
                                didCompleteWithError error: Error) {
        // ASAuthorizationError.Code: .canceled, .failed, .invalidResponse,
        // .notHandled, .notInteractive, .unknown, .matchedExcludedCredential
        guard (error as? ASAuthorizationError)?.code != .canceled else { return }
        // surface a retry
    }
}
```

- **`cred.user` is the identity key** — stable for your team, survives reinstall. Store it (Keychain, see `swift-security`); never rely on email, which the user can hide (private relay) or which arrives only once.
- **Name/email arrive only on the very first authorization.** If your server misses them, the user must remove the app under *Settings ▸ Apple ID ▸ Sign in with Apple* to re-trigger — capture and persist them immediately.
- **Nonce:** send `SHA256(rawNonce)` on the request; keep the raw nonce and have the server confirm the token's `nonce` claim hashes to it. Blocks replay.
- Use the SwiftUI `SignInWithAppleButton(.signIn, onRequest:onCompletion:)` for the button; the `onRequest` closure sets `requestedScopes`/`nonce`, `onCompletion` yields `Result<ASAuthorization, Error>`.

### Revocation / state at launch

```swift
ASAuthorizationAppleIDProvider().getCredentialState(forUserID: storedUserID) { state, _ in
    switch state {
    case .authorized:  break                 // still valid
    case .revoked:     signOutAndClearTokens() // user disabled in Settings → force re-auth
    case .notFound:    routeToLogin()          // never signed in on this device
    case .transferred: migrateUserIdentifier() // app moved to another dev team
    @unknown default:  break
    }
}
```

- Also subscribe to `ASAuthorizationAppleIDProvider.credentialRevokedNotification` to react while running. On `.revoked`, treat the session as dead and purge tokens.

<a id="passkeys"></a>
## Passkeys / WebAuthn

Passkeys are WebAuthn credentials synced through iCloud Keychain (platform) or held on a hardware key (security key). Requires the **Associated Domains** entitlement `webcredentials:example.com` and a matching `apple-app-site-association` file served from that domain — the `relyingPartyIdentifier` must be a domain you own and have associated.

### Registration (platform passkey)

```swift
func registerPasskey(challenge: Data, userName: String, userID: Data,
                     anchor: ASPresentationAnchor) {
    let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
        relyingPartyIdentifier: "example.com")            // must match associated domain
    let request = provider.createCredentialRegistrationRequest(
        challenge: challenge,                             // fresh, from your server
        name: userName,                                   // shown in the passkey sheet
        userID: userID)                                   // your opaque user handle (Data)

    let controller = ASAuthorizationController(authorizationRequests: [request])
    controller.delegate = self
    controller.presentationContextProvider = self
    controller.performRequests()
}
```

On success the delegate receives an `ASAuthorizationPlatformPublicKeyCredentialRegistration`:
`credentialID`, `rawAttestationObject`, `rawClientDataJSON` → forward to your server to store the public key. Details and byte handling in `references/passkeys.md`.

### Sign-in (assertion)

```swift
func signInWithPasskey(challenge: Data) {
    let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
        relyingPartyIdentifier: "example.com")
    let request = provider.createCredentialAssertionRequest(challenge: challenge)
    // request.allowedCredentials = [.init(credentialID: known)]  // optional: restrict to known IDs

    let controller = ASAuthorizationController(authorizationRequests: [request])
    controller.delegate = self
    controller.presentationContextProvider = self
    controller.performRequests(options: .preferImmediatelyAvailableCredentials)
}
```

- The assertion result (`ASAuthorizationPlatformPublicKeyCredentialAssertion`) carries `credentialID`, `rawAuthenticatorData`, `signature`, `userID`, `rawClientDataJSON` — the server verifies the signature against the stored public key.
- `.preferImmediatelyAvailableCredentials` avoids the "insert your security key / use another device" fallback UI when nothing is local — use it for a silent-if-available button; omit it to allow cross-device (QR) sign-in.
- **Security-key variant:** `ASAuthorizationSecurityKeyPublicKeyCredentialProvider(_:)` with `createCredentialRegistrationRequest(challenge:displayName:name:userID:)`; set `credentialParameters = [ASAuthorizationPublicKeyCredentialParameters(algorithm: .ES256)]`, and configure `userVerificationPreference` / residentKey. See `references/passkeys.md`.

### AutoFill-assisted passkey sign-in (QuickType bar)

Mark the username field `.textContentType(.username)`, then fire an AutoFill-assisted request so eligible passkeys surface in the keyboard bar.

```swift
// UIKit: ASAuthorizationController.performAutoFillAssistedRequests()
// SwiftUI: the AuthorizationController environment value —
@Environment(\.authorizationController) private var authorizationController

func autoFillSignIn(challenge: Data) async {
    let request = ASAuthorizationPlatformPublicKeyCredentialProvider(
        relyingPartyIdentifier: "example.com")
        .createCredentialAssertionRequest(challenge: challenge)
    do {
        let result = try await authorizationController.performAutoFillAssistedRequest(request)
        // handle result.passkeyAssertion / result.password
    } catch { /* .canceled etc. */ }
}
```

- Run AutoFill-assisted requests **once, when the sign-in screen appears** — not on a button tap (that is the ordinary `performRequests()` flow).

<a id="autofill"></a>
## Password AutoFill

For migrating username/password accounts. Purely declarative on the field + an associated domain; iOS supplies the saved-credential UI.

```swift
// SwiftUI
TextField("Email", text: $email)
    .textContentType(.username)
    .keyboardType(.emailAddress)
    .textInputAutocapitalization(.never)

SecureField("Password", text: $password)
    .textContentType(.password)          // sign-in

SecureField("New password", text: $pw)
    .textContentType(.newPassword)       // sign-up → triggers Automatic Strong Passwords

TextField("Code", text: $code)
    .textContentType(.oneTimeCode)       // SMS / mailed 2FA code from the QuickType bar
// UIKit equivalent: field.textContentType = .username / .password / .newPassword / .oneTimeCode
```

- **Associated Domains** entitlement with `webcredentials:example.com`; host `apple-app-site-association` (JSON, served over HTTPS at `/.well-known/`, no redirects) so the domain and app are linked. Same association powers passkeys and `.https` OAuth callbacks.
- `.newPassword` on a sign-up field lets iOS propose and save a strong password; pair with a `passwordRules` (`UITextInputPasswordRules`) if your backend constrains format.
- `.oneTimeCode` autofills codes from Messages — do not also disable paste on that field.
- Password AutoFill does **not** need `ASAuthorizationController`; it is field-attribute + domain only.

<a id="asweb"></a>
## ASWebAuthenticationSession (hosted OAuth/OIDC)

For a third-party identity provider's web flow. Runs in an ephemeral, app-isolated Safari view; the system returns the redirect URL to your app. **Always use Authorization Code + PKCE** — never the implicit flow, never embed a raw `WKWebView` login (phishable, and rejected by many IdPs).

```swift
func startOAuth(anchor: ASPresentationAnchor) throws {
    let verifier  = PKCE.makeVerifier()                    // random 43–128 char string
    let challenge = PKCE.challenge(for: verifier)          // base64url(SHA256(verifier))
    let authURL = URL(string:
        "https://idp.example.com/authorize?response_type=code" +
        "&client_id=CLIENT&redirect_uri=https://auth.example.com/callback" +
        "&scope=openid%20profile&state=\(state)" +
        "&code_challenge=\(challenge)&code_challenge_method=S256")!

    let session = ASWebAuthenticationSession(
        url: authURL,
        callback: .https(host: "auth.example.com", path: "/callback")   // needs associated domain
    ) { callbackURL, error in
        guard let callbackURL, error == nil,
              let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "code" })?.value else { return }
        // verify returned `state` == sent state, then exchange `code` + `verifier` for tokens
        self.exchange(code: code, verifier: verifier)
    }
    session.presentationContextProvider = self             // ASWebAuthenticationPresentationContextProviding
    session.prefersEphemeralWebBrowserSession = true       // no shared cookies → forces fresh login
    session.start()
}
```

- **Callback matching:** `.https(host:path:)` (universal-link style, needs the associated domain) is preferred and harder to hijack than `.customScheme("myappscheme")`. The old `init(url:callbackURLScheme:)` initializer is deprecated in favor of `init(url:callback:)`.
- **PKCE is mandatory** for public (mobile) clients — there is no client secret to protect the code exchange. Send `code_challenge`/`S256` on the authorize call, `code_verifier` on the token call.
- `prefersEphemeralWebBrowserSession = true` gives a private session (no SSO cookie carry-over) — best for a login screen; set to `false` if you *want* to reuse an existing IdP session. Set it **before** `start()`.
- Validate the returned `state` matches what you sent (CSRF), then exchange the code server-side or with a confidential-client proxy; store tokens in the Keychain (`swift-security`).
- SwiftUI alternative: the `\.webAuthenticationSession` environment value with `authenticate(using:callback:preferredBrowserSession:additionalHeaderFields:)` (async/throws) instead of a delegate.

<a id="server"></a>
## Identity-token / server validation

**The client is untrusted.** Anything that establishes a session must be verified on your server. For Sign in with Apple, verify the `identityToken` JWT:

- Fetch Apple's public JWKS from `https://appleid.apple.com/auth/keys` (RS256; cache, key-rotate by `kid`).
- Verify signature, then claims: `iss == https://appleid.apple.com`, `aud == <your app bundle id>`, `exp` in the future, and `nonce` equals `SHA256(rawNonce)` you sent.
- Bind the account to the `sub` claim (== `cred.user`). Exchange `authorizationCode` at `https://appleid.apple.com/auth/token` for a refresh token if you need server-side session continuity.
- For **passkeys**, the server runs standard WebAuthn verification (origin, RP ID hash, challenge, signature counter) on the attestation/assertion — the client never decides "is this user real."

Full JWKS verification walk-through, token exchange, and WebAuthn server steps in `references/siwa-server-validation.md`.

<a id="reauth"></a>
## Biometric re-auth for sensitive actions

To re-confirm the *already signed-in* user before moving money, use `LAContext` — this is a local presence check, **not** a login. Do not treat an `evaluatePolicy` boolean as authorization on its own; gate the actual secret behind a biometry-protected Keychain item or Secure Enclave key.

```swift
import LocalAuthentication

func confirmForPayment() async throws {
    let ctx = LAContext()
    ctx.localizedFallbackTitle = "Enter Passcode"
    var err: NSError?
    guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
        throw err ?? LAError(.biometryNotAvailable)
    }
    try await ctx.evaluatePolicy(.deviceOwnerAuthentication,           // biometrics + passcode fallback
                                 localizedReason: "Confirm this transfer")
}
```

- `NSFaceIDUsageDescription` is **required** in Info.plist or Face ID calls crash.
- Full `LAContext` policies, error handling (`.biometryLockout` etc.), context reuse, and the biometry-gated-Keychain pattern live in **`swift-security`** — use that skill for the storage side; this section only positions re-auth within the sign-in surface.

<a id="checklist"></a>
## Correctness checklist

- [ ] `cred.user` (Sign in with Apple) persisted as the account key; name/email captured on first authorization (they never come again).
- [ ] Sign in with Apple request sets `nonce = SHA256(rawNonce)`; server confirms the token's `nonce` claim and validates the JWT (iss/aud/exp/signature).
- [ ] `getCredentialState(forUserID:)` checked at launch; `.revoked`/`.notFound` force sign-out; `credentialRevokedNotification` observed.
- [ ] Passkey `relyingPartyIdentifier` is an owned domain with `webcredentials:` in Associated Domains and a live `apple-app-site-association`.
- [ ] Passkey attestation/assertion verified server-side (WebAuthn: origin, RP-ID hash, challenge, signature, counter) — the client never authorizes itself.
- [ ] AutoFill-assisted passkey request fired once on screen appear, not on a button tap; username field is `.textContentType(.username)`.
- [ ] Password AutoFill fields tagged (`.username` / `.password` / `.newPassword` / `.oneTimeCode`); domain associated.
- [ ] OAuth uses `ASWebAuthenticationSession` with **PKCE** (S256) and Authorization Code — never implicit flow, never a bare `WKWebView`.
- [ ] OAuth `state` validated on return; `prefersEphemeralWebBrowserSession` set intentionally before `start()`; `.https` callback preferred over custom scheme.
- [ ] `presentationContextProvider` returns a live window for every `ASAuthorizationController` / `ASWebAuthenticationSession`.
- [ ] Tokens land in the Keychain (`swift-security`), never `UserDefaults`; cleared on sign-out/revocation.
- [ ] Biometric re-auth gates the *secret* (Keychain/Secure Enclave), not just a boolean; `NSFaceIDUsageDescription` present.
