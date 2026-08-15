---
name: activitykit
description: "Build and update Live Activities and the Dynamic Island in an iOS app with ActivityKit — ActivityAttributes + ContentState, Activity.request/update/end with ActivityUIDismissalPolicy, ActivityConfiguration + DynamicIsland (compactLeading/compactTrailing/minimal + DynamicIslandExpandedRegion) registered in a WidgetBundle, the Lock Screen presentation, staleDate/relevanceScore, and remote updates via APNs (pushType .token / .channel, pushTokenUpdates, content-state payloads, NSSupportsLiveActivitiesFrequentUpdates + frequentPushesEnabled). Use when starting/updating/ending a Live Activity, laying out the Dynamic Island, or wiring push-to-update. The widget/timeline counterpart is `widgetkit`; server-side APNs delivery is `push-notifications`; App Intent buttons inside the activity use `app-intents`."
---

# ActivityKit — Live Activities & Dynamic Island (iOS)

Real-time, glanceable state (delivery, ride, order, workout, transfer) on the Lock
Screen, in the Dynamic Island, StandBy, the Apple Watch Smart Stack, the Mac menu
bar, and the CarPlay Dashboard. Grounded in Apple's ActivityKit + WidgetKit. iOS 16.1+;
targets the iOS 26 era.

- **Widget/timeline counterpart:** `widgetkit` (Home/Lock Screen widgets, timelines, App Groups). Live Activity UI *lives in the widget extension* and shares the App Group with the app.
- **Server-side push delivery:** `push-notifications` (APNs auth, topics). Interactive buttons in an activity: `app-intents` (`Button(intent:)` / `Toggle(intent:)`, no app launch).
- **Shared money formatting** in the UI: `swift-formatstyle`; if the model comes from KMP shared code, keep it a value type crossing the boundary per `kmp-ios-integration`.

## Contents

