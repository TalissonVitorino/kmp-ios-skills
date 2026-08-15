---
name: core-nfc
description: "Read and write NFC tags on iOS/iPadOS with CoreNFC — NFCNDEFReaderSession (NDEF read + writeNDEF via NFCNDEFTag: queryNDEFStatus/readNDEF/writeNDEF), NFCTagReaderSession for ISO7816/ISO15693/FeliCa/MIFARE through the NFCTag enum (.iso7816/.iso15693/.feliCa/.miFare) and PollingOption (.iso14443/.iso15693/.iso18092), NFCNDEFMessage/NFCNDEFPayload (wellKnownTypeURIPayload / wellKnownTypeTextPayload), session/delegate lifecycle + NFCReaderError, the com.apple.developer.nfc.readersession.formats entitlement + NFCReaderUsageDescription, and background tag reading (URI launch, App Clips). Use when scanning or writing NFC tags, sending APDUs, or wiring NFC entitlements. Not for Apple Pay/Wallet passes (see passkit) or card emulation. For KMP boundary see expect-actual / kmp-ios-integration; App Clip NFC invocation see app-clips; securing tag payloads see swift-security; async connect patterns see swift-concurrency."
---

# CoreNFC (iOS / iPadOS)

Detect, read, and write NFC tags on iPhone (7 and later; background reading iPhone XS
and later). Two session types, both built on `NFCReaderSession`:

- **`NFCNDEFReaderSession`** — high-level NDEF read/write. Use for NFC Forum Type 1–5 tags carrying URLs, text, vCards. Simplest path.
- **`NFCTagReaderSession`** — low-level access to `.iso7816`, `.iso15693`, `.feliCa`, `.miFare` tags for raw commands/APDUs (transit, access cards, custom protocols).

- **Not CoreNFC:** Apple Pay / Wallet passes are on the Secure Element and unreadable by third-party apps — see `passkit`. Host Card Emulation is a *separate* entitlement + `CardSession` API, out of scope here.
- **KMP:** CoreNFC is iOS-only; expose a `commonMain` interface and bind a Swift `actual` (see `expect-actual`, `kmp-ios-integration`). Keep tag payloads/secrets off shared plaintext — route sensitive material through `swift-security`.

## Contents

