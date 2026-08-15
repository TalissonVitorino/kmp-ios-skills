---
name: app-store-review
description: "Audit an iOS app's App Store submission readiness and rejection risk for a fintech app — App Review Guidelines domains (Safety/Performance/Business/Design/Legal), PrivacyInfo.xcprivacy (NSPrivacyAccessedAPITypes required-reason APIs, NSPrivacyTrackingDomains, NSPrivacyCollectedDataTypes), App Privacy nutrition labels, App Tracking Transparency (ATTrackingManager, NSUserTrackingUsageDescription), StoreKit / Guideline 3.1.1 payment-rule compliance, metadata/screenshots/age rating, entitlements + capabilities, export compliance (ITSAppUsesNonExemptEncryption), and TestFlight. Use when preparing a submission, responding to a rejection, reconciling privacy-label vs manifest evidence, or separating upload blockers from post-review cleanup. Pairs with `swift-security` (encryption/ATS), `storekit` (IAP), `authentication` (Sign in with Apple), `analytics-patterns` (tracking/data collection), `widgetkit`/`activitykit` (extension privacy manifests); Android counterpart is `play-policy-insights`."
---

# App Store Review (iOS 26)

Pre-submission audit for a fintech iOS app: guideline exposure, the privacy
manifest, privacy labels, ATT, payment rules, export compliance, and the App
Store Connect metadata gate. Grounded in the App Review Guidelines and Apple's
`PrivacyInfo.xcprivacy` / App Store Connect documentation.

- **Not covered here:** how to *implement* IAP (`storekit`), Apple Pay (`passkit`), Sign in with Apple / passkeys (`authentication`), Keychain/CryptoKit/ATS (`swift-security`), Wallet financial data (`financekit`). This skill audits their *reviewability*.
- **Android counterpart:** `play-policy-insights` (Data safety form, permissions, policy).

## Contents

