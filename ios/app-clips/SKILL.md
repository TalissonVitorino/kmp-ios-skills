---
name: app-clips
description: "Build iOS App Clips for a fintech app — App Clip target + entitlements (com.apple.developer.on-demand-install-capable, parent-application-identifiers, associated-appclip-app-identifiers, associated-domains appclips:), invocation URLs, App Clip Codes / NFC / QR / Safari App Clip banner + Smart App Banner (apple-itunes-app app-clip-bundle-id) / Maps / Messages, App Store Connect default vs Advanced App Clip Experiences, NSUserActivity(browsingWeb) webpageURL routing, the 15MB / iOS 17 100MB thinned-bundle budget, NSAppClip Info.plist ephemeral notification + location confirmation (APActivationPayload.confirmAcquired / CLCircularRegion), SKOverlay.AppClipConfiguration full-app promotion, and App Group / shared-container handoff to the full app. Use when creating an App Clip, wiring invocation/routing, configuring experiences, or migrating to the full app. Cross-refs: deep-linking (Universal Links / associated domains), swift-security (Keychain handoff caveat), cloudkit (data handoff), core-nfc (writing tags), storekit (StoreKit purchases), app-store-review (submission)."
---

# App Clips (iOS)

A small, fast, launch-on-demand slice of your full app — invoked from a URL (NFC,
QR, App Clip Code, Safari banner, Maps, Messages) without an App Store install.
For a fintech app the common uses are pay-at-table, scan-to-pay a merchant code,
onboard-a-card, or claim-an-offer, then hand off to the full app. Grounded in
Apple's `AppClip` framework, StoreKit, and App Store Connect docs (iOS 26 era).

- **Deep links / associated domains:** an App Clip is Universal-Links machinery narrowed to one target; see `deep-linking`.
- **Secure handoff:** shared secrets go through an App Group container or CloudKit, **not** the Keychain (App Clip Keychain items are *not* readable by the full app) — see `swift-security`, `cloudkit`.
- **Writing physical tags:** encode the invocation URL on an NDEF tag with `core-nfc`.
- **Purchases inside the clip:** StoreKit works in a clip — see `storekit`; Apple Pay via `passkit`.
- **Submission gates:** privacy manifest, size, entitlements — see `app-store-review`.

## Contents

