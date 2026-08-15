# App Clip size & capabilities

Deep reference for `app-clips` ▸ [Size & capability budget](../SKILL.md#budget).

## The size cap (thinned, uncompressed)

The limit is on the **uncompressed main bundle after app thinning**, per device
variant, keyed to the clip's **minimum deployment target**:

| Min deployment target | Max thinned uncompressed size |
|---|---|
| earlier than iOS 16 | 10 MB |
| iOS 16+ | 15 MB |
| iOS 17+ | 100 MB — **digital-invocation-only** clips (see caveat) |

- The **iOS 17 100 MB cap applies only** to clips that support **digital invocations only** (website / Spotlight), can't target below iOS 17, and require a reliable network connection. A clip with **any physical** invocation (App Clip Code / QR / NFC) stays at **15 MB** even on iOS 17. Fintech merchant clips (App Clip Codes / NFC at the till) are physical, so plan for **15 MB**.
- The **archive** size and the **download** size are both different numbers — neither is what App Store Connect enforces. Read the real figure from the thinning report.
- Setting a higher minimum target raises the cap but drops older-OS users; choose deliberately.

### Measuring it

1. Xcode ▸ Product ▸ Archive.
2. Organizer ▸ Distribute ▸ export **for App Store / Ad Hoc with "Rebuild from Bitcode" off and app thinning "All compatible device variants"**.
3. Open `App Thinning Size Report.txt` — the **uncompressed** column of the largest variant is the number that must be under the cap.

## Shrinking a clip

- **Asset catalogs everywhere**: images/colors in `.xcassets` are thinned per device and pixel density automatically. Loose PNGs are not.
- **Link only what you need**: split shared code so the clip links a lean subset. A single fat "shared everything" framework pulls its whole transitive graph into the clip.
- **Drop heavyweight dependencies** in the clip target (analytics SDKs, image pipelines, chart libs). Reimplement the tiny slice you need or defer it to the full app.
- **Defer large assets**: fetch big media/config over the network *after* launch rather than bundling it.
- **Strip debug/dev-only** code and resources from the clip's build configuration.
- **Prefer system frameworks** (SwiftUI, SF Symbols) over bundled equivalents.

## Capabilities an App Clip does NOT have

- **No background execution** after the user leaves — no `BGTaskScheduler`, no background URLSession completion you can rely on, no background location.
- **No** access to: HealthKit, background/continuous location, the user's full photo library picker as a persistent grant, App Tracking Transparency for cross-app tracking (a clip must not track).
- **Ephemeral storage**: data is cleared when the clip is evicted; nothing persists across invocations unless handed to the full app (App Group / CloudKit).
- **Minimized prompts**: use the ephemeral notification grant and location confirmation instead of full permission prompts (see the main skill). Standard prompts that *are* allowed (camera, one-shot location when-in-use) still work but should be rare and justified.

## Capabilities an App Clip DOES have

- StoreKit purchases and **Apple Pay** (`passkit`) — the point of many fintech clips.
- Sign in with Apple (`authentication`) — carries to the full app.
- CloudKit (`cloudkit`), local notifications (ephemeral grant), Core NFC reading, camera, MapKit.
- Full SwiftUI / UIKit UI, networking (Ktor/URLSession), Keychain (writes are private to the clip — not shared with the full app).
