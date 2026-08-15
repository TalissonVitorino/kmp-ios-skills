# PrivacyInfo.xcprivacy — depth reference

Companion to the `app-store-review` skill. Full required-reason code tables,
data-type identifiers, and SDK-signature rules. Everything here is exact-string
territory — copy, don't paraphrase.

## Required-reason API reason codes

Each `NSPrivacyAccessedAPIType` category accepts one or more approved codes under
`NSPrivacyAccessedAPITypeReasons`. Pick the code that matches your *actual* use.
Codes below are the commonly-used entries; **verify the current, complete set
against Apple's "Describing use of required reason API" documentation** before
shipping — Apple adds/edits codes, and using an unlisted code is an upload
rejection. Do not invent a code that "sounds right".

### NSPrivacyAccessedAPICategoryFileTimestamp
APIs: `creationDate`/`modificationDate`, `.contentModificationDateKey`,
`.creationDateKey`, `NSFileCreationDate`, `NSFileModificationDate`, `stat`,
`fstat`, `lstat`, `getattrlist`, `fgetattrlist`, `getattrlistbulk`, `fstatat`.

- `DDA9.1` — display timestamp to the user (files the user chose).
- `C617.1` — access timestamps of files inside the app's own container, an app-group container, or the app's CloudKit container.
- `3B52.1` — access timestamps of files/directories the user specifically granted access to (document picker, drag-and-drop, file provider).
- `0A2A.1` — third-party SDK acting as a "file-provider"–style component, accessing timestamps of files the host app hands it.

### NSPrivacyAccessedAPICategorySystemBootTime
APIs: `systemUptime`, `mach_absolute_time` (when used to derive boot/absolute time).

- `35F9.1` — measure elapsed time between events within the app.
- `8FFB.1` — compute timestamps for events that must be ordered/persisted (e.g. reporting to a server), using an API that reports boot time.

### NSPrivacyAccessedAPICategoryDiskSpace
APIs: `volumeAvailableCapacityKey`, `volumeAvailableCapacityForImportantUsageKey`,
`volumeAvailableCapacityForOpportunisticUsageKey`, `volumeTotalCapacityKey`,
`systemFreeSize`, `systemSize`, `statfs`, `statvfs`, `fstatfs`, `fstatvfs`.

- `85F4.1` — display disk-space information to the user.
- `E174.1` — check whether there is enough space before writing files (and only then write).
- `7D9E.1` — third-party SDK writing on behalf of the host app, checking space first.
- `B728.1` — user-initiated action where the user is shown disk space, including on removable/external media.

### NSPrivacyAccessedAPICategoryActiveKeyboards
APIs: `UITextInputMode.activeInputModes`.

- `3EC4.1` — a custom keyboard *app itself* (Keyboard extension host) determining the active keyboards.
- `54BD.1` — customize the app's UI based on the user's active keyboards (e.g. layout/language adaptation), without sending the info off-device.

### NSPrivacyAccessedAPICategoryUserDefaults
APIs: `UserDefaults` / `NSUserDefaults` read/write.

- `CA92.1` — access user defaults to read/write values readable only by the app itself.
- `1C8F.1` — access user defaults from apps, app extensions, and App Clips that are members of the same App Group.
- `C56D.1` — a third-party SDK accessing user defaults, reading/writing values readable only by the app and the SDKs bundled in it.
- `AC6B.1` — access user defaults to read the `com.apple.configuration.managed` or `com.apple.feedback.managed` key (managed-app configuration / MDM).

> The pair {category, code} must exactly match Apple's table. If your only
> UserDefaults use is your own app's settings, `CA92.1` is almost always right;
> shared App-Group defaults need `1C8F.1`.

## Data-type identifiers (NSPrivacyCollectedDataType)

Values used inside each `NSPrivacyCollectedDataTypes` entry. Fintech apps most
often need the ones flagged ★. Each entry also carries `...Linked` (Bool),
`...Tracking` (Bool), and `...Purposes` (array).

- Contact info: `NSPrivacyCollectedDataTypeName` ★, `...EmailAddress` ★, `...PhoneNumber` ★, `...PhysicalAddress` ★, `...OtherUserContactInfo`
- Financial: `NSPrivacyCollectedDataTypePaymentInfo` ★, `...CreditInfo` ★, `...OtherFinancialInfo` ★
- Identifiers: `NSPrivacyCollectedDataTypeUserID` ★, `...DeviceID` ★
- Usage/diagnostics: `NSPrivacyCollectedDataTypeProductInteraction`, `...AdvertisingData`, `...CrashData` ★, `...PerformanceData` ★, `...OtherDiagnosticData`
- Location: `NSPrivacyCollectedDataTypePreciseLocation`, `...CoarseLocation`
- Sensitive/other: `NSPrivacyCollectedDataTypeSensitiveInfo`, `...Contacts`, `...Photos`, `...Audio`, `...GameplayContent`, `...CustomerSupport`, `...OtherDataTypes`, `...Health`, `...Fitness`, `...BrowsingHistory`, `...SearchHistory`, `...EmailsOrTextMessages`, `...OtherUserContent`, `...PurchaseHistory`

### Purposes (NSPrivacyCollectedDataTypePurposes)
- `NSPrivacyCollectedDataTypePurposeAppFunctionality`
- `...Analytics`
- `...ProductPersonalization`
- `...ThirdPartyAdvertising`
- `...DeveloperAdvertising`
- `...Other`

## SDK-signature & manifest aggregation rules

- Apple maintains a list of **commonly-used SDKs** that, when included, must ship a privacy manifest **and** a valid code signature. Adopting a new major version of such an SDK without its manifest/signature is an upload rejection.
- Xcode's **Privacy Report** (Product → Archive → Generate Privacy Report) aggregates the app's manifest with every bundled framework/SDK manifest into the PDF you can attach to a submission. Generate and read it before uploading.
- A framework/extension's manifest lives inside *that* bundle, not the app's. A required-reason API called from a widget or notification-service extension needs the declaration in the extension target.

## Reconciliation checklist

- [ ] Manifest exists in app + every extension/framework target.
- [ ] Each required-reason API in code and in each SDK has a category + verified code.
- [ ] `NSPrivacyCollectedDataTypes` lists every type the app *and its SDKs* collect.
- [ ] `...Tracking = true` on any type ⇒ ATT is implemented and the type also shows "tracking" in the App Store Connect label.
- [ ] `NSPrivacyTrackingDomains` covers all tracking hosts; none of them are contacted before ATT authorization.
- [ ] Privacy Report generated and matches the App Store Connect privacy label.