- [When it fits (and when not)](#fit)
- [Project setup](#setup)
- [Data model: ActivityAttributes + ContentState](#model)
- [Lifecycle: request / update / end](#lifecycle)
- [Observing state & tokens](#observe)
- [UI: ActivityConfiguration, Lock Screen, Dynamic Island](#ui)
- [Push-to-update (APNs)](#push)
- [Apple Watch / CarPlay](#watch)
- [Correctness checklist](#checklist)
- References: `references/push.md` (APNs payloads & channels), `references/dynamic-island.md` (region layout rules)

<a id="fit"></a>
## When it fits (and when not)

- **Fits:** a *single, live, user-initiated* event with a foreseeable end — order/delivery tracking, ride status, a running timer, a transfer clearing, a live score. One activity per real-world event.
- **Doesn't fit:** general marketing, always-on dashboards, or content with no end state. The system limits how many activities an app runs and how often they update; abuse gets throttled.
- **Budget:** combined `ContentState` + `ActivityAttributes` payload must stay **≤ 4 KB**. Keep the model tiny — ids and small scalars, not blobs or images.
- Users can disable Live Activities per-app in Settings — always gate on authorization.

<a id="setup"></a>
## Project setup

1. **Widget extension** — add a Widget Extension target (File ▸ New ▸ Target). The Live Activity UI is a `Widget` in this extension; the app owns the lifecycle.
2. **App Info.plist** — `NSSupportsLiveActivities` = `YES` (enables the feature). Add `NSSupportsLiveActivitiesFrequentUpdates` = `YES` only if you genuinely push frequent updates.
3. **Share the model** — put `ActivityAttributes` in a file with target membership in *both* the app and the widget extension (or a shared framework), so both sides see the same type.
4. **App Group** (recommended) — share ids/state between app and extension if the extension needs to read app data.

```xml
<!-- App target Info.plist -->
<key>NSSupportsLiveActivities</key>
<true/>
<key>NSSupportsLiveActivitiesFrequentUpdates</key>
<true/>
```

<a id="model"></a>
## Data model: ActivityAttributes + ContentState

`ActivityAttributes` holds **static** data fixed for the activity's life. Its nested
`ContentState` holds the **dynamic** data that changes on every update. Both must be
`Codable` (and `Hashable`); `ContentState` is what a push payload's `content-state`
decodes into.

```swift
import ActivityKit
import Foundation

struct DeliveryActivityAttributes: ActivityAttributes {
    // Dynamic — changes with every update. This is `Activity.ContentState`.
    public struct ContentState: Codable, Hashable {
        var status: DeliveryStatus          // e.g. .preparing, .enRoute, .arriving
        var etaSeconds: Int
        var driverName: String
        var updatedAt: Date
    }

    // Static — set once at request time, never changes.
    var orderNumber: String
    var merchantName: String
}

enum DeliveryStatus: String, Codable, Hashable { case preparing, enRoute, arriving, delivered }
```

- `Activity<Attributes>.ContentState` is an alias for `Attributes.ContentState` — you'll see both spellings.
- Keep it **flat and small** (the 4 KB budget). Prefer `Date` for times so the UI can render a live-counting timer (`Text(date, style: .timer)`) without pushing every second.
- Never put secrets/PII in the state — it renders on a locked screen and can pass through APNs.

<a id="lifecycle"></a>
## Lifecycle: request / update / end

Only the **foreground app** can *start* an activity; updates/ends can come from the
app (foreground/background) or from APNs.

```swift
import ActivityKit

@MainActor
final class DeliveryLiveActivity {
    private var activity: Activity<DeliveryActivityAttributes>?

    func start(order: Order) throws {
        // Gate on authorization — respect the user's Settings toggle.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = DeliveryActivityAttributes(
            orderNumber: order.number, merchantName: order.merchant)
        let state = DeliveryActivityAttributes.ContentState(
            status: .preparing, etaSeconds: order.eta, driverName: "", updatedAt: .now)

        let content = ActivityContent(state: state,
                                      staleDate: Date.now.addingTimeInterval(15 * 60),
                                      relevanceScore: 100)

        // pushType: .token → request a push token for remote updates. Omit for local-only.
        activity = try Activity.request(attributes: attributes, content: content, pushType: .token)
    }

    func update(status: DeliveryStatus, eta: Int, driver: String) async {
        guard let activity else { return }
        let state = DeliveryActivityAttributes.ContentState(
            status: status, etaSeconds: eta, driverName: driver, updatedAt: .now)
        let content = ActivityContent(state: state,
                                      staleDate: Date.now.addingTimeInterval(15 * 60),
                                      relevanceScore: 100)

        // Pass an alert to break through on the Lock Screen / Dynamic Island for important changes.
        await activity.update(content, alertConfiguration:
            AlertConfiguration(title: "Driver arriving",
                               body: "\(driver) is almost there",
                               sound: .default))
    }

    func end(delivered: Bool) async {
        guard let activity else { return }
        let final = DeliveryActivityAttributes.ContentState(
            status: .delivered, etaSeconds: 0, driverName: "", updatedAt: .now)
        // Dismissal policy controls how long the ended activity lingers on the Lock Screen.
        await activity.end(ActivityContent(state: final, staleDate: nil),
                           dismissalPolicy: .after(.now + 60 * 5))
        self.activity = nil
    }
}
```

- **`ActivityContent(state:staleDate:relevanceScore:)`** — `relevanceScore` (default `0.0`) orders *your own* concurrent activities in the Dynamic Island; higher wins. `staleDate` is when the system marks the content out of date.
- **`ActivityUIDismissalPolicy`**: `.default` (system keeps it up to ~4 h), `.immediate` (remove now), `.after(Date)` (remove at a time you choose). Pass a final `ContentState` to `end` so the last frame is correct.
- **Don't over-update.** Each `update` costs system budget; batch meaningful changes. Use a live `Text(…, style: .timer)` instead of pushing every tick.
- Reconnect on launch: `Activity<DeliveryActivityAttributes>.activities` returns any already-running activities to re-adopt after the app restarts.

<a id="observe"></a>
## Observing state & tokens

Each activity exposes async sequences. Start these in a detached `Task` right after `request`.

```swift
// Push token — send to your server; it can change, so keep listening.
Task {
    for await tokenData in activity.pushTokenUpdates {
        let hex = tokenData.map { String(format: "%02x", $0) }.joined()
        try await api.registerLiveActivityToken(hex, orderNumber: order.number)
    }
}

// Lifecycle — .active, .stale (past staleDate), .ended, .dismissed (removed by user/system).
Task {
    for await state in activity.activityStateUpdates {
        if state == .dismissed || state == .ended { cleanUp() }
    }
}

// Content — react to updates that arrived via push.
Task { for await content in activity.contentUpdates { render(content.state) } }
```

- `pushTokenUpdates` is **per-activity** (distinct from the APNs *device* token). Emit the first token before sending any push; re-send whenever it changes and invalidate the old one.
- **Frequent updates:** if you set `NSSupportsLiveActivitiesFrequentUpdates`, read `ActivityAuthorizationInfo().frequentPushesEnabled` and watch `frequentPushEnablementUpdates` — the user can disable it independently. Tell your server to throttle when it's off.

<a id="ui"></a>
## UI: ActivityConfiguration, Lock Screen, Dynamic Island

The UI is a `Widget` returning an `ActivityConfiguration`, registered in the widget
extension's `WidgetBundle`. The first closure is the **Lock Screen / banner**; the
`dynamicIsland:` closure builds the three Dynamic Island presentations.

```swift
import ActivityKit
import WidgetKit
import SwiftUI

@main
struct DeliveryWidgetBundle: WidgetBundle {
    var body: some Widget {
        DeliveryHomeWidget()        // ordinary widgets, if any
        DeliveryLiveActivityWidget() // the Live Activity
    }
}

struct DeliveryLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DeliveryActivityAttributes.self) { context in
            // Lock Screen + Home Screen banner (no Dynamic Island).
            LockScreenDeliveryView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.2))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                // EXPANDED — long-press / prominent. Regions: leading, trailing, center, bottom.
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.merchantName, systemImage: "bag.fill")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(etaDate(context.state), style: .timer).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    DeliveryProgressBar(status: context.state.status)
                        .foregroundStyle(context.isStale ? .secondary : .primary)
                }
            } compactLeading: {
                Image(systemName: "shippingbox.fill")
            } compactTrailing: {
                Text(etaDate(context.state), style: .timer).frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "shippingbox.fill")
            }
            .widgetURL(URL(string: "myapp://order/\(context.attributes.orderNumber)"))
            .keylineTint(.orange)
        }
    }
}
```

- **`context`** (`ActivityViewContext`) gives you `context.state` (dynamic `ContentState`), `context.attributes` (static), `context.isStale` (past `staleDate` → show a muted "updating…" treatment), and `context.activityID`.
- **Dynamic Island regions** — *compact* (`compactLeading` / `compactTrailing`) shows when only your activity is active; *minimal* shows when several apps compete (system may show just one). *Expanded* uses `DynamicIslandExpandedRegion(.leading/.trailing/.center/.bottom)`; keep compact/minimal to a single glyph or short number. Layout rules and priorities in `references/dynamic-island.md`.
- Keep both presentations rendering from the **same `context.state`** so Lock Screen and Island never disagree.
- **Interactive controls:** use `Button(intent:)` / `Toggle(intent:)` backed by an `AppIntent` (no app launch) — see `app-intents`. Deep-link taps use `.widgetURL` / `Link`.
- Live time: prefer `Text(date, style: .timer)` / `.relative` so countdowns tick without a push per second.

<a id="push"></a>
## Push-to-update (APNs)

Update or end an activity remotely without waking the app.

- Request with `pushType: .token`; collect the token from `pushTokenUpdates` and send it to your server (one token per activity).
- APNs headers: `apns-push-type: liveactivity`, `apns-topic: <your.bundle.id>.push-type.liveactivity`, plus `apns-priority` and `apns-expiration`.
- Payload `aps` carries `event` (`"update"` or `"end"`), a **`content-state`** object that must decode into your `ContentState`, a `timestamp`, and optionally `stale-date`, `relevance-score`, `alert`, and (for end) `dismissal-date`.
- **`.channel(_:)`** (broadcast) — `pushType: .channel("<base64 id>")` updates *many* devices' activities from one channel push; channels can update/end but **cannot start** an activity. Use for shared events (a live match) where every viewer sees the same state. Starting a broadcast activity still happens per-device via `.token`.
- Full payload examples, priority/expiration guidance, and channel management are in `references/push.md`. Server delivery (auth keys, topics) is the `push-notifications` skill.

<a id="watch"></a>
## Apple Watch / CarPlay

- Live Activities surface on the **Apple Watch Smart Stack** automatically. Adapt the Lock Screen view for the small watch presentation with `.supplementalActivityFamilies([.small])` on the `ActivityConfiguration` (iOS 18 / watchOS 11+); branch UI on the `\.activityFamily` environment value.
- **CarPlay Dashboard** can display Live Activities (iOS 26 era) — keep the Lock Screen layout legible at a glance; no separate configuration is required, but test the reduced presentation.

<a id="checklist"></a>
## Correctness checklist

- [ ] `ActivityAttributes` (+ nested `ContentState`) is `Codable`/`Hashable`, small, and shares target membership with the widget extension.
- [ ] Combined attributes + content-state stays ≤ 4 KB; no secrets/PII in the state.
- [ ] `NSSupportsLiveActivities` = YES in the app Info.plist; frequent-updates key set *only* if actually used.
- [ ] Start gated on `ActivityAuthorizationInfo().areActivitiesEnabled`; only the foreground app calls `request`.
- [ ] `ActivityContent` sets a sensible `staleDate`; UI handles `context.isStale`.
- [ ] `end` passes a correct final `ContentState` and an explicit `ActivityUIDismissalPolicy`.
- [ ] `pushTokenUpdates`, `activityStateUpdates`, and `contentUpdates` observed in a `Task`; token sent before pushing, re-sent on change.
- [ ] On launch, re-adopt running activities via `Activity.activities`.
- [ ] Dynamic Island: compact/minimal are single-glyph/short; expanded uses `DynamicIslandExpandedRegion`; both presentations render from `context.state`.
- [ ] Live timers use `Text(_, style: .timer)` instead of a push-per-second.
- [ ] APNs uses `apns-push-type: liveactivity` and topic `<bundle>.push-type.liveactivity`; `.channel` used for broadcast (never to *start*).
- [ ] `frequentPushesEnabled` respected; server throttles when the user disables frequent updates.
- [ ] Interactive controls use `AppIntent` (`app-intents`), not app-launch hacks.