- [Architecture & targets](#architecture)
- [Entitlements & Info.plist](#entitlements)
- [Invocation & routing (NSUserActivity)](#routing)
- [Invocation methods](#invocation-methods)
- [App Store Connect experiences](#experiences)
- [Size & capability budget](#budget)
- [Ephemeral permissions](#ephemeral)
- [Location confirmation](#location)
- [Full-app promotion (SKOverlay)](#promotion)
- [Data handoff to the full app](#handoff)
- [Correctness checklist](#checklist)
- References: `references/experiences.md`, `references/size-and-capabilities.md`

<a id="architecture"></a>
## Architecture & targets

- An App Clip is a **separate target** inside the full app's Xcode project (File ▸ New ▸ Target ▸ App Clip). It ships **inside** the full app's binary but downloads independently.
- The App Clip bundle ID **must** be the full app's bundle ID plus one suffix segment: full app `com.example.wallet` → clip `com.example.wallet.Clip`.
- One full app has **exactly one** App Clip. One App Clip can serve many *experiences* (many URLs / merchants).
- Reuse code by putting shared logic in a **framework or Swift package** linked into both targets — do not duplicate. Keep the clip's slice minimal (see [budget](#budget)).
- The clip is **ephemeral**: no background execution after the user leaves, data cleared if unused, capped lifetime. Design every flow to complete in one session or resume from the full app.

<a id="entitlements"></a>
## Entitlements & Info.plist

**App Clip target** entitlements (Xcode adds the first two automatically):

```xml
<!-- Clip.entitlements -->
<key>com.apple.developer.on-demand-install-capable</key><true/>   <!-- marks the bundle as an App Clip -->
<key>com.apple.developer.parent-application-identifiers</key>
<array><string>$(AppIdentifierPrefix)com.example.wallet</string></array>  <!-- exactly one parent -->
<key>com.apple.developer.associated-domains</key>
<array><string>appclips:pay.example.com</string></array>          <!-- note the appclips: prefix -->
```

**Full-app target** — you must add this **manually** (Xcode does not):

```xml
<!-- Wallet.entitlements -->
<key>com.apple.developer.associated-appclip-app-identifiers</key>
<array><string>$(AppIdentifierPrefix)com.example.wallet.Clip</string></array>  <!-- exactly one clip -->
```

- Host `apple-app-site-association` (AASA) at `https://pay.example.com/.well-known/apple-app-site-association`, served over HTTPS as `application/json`, with an `appclips` block listing the clip's app ID:

```json
{ "appclips": { "apps": ["ABCDE12345.com.example.wallet.Clip"] } }
```

- The **full app's** AASA still carries its `applinks` block; the same domain drives both.
- **NSAppClip** Info.plist dictionary (App Clip target only) holds ephemeral-permission flags — see [ephemeral](#ephemeral) and [location](#location).

<a id="routing"></a>
## Invocation & routing (NSUserActivity)

Every invocation reaches the clip as an `NSUserActivity` of type **`NSUserActivityTypeBrowsingWeb`** (`browsingWeb`); the invocation URL is `webpageURL`. Route off it — never hardcode a single screen.

```swift
import SwiftUI

@main
struct WalletClip: App {
    @State private var route = ClipRoute.loading

    var body: some Scene {
        WindowGroup {
            ClipRootView(route: route)
                // Cold launch AND warm re-invocation both arrive here.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL else { return }
                    route = ClipRoute(url: url)
                }
        }
    }
}

enum ClipRoute: Equatable {
    case loading, payMerchant(id: String), claimOffer(code: String), unknown

    init(url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { self = .unknown; return }
        let q = { (n: String) in c.queryItems?.first { $0.name == n }?.value }
        switch c.path {
        case "/pay":   self = q("merchant").map { .payMerchant(id: $0) } ?? .unknown
        case "/offer": self = q("code").map { .claimOffer(code: $0) }   ?? .unknown
        default:       self = .unknown
        }
    }
}
```

- **Validate the URL** before acting: only trust the `host`/`path` your AASA declares, treat query values as untrusted input, and never move money purely on URL contents — confirm server-side.
- `webpageURL` may be absent (defensive `guard`). For UIKit apps, implement `scene(_:continue:)` / `application(_:continue:restorationHandler:)` instead of the SwiftUI modifier.
- The clip can also read a richer **`appClipActivationPayload`** off the activity (used for [location confirmation](#location)).

<a id="invocation-methods"></a>
## Invocation methods

| Method | Works with default experience | Needs an Advanced Experience | Notes |
|---|---|---|---|
| Safari **App Clip banner** (top of a matching page) | yes | no | Shows automatically on associated domains once published |
| **Smart App Banner** meta tag | yes | no | Fallback + explicit; see below |
| **Messages** link, **Maps** place card | yes | no | Default link/place association |
| **App Clip Code** (NFC + visual, Apple-designed) | yes (visual) | yes (to bind to a specific URL/location) | Generated in App Store Connect |
| **QR code** | no | yes | Must map to a registered advanced-experience URL |
| **NFC tag** (generic NDEF) | no | yes | Encode the advanced-experience URL with `core-nfc` |
| **Location suggestions** (lock screen, Maps nearby) | no | yes | Requires location-tagged advanced experience |

Smart App Banner (in the page `<head>`) — points at the clip, falls back to the full app:

```html
<meta name="apple-itunes-app"
      content="app-clip-bundle-id=com.example.wallet.Clip, app-id=1234567890">
```

- Prefer an **App Clip Code** for physical merchant placement: it carries the NFC payload *and* a scannable visual in one Apple-verified artifact, so it works with the camera even where NFC is unavailable.
- The Safari banner and Smart App Banner only appear **after the app (with its clip) is published**; domain association is verified by the system.

<a id="experiences"></a>
## App Store Connect experiences

- **Default experience** (required): configured on the app version; auto-generates a default App Clip link + demo URL. Covers Safari, Messages, Maps, and Apple-provided links. One card, one URL pattern.
- **Advanced experiences**: register specific **URL prefixes** to unlock QR, generic NFC, location suggestions, multiple domains, per-location/per-merchant cards, and App Clip Codes. Register a broad prefix for the common case and add narrower prefixes only where a different card/behavior is needed.
- Each experience defines the **App Clip Card** (header image, title, subtitle, action verb: Open/View/Play). This is Apple-hosted UI — not your SwiftUI.
- App Clip Codes are generated per advanced experience in App Store Connect (or via the App Store Connect API `appClipAdvancedExperiences`).
- Detailed default-vs-advanced setup, card fields, and prefix-matching rules in `references/experiences.md`.

<a id="budget"></a>
## Size & capability budget

- The **uncompressed, app-thinned** main bundle of each clip variant must stay under the cap for its **minimum deployment target**:
  - earlier than iOS **16** → **10 MB**
  - min iOS **16+** → **15 MB**
  - min iOS **17+** → **100 MB**, but *only* for clips that support **digital invocations only** (website / Spotlight) and require a network connection — a clip with **any physical** invocation (App Clip Code / QR / NFC) stays at **15 MB**
- Measure the real number: Xcode ▸ Organizer ▸ export with **app thinning**, then read `App Thinning Size Report.txt` per device variant — not the archive size.
- Shrink the clip: strip unused frameworks, use **asset catalogs** (auto-thinned per device), avoid heavyweight dependencies, defer large assets to a network fetch after launch, and split shared code so the clip links only what it needs.
- **Capability limits:** an App Clip **cannot** use background execution, HealthKit, background location, or ask for broad tracking permission; permission prompts are minimized by design (see [ephemeral](#ephemeral)). Full capability list and optimization tactics in `references/size-and-capabilities.md`.

<a id="ephemeral"></a>
## Ephemeral permissions

App Clips avoid permission fatigue: some prompts are replaced by short-lived, invocation-scoped grants declared in the **`NSAppClip`** Info.plist dictionary.

```xml
<key>NSAppClip</key>
<dict>
    <!-- 8-hour ephemeral notification grant, no permission alert -->
    <key>NSAppClipRequestEphemeralUserNotification</key><true/>
    <!-- allow location confirmation without a standard prompt -->
    <key>NSAppClipRequestLocationConfirmation</key><true/>
</dict>
```

- `NSAppClipRequestEphemeralUserNotification`: lets the clip send **local notifications for ~8 hours** after invocation without a notification-permission alert — e.g. "your table's order is ready". Register/schedule via `UNUserNotificationCenter` as usual; the grant is time-boxed and tied to this invocation.
- The full app must still request normal notification permission separately; the ephemeral grant does not carry over.

<a id="location"></a>
## Location confirmation

Instead of a full Core Location permission prompt, a clip invoked from a **visual code or NFC tag** can *confirm* it was acquired at (near) an expected place — precise enough for pay-at-this-store without asking for location access.

```swift
import CoreLocation

func confirmAtStore(_ activity: NSUserActivity, store: CLLocationCoordinate2D) {
    guard let payload = activity.appClipActivationPayload else { return }
    let region = CLCircularRegion(center: store, radius: 100, identifier: "store-42") // radius up to 100 m
    payload.confirmAcquired(in: region) { inRegion, error in
        if let error = error as? APActivationPayloadError {
            switch error.code {
            case .disallowed:  break   // user denied, or invocation not from a visual code / NFC
            case .doesNotMatch: break  // payload isn't the most recent invocation
            @unknown default:  break
            }
            return
        }
        guard inRegion else { return }   // device is NOT within the region
        // Confirmed inside the region (privacy-preserving yes/no — no precise distance) — safe to proceed.
    }
}
```

- Requires `NSAppClipRequestLocationConfirmation` = `true` in the `NSAppClip` dict.
- Region **radius up to 100 m**; the closure returns a **`Bool` (`inRegion`)** — a privacy-preserving yes/no, *never* the precise distance — plus an optional `APActivationPayloadError`.
- Confirmation only works for **physical** invocations (App Clip Code / NFC), not a tapped web link — handle `.disallowed` gracefully.

<a id="promotion"></a>
## Full-app promotion (SKOverlay)

Recommend the full app from inside the clip with `SKOverlay.AppClipConfiguration` — it maps the current clip to its parent app automatically (no app-id needed).

```swift
import StoreKit
import SwiftUI

struct PaymentSuccessView: View {
    var body: some View {
        VStack { /* receipt UI */ }
            .appStoreOverlay(isPresented: .constant(true)) {
                SKOverlay.AppClipConfiguration(position: .bottom)
            }
    }
}
```

- Present it **after** the task succeeds (e.g. on the payment-confirmation screen), never on launch — an overlay before value is delivered reads as a nag and hurts conversion.
- `AppClipConfiguration` can only promote the clip's own parent app. It exposes `campaignToken` / `providerToken` for App Analytics / SKAdNetwork attribution.
- On UIKit use `SKOverlay(configuration:)` + `overlay.present(in: windowScene)`.
- `SKOverlay` is the App Clip promotion API; there is no StoreKit 2 replacement for it as of iOS 26.

<a id="handoff"></a>
## Data handoff to the full app

When the user upgrades to the full app, resume where the clip left off — the full app should not re-ask for what the clip already collected.

- **Shared App Group container** (`group.com.example.wallet`): put the clip on both targets' App Groups; write non-sensitive resume state (cart, selected merchant, draft) to the shared container or `UserDefaults(suiteName:)`. The full app reads it on first launch.
- **CloudKit**: for data that should also sync across devices; both targets share the container (see `cloudkit`).
- **Sign in with Apple**: the credential established in the clip carries to the full app (same Apple ID) — best path for authenticated fintech onboarding (see `authentication`).
- **Keychain caveat (critical):** by design, Keychain items the **App Clip** writes are **not** accessible to the full app. Do **not** rely on a shared Keychain access group to move secrets clip→app. Never place passwords/tokens/PANs in a shared App Group container or shared `UserDefaults` either — those are not a secure store (see `swift-security`). Move *references* / non-secret resume state through the App Group; re-establish secrets in the full app via your normal auth flow.
- Detect the upgrade in the full app (e.g. a flag in the shared container the clip set) and finish the flow, prompting the user to secure credentials properly in the full app.

<a id="checklist"></a>
## Correctness checklist

- [ ] Clip bundle ID = full-app bundle ID + one suffix segment; exactly one parent / one clip per app.
- [ ] Clip has `on-demand-install-capable`, `parent-application-identifiers`, `associated-domains` (`appclips:` prefix); full app has `associated-appclip-app-identifiers` (added manually).
- [ ] AASA served at `/.well-known/apple-app-site-association` over HTTPS with an `appclips` block; full app keeps its `applinks` block.
- [ ] Routing reads `NSUserActivityTypeBrowsingWeb` → `webpageURL`; URL host/path validated; no money moved on URL contents alone (confirm server-side).
- [ ] Handles absent `webpageURL` and unknown routes without crashing.
- [ ] A **default** experience is configured (required); QR / generic NFC / location invocations have matching **advanced** experiences.
- [ ] Thinned uncompressed clip under the cap (15 MB for min iOS 16; 100 MB for min iOS 17 **only** if digital-invocation-only — a physical-invocation clip stays 15 MB) — verified from the App Thinning Size Report, not archive size.
- [ ] No background execution / disallowed capabilities relied on; flow completes in one session or resumes in the full app.
- [ ] `NSAppClip` dict declares only the ephemeral grants actually used; ephemeral notification grant treated as ~8 h and not assumed to carry to the full app.
- [ ] Location confirmation uses `appClipActivationPayload.confirmAcquired(in:)` with radius ≤ 100 m; closure reads the `Bool inRegion` (not a distance); `.disallowed` / `.doesNotMatch` handled; only expected for physical invocations.
- [ ] `SKOverlay.AppClipConfiguration` presented after task success, not on launch.
- [ ] Handoff uses App Group container / CloudKit / Sign in with Apple; secrets are **not** passed via shared Keychain (unreadable by full app) or shared UserDefaults.
