# ActivityKit push-to-update — APNs payloads & channels

Deep reference for remotely updating/ending Live Activities. The app-side wiring is
in `SKILL.md`; server auth/topics live in the `push-notifications` skill.

## Token vs. channel

| | `.token` | `.channel("<base64>")` |
|---|---|---|
| Scope | one activity on one device | one broadcast channel → many devices |
| Can **start** an activity | no (app starts it, then you push) | **no** — start per-device with `.token` |
| Can **update / end** | yes | yes |
| Token source | `activity.pushTokenUpdates` | channel id you mint on your server |
| Use for | per-user order/ride/transfer | shared event (live match, flash sale) everyone watches |

Only one `PushType` per `Activity.request`. A single device can hold both a token
activity and channel activities.

## APNs request headers

```
:method            POST
:path              /3/device/<activity-push-token-hex>      # per-token
apns-push-type     liveactivity
apns-topic         com.example.myapp.push-type.liveactivity  # bundle id + suffix
apns-priority      10        # 10 = deliver immediately; 5 = throttled/low power
apns-expiration    <unix-ts> # 0 = discard if not deliverable now
authorization      bearer <JWT signed with your APNs key>
```

For channel pushes, address the channel per Apple's broadcast endpoint instead of a
device path; the topic suffix is the same.

## Update payload

`content-state` must decode into your `ContentState` exactly (same keys/types).

```json
{
  "aps": {
    "timestamp": 1765400000,
    "event": "update",
    "content-state": {
      "status": "enRoute",
      "etaSeconds": 540,
      "driverName": "Sam",
      "updatedAt": 1765400000
    },
    "stale-date": 1765400900,
    "relevance-score": 100,
    "alert": {
      "title": "On the way",
      "body": "Sam is heading to you",
      "sound": "default"
    }
  }
}
```

- Omit `alert` for a silent update (no breakthrough). Include it to surface on the Lock Screen / Dynamic Island.
- `stale-date` and `relevance-score` mirror the `ActivityContent` fields; both optional.
- `timestamp` orders updates — the system ignores a payload older than what it already showed.

## End payload

```json
{
  "aps": {
    "timestamp": 1765401000,
    "event": "end",
    "content-state": { "status": "delivered", "etaSeconds": 0, "driverName": "", "updatedAt": 1765401000 },
    "dismissal-date": 1765401300
  }
}
```

- `dismissal-date` (unix time) = when the ended activity is removed from the Lock Screen. Past/absent → system default (removes soon, up to ~4 h retention).
- Send a final `content-state` so the last frame is correct.

## Start payload (channel start is NOT supported)

To start via push at all you use a *token*-based start only after the app has run;
in practice the app calls `Activity.request` locally. A start payload (when supported
on your channel program) additionally carries `attributes-type` and `attributes`:

```json
{
  "aps": {
    "timestamp": 1765399000,
    "event": "start",
    "attributes-type": "DeliveryActivityAttributes",
    "attributes": { "orderNumber": "A-1029", "merchantName": "Cafe" },
    "content-state": { "status": "preparing", "etaSeconds": 900, "driverName": "", "updatedAt": 1765399000 }
  }
}
```

## Frequent updates

- `NSSupportsLiveActivitiesFrequentUpdates` = YES lets you push at a higher cadence, but the user can turn it off.
- App reads `ActivityAuthorizationInfo().frequentPushesEnabled` and observes `frequentPushEnablementUpdates`; forward the flag to your server so it can drop to a lower cadence (and higher `apns-priority: 5` / longer intervals) when disabled.
- Even with frequent updates on, the system may throttle a misbehaving app. Design the UI to look correct between pushes (live timers, `isStale` treatment).

## Pitfalls

- Wrong `apns-topic` suffix (`.push-type.liveactivity`) → silent non-delivery.
- `content-state` keys not matching `ContentState` → decode failure, update dropped.
- Reusing a stale per-activity token after it rotated → send from `pushTokenUpdates` each time it changes and retire the old one.
- Pushing every second → throttling; use `Text(_, style: .timer)` and push on real state changes.