- [How to use / triage model](#triage)
- [Guideline domains & top fintech triggers](#guidelines)
- [PrivacyInfo.xcprivacy](#privacy-manifest)
- [App Privacy nutrition labels](#privacy-labels)
- [App Tracking Transparency](#att)
- [StoreKit / payment-rule compliance](#payments)
- [Export compliance](#export)
- [Entitlements & capabilities](#entitlements)
- [Metadata / screenshots / age rating](#metadata)
- [TestFlight](#testflight)
- [Upload blockers vs post-review cleanup](#blockers)
- [Correctness checklist](#checklist)
- References: `references/privacy-manifest.md`, `references/rejection-playbook.md`

<a id="triage"></a>
## How to use / triage model

Sort every finding into one of three buckets — they fail at different gates:

1. **Upload blockers** — the binary or App Store Connect record is rejected at *upload/validation* time, before a human looks. Automated. Fix these first (see [blockers](#blockers)).
2. **Metadata gate** — App Store Connect refuses to submit until required fields are set (privacy labels, age rating, export compliance answer, encryption docs, screenshots for required sizes).
3. **Post-review cleanup** — passes upload but risks *human* rejection under a guideline. Ranked by likelihood, not certainty. Document your reasoning so a resubmission note can pre-empt it.

Audit order: run through Guidelines for exposure → verify the privacy manifest exists and matches actual API/SDK use → reconcile it against the privacy labels → confirm ATT/payment/export/entitlement gates → check metadata completeness.

<a id="guidelines"></a>
## Guideline domains & top fintech triggers

The App Review Guidelines have five sections. Map each finding to a numbered guideline so a reviewer note can cite it.

| # | Domain | Fintech-relevant hotspots |
|---|---|---|
| 1 | **Safety** | 1.4 physical harm / financial-loss risk; 1.5 developer identity & support URL; UGC moderation if any social feature |
| 2 | **Performance** | 2.1 completeness (no placeholder content, working demo/sandbox account); 2.3 accurate metadata; 2.5 use public APIs only, no hidden features |
| 3 | **Business** | **3.1.1 In-App Purchase** — digital goods must use IAP; 3.1.3 "reader"/external-account nuances; 3.2 acceptable business model |
| 4 | **Design** | 4.0 quality; 4.2 minimum functionality (not a repackaged website); **4.8 Sign in with Apple** parity; 4.7 mini-apps/third-party code |
| 5 | **Legal** | **5.1 Privacy** — 5.1.1 data collection & consent, **5.1.1(v) account deletion**, 5.1.2 data use/sharing; 5.2 IP; 5.6 developer conduct; money-transmission / regional financial licensing |

Fintech-specific must-haves:
- **Account deletion in-app** (5.1.1(v)) if the app supports account creation. A "contact support" flow alone is not sufficient.
- **Sign in with Apple** (4.8): if you offer any third-party or social login, you must also offer an equivalent login option that limits data collection to name + email and supports Hide My Email — Sign in with Apple satisfies this. See `authentication`.
- **Demo credentials / sandbox**: provide a working test account (or App Review notes explaining how to reach gated flows) or expect a 2.1 rejection.
- **Regulated-activity documentation**: apps facilitating money transmission, brokerage, or crypto may need to show licensing/authorization for each region; put it in App Review notes.
- **Purpose strings**: every entitled data class (`NSCameraUsageDescription`, `NSFaceIDUsageDescription`, `NSLocationWhenInUseUsageDescription`, `NSContactsUsageDescription`, etc.) must be present and specific — a missing/empty string is both a runtime crash and a rejection.

Full section-by-section rejection playbook and Resolution Center response templates: `references/rejection-playbook.md`.

<a id="privacy-manifest"></a>
## PrivacyInfo.xcprivacy

A property-list resource (`PrivacyInfo.xcprivacy`, type "App Privacy") in the app bundle and in **each** app extension / framework you ship. Third-party SDKs must ship their own; Xcode aggregates them into the **Privacy Report** at archive time. Four top-level keys:

| Key | Type | Meaning |
|---|---|---|
| `NSPrivacyTracking` | Boolean | Does the app/SDK use data for *tracking* (as ATT defines it)? |
| `NSPrivacyTrackingDomains` | Array\<String\> | Domains involved in tracking. Non-ATT-authorized connections to these are **blocked at runtime** on device. |
| `NSPrivacyCollectedDataTypes` | Array\<Dict\> | Each data type collected, whether linked to identity, used for tracking, and its purposes. |
| `NSPrivacyAccessedAPITypes` | Array\<Dict\> | Required-reason API categories used + approved reason codes. |

### Required-reason APIs

Five API categories require a declared, Apple-approved reason. Declaring the wrong or no reason is an **upload blocker** (validation email / rejected build). Each entry is a dict with `NSPrivacyAccessedAPIType` (the category) and `NSPrivacyAccessedAPITypeReasons` (array of codes).

| `NSPrivacyAccessedAPIType` value | Covers (examples) | Common reason code |
|---|---|---|
| `NSPrivacyAccessedAPICategoryFileTimestamp` | `stat`, `NSFileModificationDate`, `.contentModificationDateKey`, `getattrlist` | `C617.1` (files inside your own container) |
| `NSPrivacyAccessedAPICategorySystemBootTime` | `systemUptime`, `mach_absolute_time` epoch | `35F9.1` (measure elapsed time) |
| `NSPrivacyAccessedAPICategoryDiskSpace` | `volumeAvailableCapacityKey`, `statfs` | `E174.1` (write only when space allows) |
| `NSPrivacyAccessedAPICategoryActiveKeyboards` | `UITextInputMode.activeInputModes` | `3EC4.1` (custom-keyboard app itself) |
| `NSPrivacyAccessedAPICategoryUserDefaults` | `UserDefaults`, `NSUserDefaults` | `CA92.1` (your own app's defaults; App-Group defaults use `1C8F.1`) |

> Reason codes are exact strings from Apple's approved list; each category has several codes for different use cases. **Do not guess** — copy the code matching your actual usage from Apple's "Describing use of required reason API" table. The full per-category code list is in `references/privacy-manifest.md`.

### Skeleton

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>NSPrivacyTracking</key>
  <false/>
  <key>NSPrivacyTrackingDomains</key>
  <array/>
  <key>NSPrivacyAccessedAPITypes</key>
  <array>
    <dict>
      <key>NSPrivacyAccessedAPIType</key>
      <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
      <key>NSPrivacyAccessedAPITypeReasons</key>
      <array><string>CA92.1</string></array>
    </dict>
  </array>
  <key>NSPrivacyCollectedDataTypes</key>
  <array>
    <dict>
      <key>NSPrivacyCollectedDataType</key>
      <string>NSPrivacyCollectedDataTypePaymentInfo</string>
      <key>NSPrivacyCollectedDataTypeLinked</key>
      <true/>
      <key>NSPrivacyCollectedDataTypeTracking</key>
      <false/>
      <key>NSPrivacyCollectedDataTypePurposes</key>
      <array>
        <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
```

### Audit rules

- If `NSPrivacyTracking` is `true`, the app **must** call ATT before any tracking (see [ATT](#att)) and **must** list `NSPrivacyTrackingDomains`.
- Listing a domain under `NSPrivacyTrackingDomains` means the OS **blocks** connections to it until the user grants ATT — so an analytics/ads domain there will silently fail if you never prompt. Reconcile with `analytics-patterns` / `feature-flags`.
- Every fintech app that touches money data almost always declares `NSPrivacyCollectedDataTypePaymentInfo`, and usually `...ContactInfo`, `...FinancialInfo` (credit/financial data), `...DeviceID`, `...CrashData`, `...PerformanceData`. Data type identifiers list: `references/privacy-manifest.md`.
- **Extensions ship their own manifest** — a widget, notification-service, or App Clip target that calls a required-reason API needs the declaration in *its* bundle, not the app's. See `widgetkit` / `activitykit` / `app-clips`.
- The manifest and the App Privacy labels are **independently reviewed**; a mismatch (label says "no data collected", manifest declares a linked type) is a common reconciliation-stage rejection.

<a id="privacy-labels"></a>
## App Privacy nutrition labels

Set in App Store Connect (App Privacy section) — a **metadata gate**; you cannot submit without answering. The label is your public "Data collected" card.

- Declare, per data type: **collected?**, **linked to identity?**, **used for tracking?**, and **purposes** (App Functionality, Analytics, Product Personalization, Third-Party Advertising, Developer's Advertising, Other).
- **Tracking** here has the ATT meaning — linking user/device data with third-party data for ads, or sharing with data brokers. If *any* data type is marked "used for tracking", ATT is mandatory.
- Third-party SDKs collect on your behalf — you are responsible for declaring what they collect. Cross-check each SDK's published privacy details and its bundled manifest.
- **Consistency triad** to reconcile before submitting: privacy **label** (App Store Connect) ↔ privacy **manifest** (`NSPrivacyCollectedDataTypes`) ↔ actual **runtime** collection + `NSPrivacyTrackingDomains`. All three must agree.

<a id="att"></a>
## App Tracking Transparency

Required (framework `AppTrackingTransparency`) whenever the app tracks per the definition above. Gate access to the IDFA and any cross-app/broker data sharing on the user's choice.

- **Info.plist:** `NSUserTrackingUsageDescription` is **mandatory** — the prompt won't show (and review will flag) without it. Describe the real benefit to the user, not "we track you".
- Request only when you have context; do **not** block app functionality on a "denied" answer (Guideline 5.1.2 — the app must work either way).

```swift
import AppTrackingTransparency

func requestTracking() async -> Bool {
    let status = await ATTrackingManager.requestTrackingAuthorization()
    // .authorized | .denied | .restricted | .notDetermined
    return status == .authorized
}

// Read current status without prompting:
let current = ATTrackingManager.trackingAuthorizationStatus
```

- `requestTrackingAuthorization()` has an `async` form (iOS 15+) and a completion-handler form. Only prompt when `trackingAuthorizationStatus == .notDetermined`; the system shows it once.
- Only read the IDFA (`ASIdentifierManager.shared().advertisingIdentifier`) after `.authorized` — otherwise it returns all-zeros.
- **Do not** gate the prompt behind, or bundle it with, any other permission or a reward; incentivizing/forcing "Allow" is a rejection.

<a id="payments"></a>
## StoreKit / payment-rule compliance

Guideline **3.1.1** governs digital purchases. Getting this wrong is one of the top rejection causes. This skill checks *which rule applies*; implement with `storekit`.

- **Digital goods/services consumed in-app** (subscriptions, unlockable features, in-app currency) → **must** use In-App Purchase. No external checkout for these.
- **Physical goods & real-world services** (money transfers, card issuance, bill pay, buying physical items, person-to-person payments) → must **not** use IAP; use your own payment stack / Apple Pay (`passkit`). A fintech app moving real money is generally in this category.
- **Anti-steering (US storefront):** following the 2025 court order, Guideline **3.1.1(a)** permits buttons, external links, and calls to action to a purchase outside the app **on the US storefront with no entitlement required**. Rules still vary by storefront/region — do not assume worldwide.
- **External Purchase / External Link Account entitlements** apply on other storefronts and carry their own disclosure-sheet and formatting rules; confirm the current program per region rather than hardcoding.
- **Account/business context:** apps for a "reader" or enterprise/one-to-one business model have narrower carve-outs (3.1.3) — classify the app before assuming IAP is or isn't required.

<a id="export"></a>
## Export compliance

Every app declares whether it uses non-exempt encryption. HTTPS/TLS and Apple-provided crypto are generally *exempt*, but you still must answer.

- **Info.plist key:** `ITSAppUsesNonExemptEncryption` (Boolean). Set it in the build so the questionnaire stops appearing on every upload.
  - `false` if you only use exempt encryption (standard HTTPS/`URLSession`, Apple crypto). Most apps.
  - `true` if you add proprietary/non-standard encryption or non-exempt algorithms; you then owe export documentation.
- **`ITSEncryptionExportComplianceCode`** — only the code App Store Connect issues *after* it approves your export docs. Never invent this value.
- Answering `true` without the required CCATS/self-classification documentation is a **metadata gate** stall (and applies to TestFlight external testing too). A fintech app using its own crypto beyond TLS should plan the paperwork. Crypto details: `swift-security`.

<a id="entitlements"></a>
## Entitlements & capabilities

Mismatches between the `.entitlements` file, the App ID's enabled capabilities, and the provisioning profile are **upload blockers** (profile/signing validation).

- Enable each capability on the App ID (Certificates, Identifiers & Profiles) **and** in the target's Signing & Capabilities so the profile carries it: App Groups, Keychain Sharing, Push Notifications (`aps-environment`), Sign in with Apple, Apple Pay merchant IDs, Associated Domains, App Attest, HealthKit, background modes, etc.
- Ship no entitlement you don't use — an unjustified sensitive entitlement (e.g. a special background mode) draws scrutiny.
- **Associated Domains** (universal links, credential sharing / passkeys, App Clips) require the matching `apple-app-site-association` file served over HTTPS at the domain root; a missing/invalid AASA breaks the feature and the review flow. See `deep-linking`, `authentication`, `app-clips`.
- `aps-environment` must match the distribution channel (`production` for App Store/TestFlight). See `push-notifications`.
- Special entitlements (CarPlay, critical alerts, etc.) require Apple approval before they'll sign for distribution — request early.

<a id="metadata"></a>
## Metadata / screenshots / age rating

App Store Connect gates submission on these:

- **Screenshots:** App Store Connect now requires only one set at the largest current size per family (6.9" iPhone, plus 13" iPad if the app supports iPad) and auto-scales the rest — verify the current required sizes in App Store Connect. Must show the actual app (2.3.3) — no device frames that hide UI, no misleading marketing-only imagery.
- **App name / subtitle / keywords / description / promotional text:** accurate; no competitor names, no pricing in metadata, no "beta"/"test" wording for a public release (2.3). Localize per `localization-patterns`.
- **Age rating:** answer the App Store Connect questionnaire; fintech apps often need the "unrestricted web access" and gambling questions answered honestly. Mis-rating is a rejection.
- **App Privacy** (see [labels](#privacy-labels)), **support URL**, **privacy policy URL** (required when you collect data — always, for fintech), **marketing URL** (optional).
- **App Review notes:** the highest-leverage field — put demo credentials, how to reach gated/regulated flows, licensing evidence, and an explanation of anything a reviewer might misread.

<a id="testflight"></a>
## TestFlight

- **Internal testers** (up to 100 users on the team, by App Store Connect role) get builds **without** Beta App Review. Fastest loop.
- **External testers** (up to 10,000 via public link or email) require **Beta App Review** on the first build of a version and when you materially change it — a lighter pass than full review, but the privacy manifest, ATT, purpose strings, and export-compliance answer are all still checked. Fixing them here prevents surprises at full submission.
- Builds expire after **90 days**. TestFlight is not a distribution channel for production — don't rely on it for long-lived access.
- Provide **Beta App Description** and **feedback email**; a crash on launch or an obvious placeholder will fail Beta App Review too.

<a id="blockers"></a>
## Upload blockers vs post-review cleanup

Separate what stops the build/submission *now* from what a human might reject *later*.

**Upload blockers (automated — fix first):**
- Missing/invalid `NSPrivacyAccessedAPITypes` reason for a required-reason API your code or an SDK calls.
- Entitlement ↔ App ID ↔ provisioning-profile mismatch; wrong `aps-environment`.
- Missing purpose string for a framework the binary links (e.g. `NSFaceIDUsageDescription`) — can crash at runtime and be flagged.
- Deprecated/removed API or private-API symbol usage (2.5.1); missing required device-family assets.
- Unset export-compliance answer / privacy labels / age rating (metadata gate — App Store Connect won't let you submit).

**Post-review cleanup (human judgment — rank by likelihood):**
- Privacy label ↔ manifest ↔ runtime mismatch (5.1).
- No in-app account deletion (5.1.1(v)); no Sign in with Apple parity (4.8).
- IAP-rule misclassification (3.1.1); ATT prompt incentivized or missing when tracking.
- Thin/"web-wrapper" functionality (4.2); placeholder content or no demo account (2.1).
- Inaccurate screenshots/metadata (2.3); unjustified sensitive entitlement.

<a id="checklist"></a>
## Correctness checklist

- [ ] Each finding tagged **upload blocker** / **metadata gate** / **post-review**, and mapped to a numbered guideline.
- [ ] `PrivacyInfo.xcprivacy` present in the app **and every extension/framework** that needs one; Privacy Report reviewed at archive.
- [ ] Every required-reason API (FileTimestamp, SystemBootTime, DiskSpace, ActiveKeyboards, UserDefaults) used by app **or SDK** has a correct, non-guessed reason code.
- [ ] Privacy **label** ↔ **manifest** `NSPrivacyCollectedDataTypes` ↔ runtime collection all agree; SDK collection accounted for.
- [ ] `NSPrivacyTracking`/`NSPrivacyTrackingDomains` consistent with actual tracking; if tracking, ATT is called and `NSUserTrackingUsageDescription` is set and specific.
- [ ] ATT prompted only when `.notDetermined`, not incentivized, app works when denied; IDFA read only after `.authorized`.
- [ ] Payment flows classified against 3.1.1 (digital → IAP; real-money/physical → own stack); external-link rules checked **per storefront**, not assumed worldwide.
- [ ] `ITSAppUsesNonExemptEncryption` set in Info.plist; export docs/`ITSEncryptionExportComplianceCode` obtained if `true` (never invented).
- [ ] Entitlements match App ID + provisioning profile; `aps-environment` = production for release; AASA served for associated domains.
- [ ] In-app account deletion present (if accounts exist); Sign in with Apple offered if any third-party login is.
- [ ] Every usage-description string present and specific; no missing purpose strings.
- [ ] Screenshots for required sizes show the real app; age rating, privacy-policy URL, support URL set; demo credentials + regulatory notes in App Review notes.
- [ ] TestFlight external build passes Beta App Review; no launch crash / placeholder; build not relied on past 90-day expiry.
