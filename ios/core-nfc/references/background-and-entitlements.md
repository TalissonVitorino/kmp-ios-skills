# Entitlements, Info.plist & background tag reading

## Capability setup

Add **Near Field Communication Tag Reading** in Signing & Capabilities. Xcode writes
the entitlement; you edit its formats array.

`YourApp.entitlements`:

```xml
<key>com.apple.developer.nfc.readersession.formats</key>
<array>
    <string>NDEF</string>   <!-- NFCNDEFReaderSession -->
    <string>TAG</string>    <!-- NFCTagReaderSession (raw ISO7816/ISO15693/FeliCa/MIFARE) -->
</array>
```

`Info.plist`:

```xml
<key>NFCReaderUsageDescription</key>
<string>Scan a tag to link your card.</string>

<!-- Needed only when detecting these tag families: -->
<key>com.apple.developer.nfc.readersession.iso7816.select-identifiers</key>
<array>
    <string>A0000000041010</string>   <!-- AIDs, hex -->
</array>
<key>com.apple.developer.nfc.readersession.felica.systemcodes</key>
<array>
    <string>0003</string>             <!-- FeliCa system codes, hex -->
</array>
```

- Missing `NFCReaderUsageDescription` → the app **crashes** the moment you call `begin()`.
- Missing/wrong entitlement format → session initializer fails or `begin()` never activates.
- These AID / system-code lists are configured **only** in Info.plist — there is no per-session override API. The system polls for exactly the identifiers declared there.

## Background tag reading

iPhone XS and later read background NDEF tags with **no active session and no scan sheet**
— iOS reads the tag and launches/foregrounds your app.

Requirements and constraints:

- The `"NDEF"` format entitlement is present.
- The tag's first record is a **Well Known Type URI** whose destination your app claims:
  - a Universal Link (`applinks:` associated domain), or
  - a custom URL scheme your app registers.
- Only URI records launch the app. Text/MIME/other records are ignored in the background — use a foreground `NFCNDEFReaderSession` for those.
- The user must tap the on-screen NFC banner iOS presents (system-gated; you cannot auto-open).

### Handling the launch

UIKit app delegate / scene delegate:

```swift
func application(_ application: UIApplication,
                 continue userActivity: NSUserActivity,
                 restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
    guard userActivity.activityType == NSUserActivityTypeBrowsingWeb else { return false }

    // Full NDEF message from the background-read tag:
    let message = userActivity.ndefMessagePayload
    guard let record = message.records.first, record.typeNameFormat != .empty else { return false }

    if let url = record.wellKnownTypeURIPayload() {
        route(to: url)
    }
    // Or use userActivity.webpageURL for the resolved Universal Link.
    return true
}
```

SwiftUI:

```swift
WindowGroup {
    ContentView()
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            let message = activity.ndefMessagePayload
            // route based on message.records / activity.webpageURL
        }
        .onOpenURL { url in route(to: url) }   // custom-scheme URI records
}
```

- `ndefMessagePayload` is non-optional on the activity (empty message when absent) — validate `records` before use.
- `webpageURL` gives the resolved Universal Link when the tag encoded an `applinks` URL.

## App Clips

App Clip Codes embed an NFC tag whose URL is your App Clip invocation URL. The launch is
handled through `NSUserActivity` App Clip routing rather than `ndefMessagePayload`. See the
`app-clips` skill for invocation-URL configuration, App Store Connect experiences, and
full-app handoff.

## Related

- `passkit` — Apple Pay / Wallet (Secure Element; not reachable via CoreNFC).
- `swift-security` — protect anything read off a tag before persisting.
- `swift-concurrency` — `connect(to:)` / `sendCommand(apdu:)` `async` forms and `@MainActor` hops.
