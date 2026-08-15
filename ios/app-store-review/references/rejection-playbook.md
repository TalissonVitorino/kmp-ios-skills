# Rejection playbook & Resolution Center

Companion to the `app-store-review` skill. Section-by-section rejection triggers,
how to respond in Resolution Center, and expedited/appeal paths. Guideline
numbers follow the App Review Guidelines (five domains: 1 Safety, 2 Performance,
3 Business, 4 Design, 5 Legal). Confirm exact sub-numbers against the current
published guidelines — Apple renumbers.

## High-frequency fintech rejections

| Guideline | Trigger | Fix / response |
|---|---|---|
| **2.1** App completeness | Reviewer can't reach a gated flow; no demo account; crash/placeholder | Provide working demo credentials + step-by-step in App Review notes; ensure sandbox backend is live during review |
| **2.3.x** Accurate metadata | Screenshots don't show real app; description overstates; "beta"/pricing in metadata | Real in-app screenshots; trim claims; move pricing out of text |
| **2.5.1** Software requirements | Private API / undocumented symbol; deprecated capability | Remove private symbols; use public APIs only |
| **3.1.1** In-App Purchase | Selling digital goods via external checkout; or forcing IAP for real-world money movement | Reclassify: digital-in-app ⇒ IAP; real money/physical ⇒ own stack. See `storekit`, `passkit` |
| **3.1.1(a)** Anti-steering | External-link formatting/entitlement wrong for the storefront | US storefront: links allowed, no entitlement (2025 order). Other storefronts: follow that region's external-purchase program |
| **4.2** Minimum functionality | App is a thin web wrapper | Add native value; don't ship a WKWebView-only shell |
| **4.8** Login services | Third-party/social login without an equivalent privacy-preserving option | Add Sign in with Apple (name+email only, Hide My Email). See `authentication` |
| **5.1.1** Data collection & storage | Purpose strings vague/missing; data collected before consent | Specific `NS…UsageDescription`; request at point of use |
| **5.1.1(v)** Account deletion | No in-app way to delete the account | Add in-app deletion that removes the account, not just data export or a support email |
| **5.1.2** Data use & sharing | Tracking without ATT; app breaks when tracking denied | Implement ATT; keep full functionality when denied |
| **5.6** Developer conduct | Manipulating reviews; misleading behavior | N/A to code — process issue |

## Privacy-label vs manifest mismatch (reconciliation stage)

The single most common "surprise" rejection for privacy-heavy apps:

1. List every data type actually sent off-device (yours + each SDK).
2. Ensure each appears in **both** the App Store Connect privacy label **and** `NSPrivacyCollectedDataTypes`, with matching linked/tracking flags.
3. Any host under `NSPrivacyTrackingDomains` must correspond to a data type flagged "tracking" and to an ATT prompt.
4. Regenerate Xcode's Privacy Report and diff it against the label before resubmitting.

## Responding in Resolution Center

- **Read the exact guideline number** Apple cites and the screenshot/log they attach. Respond to *that*, not a general defense.
- If it's a **misunderstanding**, reply in Resolution Center with a precise explanation + (if useful) a screen recording or updated demo steps — no new build needed.
- If it's a **real issue**, fix, bump the build, and note in the resubmission what changed and where.
- Keep tone factual. One clear reply with evidence beats several.

## Expedited review & appeals

- **Expedited review**: request only for genuine urgency (critical bug affecting users, time-sensitive event). Overuse burns credibility.
- **Appeal**: if you believe the rejection misapplies a guideline, use the App Review Board appeal — cite the guideline text and why the app conforms. Separate from a Resolution Center reply.
- **Guideline-change suggestion**: a distinct channel for arguing a rule itself should change; not a path to ship a non-conforming build now.

## Pre-submission dry-run

- Archive → **Generate Privacy Report**; read it.
- Validate the archive in Organizer (catches most upload blockers before submission).
- Confirm `ITSAppUsesNonExemptEncryption` answered; export docs if `true`.
- Confirm privacy labels, age rating, screenshots (required sizes), privacy-policy + support URLs, demo credentials, and regulatory notes are all filled.
- Send the build to a TestFlight **external** group first — Beta App Review exercises the same privacy/ATT/export checks with a faster turnaround.
