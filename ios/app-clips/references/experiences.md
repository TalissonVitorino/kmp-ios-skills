# App Clip experiences — App Store Connect

Deep reference for `app-clips` ▸ [App Store Connect experiences](../SKILL.md#experiences).
The App Clip *Card* and its URL mapping live in App Store Connect, not in your code —
the SwiftUI you write only runs *after* the card's action button is tapped.

## Default vs. advanced

| | Default experience | Advanced experience |
|---|---|---|
| Required? | **Yes** (per app version) | Optional, add as many as needed |
| Configured on | The app version | The app version's "Advanced App Clip Experiences" section |
| Bound to | One URL (the default App Clip link) | A specific **URL prefix** you register |
| Invocations unlocked | Safari banner, Messages, Maps, Apple-provided links | + QR codes, generic NFC tags, App Clip Codes, location suggestions, multiple domains, per-merchant cards |
| Cards | One | One per experience (customize per location/business) |
| Location association | No | Yes (a place from Apple Maps / Business Connect) |

- Uploading a build with a clip + a configured default experience auto-generates the **default App Clip link** and a **demo URL** (used for local testing without the card).
- If you only need Safari/Messages/Maps, the default experience alone is enough — skip advanced experiences.

## Registering advanced experiences

- Register a **URL prefix**, not an exact URL: `https://pay.example.com/` (broad) matches every merchant path. Add a narrower prefix like `https://pay.example.com/vip/` **only** when it needs a different card or behavior — the longest matching prefix wins.
- Every registered prefix's domain must appear in the clip's `associated-domains` (`appclips:` prefix) and its AASA `appclips` block.
- Each advanced experience has:
  - **Status** (Received / Deployed) and a title.
  - A **place** (optional) for location-based suggestions.
  - **Business Connect** association for real-world places (pay-at-restaurant, etc.).
- The App Store Connect API exposes these under `appClipAdvancedExperiences` (create / read / list) for CI automation.

## The App Clip Card

Apple-hosted UI shown before launch. You supply:

- **Header image** (per current spec; a wide promotional image).
- **Title** and **subtitle** (short — describe the specific task, e.g. "Pay — Blue Bottle, Pier 1").
- **Action** verb: `Open`, `View`, `Play` (pick the closest; no custom text).
- Localizations per supported language.

Keep the card task-specific: a card that says exactly what will happen ("Pay this table") converts far better than a generic app pitch.

## App Clip Codes

- Generated per **advanced experience** in App Store Connect (or the API).
- Two scan paths in one artifact: **NFC + camera-scannable visual** (Apple's ring design), or a camera-only variant where NFC isn't wanted.
- You pick the color pair (must pass Apple's contrast rules) and download print-ready assets.
- Because they're Apple-verified, they're the most reliable physical trigger — prefer them over hand-rolled QR/NFC for merchant placement.

## Testing before release

- **Local Experience** (Settings ▸ Developer ▸ Local Experiences on device): map a URL prefix + bundle ID to test routing without App Store Connect. The card is a simplified placeholder — good for wiring, not final card visuals.
- **TestFlight**: testers get the real card and invocation flow.
- The Safari App Clip banner and Smart App Banner only render for a **published** app; use Local Experiences / demo URL / TestFlight before that.