- [Setup: entitlement + Info.plist](#setup)
- [NDEF reading](#ndef-read)
- [NDEF writing](#ndef-write)
- [Building NDEF payloads](#payloads)
- [Tag reader session (raw tags)](#tag-session)
- [Session lifecycle & errors](#lifecycle)
- [Background tag reading](#background)
- [Correctness checklist](#checklist)
- References: `references/tag-types.md`, `references/background-and-entitlements.md`

<a id="setup"></a>
## Setup: entitlement + Info.plist

Both are mandatory — a missing usage string crashes on `begin()`; a missing entitlement fails session creation.

- **Entitlement** `com.apple.developer.nfc.readersession.formats` (add the *Near Field Communication Tag Reading* capability in Xcode). Array of strings:
  - `"NDEF"` — enables `NFCNDEFReaderSession`.
  - `"TAG"` — enables `NFCTagReaderSession` (raw ISO7816/ISO15693/FeliCa/MIFARE). Include both if you use both session types.
- **Info.plist** `NFCReaderUsageDescription` (String) — required, shown in the scan sheet. Explain why you scan.
- **Info.plist** application-identifier lists (needed to *detect* certain tags):
  - `com.apple.developer.nfc.readersession.iso7816.select-identifiers` — array of AIDs (hex strings) for ISO7816 tags.
  - `com.apple.developer.nfc.readersession.felica.systemcodes` — array of FeliCa system codes.
- **Availability gate** — check before offering NFC UI:

```swift
import CoreNFC

guard NFCNDEFReaderSession.readingAvailable else {
    // No NFC hardware, unsupported device, or Simulator — hide the feature.
    return
}
```

- CoreNFC does **not** run in the Simulator; test on a physical device.

<a id="ndef-read"></a>
## NDEF reading

Hold a strong reference to the session for its lifetime (delegate is held weakly; a deallocated session ends the scan).

```swift
import CoreNFC

final class NDEFReader: NSObject, NFCNDEFReaderSessionDelegate {
    private var session: NFCNDEFReaderSession?

    func scan() {
        guard NFCNDEFReaderSession.readingAvailable else { return }
        // invalidateAfterFirstRead: true ends the session as soon as one tag is read.
        session = NFCNDEFReaderSession(delegate: self, queue: nil,
                                       invalidateAfterFirstRead: true)
        session?.alertMessage = "Hold your iPhone near the tag."
        session?.begin()
    }

    // Simple path: system reads the NDEF message for you.
    func readerSession(_ session: NFCNDEFReaderSession,
                       didDetectNDEFs messages: [NFCNDEFMessage]) {
        for record in messages.flatMap(\.records) {
            if let url = record.wellKnownTypeURIPayload() {
                print("URL:", url)
            } else {
                let (text, locale) = record.wellKnownTypeTextPayload()   // (String?, Locale?)
                if let text { print("Text:", text, locale?.identifier ?? "") }
            }
        }
        // Session invalidates itself when invalidateAfterFirstRead is true.
    }

    func readerSession(_ session: NFCNDEFReaderSession,
                       didInvalidateWithError error: Error) {
        self.session = nil   // release; inspect error (see lifecycle section)
    }
}
```

- `didDetectNDEFs` gives you decoded messages with **no tag connection** — read-only, no interaction possible.
- Implementing the optional `didDetect(_:)` (tags, below) **suppresses** `didDetectNDEFs` — the two are mutually exclusive. Use the tag form whenever you need to write, re-read, or query status.
- `readerSessionDidBecomeActive(_:)` (optional) fires when polling actually starts.

<a id="ndef-write"></a>
## NDEF writing

To write, take the tag-level path: detect `NFCNDEFTag`, connect, query status, then write. Set `invalidateAfterFirstRead: false` so the session stays open to connect.

```swift
func readerSession(_ session: NFCNDEFReaderSession,
                   didDetect tags: [any NFCNDEFTag]) {
    guard let tag = tags.first else { return }
    if tags.count > 1 {
        session.alertMessage = "More than one tag detected. Present one tag."
        // restartPolling after a short delay, or just return.
        return
    }

    session.connect(to: tag) { error in
        if let error { session.invalidate(errorMessage: error.localizedDescription); return }

        tag.queryNDEFStatus { status, capacity, error in
            if let error { session.invalidate(errorMessage: error.localizedDescription); return }

            switch status {
            case .notSupported:
                session.invalidate(errorMessage: "Tag is not NDEF-formatted.")
            case .readOnly:
                session.invalidate(errorMessage: "Tag is read-only.")
            case .readWrite:
                let message = NFCNDEFMessage(records: [
                    NFCNDEFPayload.wellKnownTypeURIPayload(url: URL(string: "https://example.com")!)!
                ])
                guard message.length <= capacity else {
                    session.invalidate(errorMessage: "Tag too small (\(capacity) bytes).")
                    return
                }
                tag.writeNDEF(message) { error in
                    if let error {
                        session.invalidate(errorMessage: "Write failed: \(error.localizedDescription)")
                    } else {
                        session.alertMessage = "Wrote tag."
                        session.invalidate()
                    }
                }
            @unknown default:
                session.invalidate(errorMessage: "Unknown tag status.")
            }
        }
    }
}
```

- `NFCNDEFStatus`: `.notSupported`, `.readOnly`, `.readWrite`. The second `queryNDEFStatus` value is the **capacity in bytes** — check `message.length` against it before writing.
- `readNDEF(completionHandler:)` re-reads a connected tag; `writeLock(completionHandler:)` makes a tag **permanently read-only** — irreversible, gate behind explicit user intent.
- All tag callbacks run on the session's queue (a private serial queue when `queue: nil`) — hop to `@MainActor` for UI.

<a id="payloads"></a>
## Building NDEF payloads

`NFCNDEFMessage` is an ordered list of `NFCNDEFPayload` records. Factory methods produce correctly-encoded Well Known Type records (return `Self?` — force-unwrap only known-valid inputs, else guard):

```swift
// URI record (RTD:U) — the common "tap to open" payload.
let uri = NFCNDEFPayload.wellKnownTypeURIPayload(url: URL(string: "https://example.com")!)
// URIs with characters outside 7-bit ASCII:
let uri2 = NFCNDEFPayload.wellKnownTypeURIPayload(string: "myapp://ação?x=1")

// Text record (RTD:T) — stores the IANA language code from the locale.
let text = NFCNDEFPayload.wellKnownTypeTextPayload(string: "Hello", locale: Locale(identifier: "en"))

// Fully custom record (e.g. MIME / external type):
let custom = NFCNDEFPayload(
    format: .media,                          // NFCTypeNameFormat
    type: Data("application/json".utf8),
    identifier: Data(),
    payload: Data(#"{"id":1}"#.utf8))

let message = NFCNDEFMessage(records: [uri!, text!, custom])
```

- Decode on read with the parameterless `record.wellKnownTypeURIPayload() -> URL?` and `record.wellKnownTypeTextPayload() -> (String?, Locale?)`.
- `NFCTypeNameFormat`: `.empty`, `.nfcWellKnown`, `.media`, `.absoluteURI`, `.nfcExternal`, `.unknown`, `.unchanged`.

<a id="tag-session"></a>
## Tag reader session (raw tags)

For transit cards, contactless smart cards, industrial ISO15693 tags — anything needing native commands rather than NDEF. Requires the `"TAG"` entitlement format.

```swift
final class TagReader: NSObject, NFCTagReaderSessionDelegate {
    private var session: NFCTagReaderSession?

    func scan() {
        // pollingOption selects which tag technologies to poll for.
        session = NFCTagReaderSession(pollingOption: [.iso14443, .iso15693, .iso18092],
                                      delegate: self, queue: nil)
        session?.alertMessage = "Hold your iPhone near the card."
        session?.begin()
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let tag = tags.first else { return }
        session.connect(to: tag) { error in
            if let error { session.invalidate(errorMessage: error.localizedDescription); return }

            switch tag {
            case let .iso7816(t):   Task { await self.readISO7816(t, session) }
            case let .iso15693(t):  self.readISO15693(t, session)
            case let .feliCa(t):    self.readFeliCa(t, session)
            case let .miFare(t):    self.readMiFare(t, session)
            @unknown default:       session.invalidate(errorMessage: "Unsupported tag.")
            }
        }
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}
    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        self.session = nil
    }

    private func readISO7816(_ tag: NFCISO7816Tag, _ session: NFCTagReaderSession) async {
        let apdu = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xB0,
                                  p1Parameter: 0x00, p2Parameter: 0x00,
                                  data: Data(), expectedResponseLength: 256)
        do {
            let response = try await tag.sendCommand(apdu: apdu)   // NFCISO7816ResponseAPDU
            // response.payload, response.statusWord1 (0x90), response.statusWord2 (0x00) = success
            session.invalidate()
        } catch {
            session.invalidate(errorMessage: error.localizedDescription)
        }
    }
    // readISO15693 / readFeliCa / readMiFare in references/tag-types.md
}
```

- **`PollingOption`** (OptionSet): `.iso14443` (ISO7816 + MIFARE, type A/B), `.iso15693`, `.iso18092` (FeliCa), plus `.pace`. Combine as `[.iso14443, .iso15693]`.
- **`NFCTag` enum** cases and their tag protocols: `.iso7816(NFCISO7816Tag)`, `.iso15693(NFCISO15693Tag)`, `.feliCa(NFCFeliCaTag)`, `.miFare(NFCMiFareTag)`. Each protocol also conforms to `NFCNDEFTag`, so you can still `queryNDEFStatus`/`readNDEF`/`writeNDEF` after connecting.
- `connect(to:)` has `async throws` and completion-handler forms. `restartPolling()` (no arguments) resumes detection after handling one tag; previously returned tags become invalid.
- Per-tag command sets (ISO15693 `readSingleBlock`/`extendedWriteSingleBlock`, FeliCa `polling`/`requestService`, MIFARE `sendMiFareCommand`, ISO7816 APDUs) are in `references/tag-types.md`.

<a id="lifecycle"></a>
## Session lifecycle & errors

- One session at a time system-wide. `begin()` shows the scan sheet; `invalidate()` / `invalidate(errorMessage:)` ends it (an error message turns the sheet red).
- Update `alertMessage` mid-session to guide the user ("Tag detected, hold still").
- A session is **single-use** — create a fresh one to scan again; a session auto-invalidates after ~60s or on user cancel.
- `didInvalidateWithError` is **required** and always the terminal callback. Bridge the error to `NFCReaderError`:

```swift
func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
    if let e = error as? NFCReaderError {
        switch e.code {
        case .readerSessionInvalidationErrorUserCanceled:            break // user tapped Cancel
        case .readerSessionInvalidationErrorSessionTimeout:          retry()
        case .readerSessionInvalidationErrorFirstNDEFTagRead:        break // normal end w/ invalidateAfterFirstRead
        case .readerSessionInvalidationErrorSessionTerminatedUnexpectedly,
             .readerSessionInvalidationErrorSystemIsBusy:            showTransientError()
        default:                                                     showError(e)
        }
    }
    self.session = nil
}
```

- Common `NFCReaderError.Code`: `...UserCanceled`, `...SessionTimeout`, `...SessionTerminatedUnexpectedly`, `...SystemIsBusy`, `...FirstNDEFTagRead`; write-path: `ndefReaderSessionErrorTagNotWritable`, `ndefReaderSessionErrorTagUpdateFailure`, `ndefReaderSessionErrorTagSizeTooSmall`, `ndefReaderSessionErrorZeroLengthMessage`; transceive: `readerTransceiveErrorTagConnectionLost`, `readerTransceiveErrorRetryExceeded`.
- Treat `...UserCanceled` as a normal outcome, not a failure to surface.

<a id="background"></a>
## Background tag reading

On iPhone XS and later, iOS reads NDEF tags **without an app session** and launches your app — no scan sheet, tap-and-go (App Clips, posters, deep links).

- Requires the `"NDEF"` (or `"TAG"`) entitlement format. Only **NFC Forum well-known URI records** whose scheme your app claims trigger a launch (via Universal Links / custom scheme). Non-URI tags do nothing in the background.
- Delivery is through `NSUserActivity` of type `NSUserActivityTypeBrowsingWeb`; the tag's message is on `userActivity.ndefMessagePayload`:

```swift
func application(_ application: UIApplication,
                 continue userActivity: NSUserActivity,
                 restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
    guard userActivity.activityType == NSUserActivityTypeBrowsingWeb else { return false }
    let message = userActivity.ndefMessagePayload
    guard let first = message.records.first, first.typeNameFormat != .empty else { return false }
    // Route based on the URI record.
    return true
}
```

- SwiftUI: handle with `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in … }` (URL records also arrive via `.onOpenURL`).
- App Clip NFC invocation (App Clip Codes, tag URLs) is covered in `app-clips`; entitlement/plist detail and the App Clip URL flow are in `references/background-and-entitlements.md`.

<a id="checklist"></a>
## Correctness checklist

- [ ] `com.apple.developer.nfc.readersession.formats` includes `"NDEF"` and/or `"TAG"` matching the session types you create.
- [ ] `NFCReaderUsageDescription` set in Info.plist (missing → crash on `begin()`).
- [ ] ISO7816 AIDs / FeliCa system codes listed in Info.plist when detecting those tags.
- [ ] `NFCNDEFReaderSession.readingAvailable` / `NFCTagReaderSession.readingAvailable` checked before showing NFC UI; feature hidden in Simulator.
- [ ] Session stored in a strong property for its whole lifetime; released in `didInvalidateWithError`.
- [ ] Use `didDetect` (tag) path — not `didDetectNDEFs` — whenever writing, re-reading, or querying status; the two are mutually exclusive.
- [ ] Before writing: `connect` → `queryNDEFStatus`, handle `.notSupported`/`.readOnly`, and check `message.length <= capacity`.
- [ ] `writeLock` used only with explicit user intent — it is permanent.
- [ ] `NFCReaderError` mapped; `...UserCanceled` treated as normal, not surfaced as an error.
- [ ] Delegate callbacks hopped to `@MainActor` before touching UI.
- [ ] Background reading relies on URI records + claimed schemes; app handles `NSUserActivityTypeBrowsingWeb` with `ndefMessagePayload`.
- [ ] Sensitive tag payloads not persisted in plaintext (see `swift-security`); shared KMP code holds no NFC secrets.
