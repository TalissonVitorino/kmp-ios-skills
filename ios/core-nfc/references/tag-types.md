# Raw tag command sets (NFCTagReaderSession)

Detail for the four `NFCTag` cases. All commands run after `session.connect(to: tag)`
succeeds. Completion handlers fire on the session queue — hop to `@MainActor` for UI.
Grounded in Apple's CoreNFC framework docs.

## ISO7816 — `NFCISO7816Tag`

Contactless smart cards (payment EMV-style layouts, ID cards, transit). Communicate via APDUs.

```swift
// Build an APDU explicitly…
let apdu = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xA4,   // SELECT
                          p1Parameter: 0x04, p2Parameter: 0x00,
                          data: aidData, expectedResponseLength: 256)
// …or from a raw command Data:  NFCISO7816APDU(data: rawAPDU)

// async/await:
let resp = try await tag.sendCommand(apdu: apdu)   // NFCISO7816ResponseAPDU
let ok = resp.statusWord1 == 0x90 && resp.statusWord2 == 0x00
let body = resp.payload

// completion-handler form:
tag.sendCommand(apdu: apdu) { payload, sw1, sw2, error in ... }
```

- Useful properties: `tag.identifier`, `tag.historicalBytes`, `tag.applicationData`, `tag.initialSelectedAID`.
- List selectable AIDs in `com.apple.developer.nfc.readersession.iso7816.select-identifiers` (Info.plist) so the tag is *detected*.

## ISO15693 — `NFCISO15693Tag`

NFC Forum Type 5 / vicinity tags (ICODE, ST25, industrial labels). Block-oriented.

```swift
// Read one block (Type 5 read single block, command 0x20):
tag.readSingleBlock(requestFlags: [.highDataRate], blockNumber: 0) { data, error in ... }

// Read several:
tag.readMultipleBlocks(requestFlags: [.highDataRate],
                       blockRange: NSRange(location: 0, length: 4)) { blocks, error in ... }

// Write (0x21) and the extended (>256-block) 0x30/0x31 variants:
tag.writeSingleBlock(requestFlags: [.highDataRate], blockNumber: 0, dataBlock: data) { error in ... }
tag.extendedReadSingleBlock(requestFlags: [.highDataRate], blockNumber: 0x0100) { data, error in ... }
tag.extendedWriteSingleBlock(requestFlags: [.highDataRate], blockNumber: 0x0100, dataBlock: data) { error in ... }
```

- `NFCISO15693RequestFlag`: `.address`, `.highDataRate`, `.dualSubCarriers`, `.select`, `.protocolExtension`, `.option`. Use `.address` when targeting a specific tag UID; `.highDataRate` is the common default.
- Other commands: `getSystemInfo`, `lockBlock`, `stayQuiet`, `select`, `resetToReady`, plus custom-command passthrough.
- `tag.identifier` (UID), `tag.icManufacturerCode`.

## FeliCa — `NFCFeliCaTag`

Japanese transit/e-money (Suica, Edy). Requires system codes in Info.plist
(`com.apple.developer.nfc.readersession.felica.systemcodes`) to detect.

```swift
tag.polling(systemCode: Data([0x00, 0x03]),
            requestCode: .systemCode,
            timeSlot: .max1) { idm, pmm, error in ... }

tag.requestService(nodeCodeList: [Data([0x0F, 0x09])]) { nodes, error in ... }

tag.readWithoutEncryption(serviceCodeList: [serviceCode],
                          blockList: [block]) { statusFlag1, statusFlag2, blocks, error in ... }
```

- `NFCFeliCaPollingRequestCode`: `.noRequest`, `.systemCode`, `.communicationPerformance`.
- `NFCFeliCaPollingTimeSlot`: `.max1`, `.max2`, `.max4`, `.max8`, `.max16`.
- Identifiers: `tag.currentSystemCode`, `tag.currentIDm`.

## MIFARE — `NFCMiFareTag`

MIFARE Ultralight / Classic / DESFire (`tag.mifareFamily`).

```swift
// Native MIFARE command packet:
tag.sendMiFareCommand(commandPacket: Data([0x30, 0x04])) { response, error in ... }  // READ page 4

// DESFire / ISO7816-capable MIFARE — wrap as APDU:
let resp = try await tag.sendMiFareISO7816Command(apdu)   // NFCISO7816ResponseAPDU
```

- `tag.identifier` (UID), `tag.historicalBytes`, `tag.mifareFamily` (`.unknown`/`.ultralight`/`.plus`/`.desfire`).

## Notes

- Every raw-tag protocol also conforms to `NFCNDEFTag`, so after connecting you may fall back to `queryNDEFStatus` / `readNDEF` / `writeNDEF` if the card happens to be NDEF-formatted.
- Keep the tag in the field: connection drops surface as `readerTransceiveErrorTagConnectionLost`. Prompt the user to hold still via `session.alertMessage`.
- After finishing one tag, either `session.invalidate()` or `session.restartPolling()` (no arguments) to look for the next; previously detected tags become invalid.
