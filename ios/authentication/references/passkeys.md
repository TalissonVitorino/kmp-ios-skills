# Passkeys / WebAuthn — depth

AuthenticationServices maps WebAuthn onto `ASAuthorization*` types. The relying party
(RP) identifier is a domain you own and have listed under **Associated Domains** as
`webcredentials:example.com`, backed by an `apple-app-site-association` file. Platform
passkeys sync via iCloud Keychain; security-key passkeys live on hardware (FIDO2).

## Providers and request types

| Kind | Provider | Registration | Assertion |
|---|---|---|---|
| Platform (synced) | `ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier:)` | `createCredentialRegistrationRequest(challenge:name:userID:)` | `createCredentialAssertionRequest(challenge:)` |
| Security key (HW) | `ASAuthorizationSecurityKeyPublicKeyCredentialProvider(_:)` | `createCredentialRegistrationRequest(challenge:displayName:name:userID:)` | `createCredentialAssertionRequest(challenge:)` |

- `challenge`, `userID` are `Data`. `userID` is your opaque WebAuthn user handle (not the email).
- iOS 18+ adds `createCredentialRegistrationRequest(challenge:name:userID:requestStyle:)` with `RequestStyle` (`.standard` / `.conditional`) for conditional-create (upgrade an existing password login to a passkey silently).

## Registration — full delegate

```swift
import AuthenticationServices

final class PasskeyManager: NSObject {
    let rpID = "example.com"

    func register(challenge: Data, name: String, userID: Data) {
        let request = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpID)
            .createCredentialRegistrationRequest(challenge: challenge, name: name, userID: userID)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }
}

extension PasskeyManager: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController,
                                didCompleteWithAuthorization authorization: ASAuthorization) {
        switch authorization.credential {
        case let reg as ASAuthorizationPlatformPublicKeyCredentialRegistration:
            // Send to server for WebAuthn registration verification:
            //   reg.credentialID          (Data) — the new credential id
            //   reg.rawAttestationObject  (Data?) — CBOR attestation
            //   reg.rawClientDataJSON     (Data) — clientDataJSON
            server.finishRegistration(id: reg.credentialID,
                                      attestation: reg.rawAttestationObject,
                                      clientDataJSON: reg.rawClientDataJSON)

        case let asr as ASAuthorizationPlatformPublicKeyCredentialAssertion:
            // Send to server for WebAuthn assertion verification:
            //   asr.credentialID, asr.rawAuthenticatorData, asr.signature,
            //   asr.userID, asr.rawClientDataJSON
            server.finishSignIn(id: asr.credentialID,
                                authenticatorData: asr.rawAuthenticatorData,
                                signature: asr.signature,
                                userID: asr.userID,
                                clientDataJSON: asr.rawClientDataJSON)
        default:
            break
        }
    }

    func authorizationController(controller: ASAuthorizationController,
                                didCompleteWithError error: Error) {
        // ASAuthorizationError.Code of note:
        //   .canceled                 — user dismissed the sheet
        //   .matchedExcludedCredential — a passkey already exists for this account (registration)
        //   .failed / .invalidResponse / .notHandled / .notInteractive / .unknown
    }
}
```

- Encode the byte fields as **base64url** when handing them to a WebAuthn server library.
- `.matchedExcludedCredential` on registration means the RP passed this credential in `excludeCredentials` and the device already holds it — surface "you already have a passkey."

## Security-key specifics

```swift
let provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: rpID)
let request = provider.createCredentialRegistrationRequest(
    challenge: challenge, displayName: "Anne Johnson",
    name: "annejohnson@example.com", userID: userIDData)
request.credentialParameters = [ASAuthorizationPublicKeyCredentialParameters(algorithm: .ES256)]
request.userVerificationPreference = .preferred        // .required / .preferred / .discouraged
request.residentKeyPreference = .required              // discoverable credential on the key
// request.excludedCredentials = [...]                  // block re-registering existing keys
```

- `ASCOSEAlgorithmIdentifier.ES256` is the common signing algorithm; add others only if the server supports them.
- Security keys require a physical tap/PIN; there is no iCloud sync. Use for regulated step-up, not primary consumer login.

## AutoFill-assisted (Conditional UI)

Surfaces passkeys in the QuickType bar above the keyboard on a `.textContentType(.username)` field.

```swift
// UIKit
let request = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpID)
    .createCredentialAssertionRequest(challenge: challenge)
let controller = ASAuthorizationController(authorizationRequests: [request])
controller.delegate = self
controller.presentationContextProvider = self
controller.performAutoFillAssistedRequests()           // NOT performRequests()

// SwiftUI — via the environment controller
@Environment(\.authorizationController) private var authorizationController
let result = try await authorizationController.performAutoFillAssistedRequest(request)
```

- Call it **once** when the login screen appears, alongside the normal button flow. A user tapping "Sign in with a passkey" uses ordinary `performRequests()`.
- The system may return a passkey assertion *or* a saved password through the same result — handle both.

## Cross-device (QR) sign-in

- Omitting `.preferImmediatelyAvailableCredentials` lets the assertion fall back to the "use a passkey from a nearby device" QR flow — the passkey on another iPhone/Android signs the challenge over the hybrid transport. Good default for account-recovery-style sign-in; opt out when you want a silent local-only experience.

## Server side (WebAuthn)

The client only ferries bytes; the server does the real verification with a WebAuthn library:

- **Registration:** parse `attestationObject` + `clientDataJSON`; check the challenge matches, `type == webauthn.create`, RP-ID hash, and store `credentialID` + public key + signature counter.
- **Assertion:** verify the `signature` over `authenticatorData || SHA256(clientDataJSON)` with the stored public key; check challenge, `type == webauthn.get`, RP-ID hash, user-presence/verification flags, and that the counter increased (clone detection).
- Always generate the `challenge` server-side per attempt and expire it.

## Gotchas

- `relyingPartyIdentifier` must equal (or be a registrable suffix of) the site origin the server enforces — a mismatch fails verification, not at request time.
- Associated-domains propagation isn't instant; test on a real device after the AASA file is live (the simulator can use the `applinks:`/`webcredentials:` alternate-mode query params for dev).
- Never derive account identity from the passkey `name` field — it is a display hint only.
