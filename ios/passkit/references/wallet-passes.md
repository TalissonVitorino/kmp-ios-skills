# Wallet passes — depth

Companion to `passkit/SKILL.md`. The app **presents & adds** passes; a **server**
creates & signs them. All `import PassKit`.

## Where things run

| Step | Where | Why |
|---|---|---|
| Design `pass.json`, images, styles | server / build tooling | pass content + layout |
| Sign into a `.pkpass` bundle | **server** | needs the Pass Type ID cert + private key |
| Download `.pkpass` bytes | app or Safari/Mail | delivery |
| Add to Wallet | app (`PKAddPassesViewController` / `AddPassToWalletButton`) or system | user consent |
| Push updates | **server** (APNs) + PassKit web service | keep passes fresh |

Never bundle the signing certificate or key in the app — anyone could mint passes for your Pass Type ID.

## `.pkpass` bundle (server-produced)

A `.pkpass` is a ZIP of:
- `pass.json` — required keys: `formatVersion` (1), `passTypeIdentifier`, `serialNumber`, `teamIdentifier`, `organizationName`, `description`, and one style dict (`boardingPass`, `coupon`, `eventTicket`, `storeCard`, or `generic`).
- image assets: `icon.png`/`icon@2x.png` (required), optional `logo`, `strip`, `thumbnail`, `background`.
- `manifest.json` — SHA-1 of every file.
- `signature` — PKCS#7 detached signature of `manifest.json` with your Pass Type ID cert + the Apple WWDR intermediate.

Barcodes go in `pass.json` under `barcodes` (`format`: `PKBarcodeFormatQR`/`PKBarcodeFormatPDF417`/`PKBarcodeFormatAztec`/`PKBarcodeFormatCode128`).

## Presenting from the app

```swift
// From downloaded bytes.
let pass = try PKPass(data: pkpassData)

let library = PKPassLibrary()
if library.containsPass(pass) {
    // Already added — offer "View in Wallet" via pass.passURL instead of re-adding.
} else if PKAddPassesViewController.canAddPasses() {     // false on iPad/unsupported
    let vc = PKAddPassesViewController(pass: pass)!
    vc.delegate = self
    present(vc, animated: true)
}
```

```swift
extension MyVC: PKAddPassesViewControllerDelegate {
    func addPassesViewControllerDidFinish(_ controller: PKAddPassesViewController) {
        controller.dismiss(animated: true)
        // Re-query library.containsPass(pass) to learn whether the user actually added it.
    }
}
```

SwiftUI equivalent:

```swift
AddPassToWalletButton(pass: pass) { error in
    if let error { /* log + retry */ }
}
.addPassToWalletButtonStyle(.automatic)
.frame(width: 250, height: 44)
```

## PKPassLibrary API

- `PKPassLibrary.isPassLibraryAvailable()` — gate all use.
- `passes()` / `passes(of: PKPassType)` — your entitled passes (`.barcode`, `.payment`, `.secureElement`).
- `pass(withPassTypeIdentifier:serialNumber:)` — fetch one.
- `containsPass(_:)` — dedupe before offering "Add".
- `addPasses(_:withCompletionHandler:)` — programmatic add of `[PKPass]`; still shows the system UI. The completion `PKPassLibraryAddPassesStatus` is `.didAddPasses` / `.shouldReviewPasses` / `.didCancelAddPasses`.
- `replacePass(with:)` — swap an updated pass in place (same pass type + serial).
- `removePass(_:)` — requires entitlement scoping to that pass type.
- Reading requires the `com.apple.developer.pass-type-identifiers` entitlement listing your Pass Type IDs.

Observe `Notification.Name.PKPassLibraryDidChange` to react when passes are added/removed/updated out from under you.

## Keeping passes updated (PassKit web service)

`pass.json` includes `webServiceURL` + `authenticationToken`; Wallet then talks to your server:
1. **Register:** `POST …/v1/devices/{deviceId}/registrations/{passTypeId}/{serial}` with the APNs push token — store it.
2. **Notify:** when data changes, send an empty APNs push to that token; Wallet responds by asking for changed serials.
3. **List changed:** `GET …/v1/devices/{deviceId}/registrations/{passTypeId}?passesUpdatedSince=…`.
4. **Fetch:** `GET …/v1/passes/{passTypeId}/{serial}` returns the new signed `.pkpass` (honor `If-Modified-Since`).
5. **Unregister:** `DELETE …` when the user deletes the pass.

All requests carry `Authorization: ApplePass <authenticationToken>` — validate it server-side.

## Add-to-Wallet from the web

Serve the signed file with `Content-Type: application/vnd.apple.pkpass`. A tap in Safari/Mail opens the Add sheet with no app involved — the simplest distribution path for loyalty cards, tickets, and boarding passes.

## Gotchas

- `PKAddPassesViewController(pass:)` / `(passes:)` are **failable** — guard the optional.
- `canAddPasses()` is false on some devices/contexts; check before presenting.
- A pass fails to add silently if `passTypeIdentifier`/`teamIdentifier` in `pass.json` don't match the signing certificate.
- `addPasses` still requires user confirmation — you can't add passes silently.
