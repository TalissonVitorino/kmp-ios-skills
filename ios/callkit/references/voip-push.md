# VoIP push (PushKit) — payload, delivery, pitfalls

Deep reference for `pushkit` VoIP delivery. The main skill covers the golden rule
(report a call on every push); this covers the wire format and edge cases.

## Server → APNs

- **Endpoint:** APNs (`api.push.apple.com`, or sandbox `api.sandbox.push.apple.com`).
- **Headers:**
  - `apns-topic: <your.bundle.id>.voip` — note the `.voip` suffix; a plain bundle id is rejected for VoIP.
  - `apns-push-type: voip` (required on modern APNs).
  - `apns-priority: 10`, `apns-expiration: 0` (deliver now or drop — a stale call ring is worse than none).
- **Auth:** token-based (JWT signed with your APNs key, `Authorization: bearer <jwt>`) or a VoIP-services certificate. Token-based is preferred (one key, all environments).
- **Token target:** the `PKPushCredentials.token` from `pushRegistry(_:didUpdate:for:)`, hex-encoded — *not* the token from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.

## Payload shape

There is no reserved `aps` structure for VoIP — the whole `dictionaryPayload` is yours. Include everything CallKit needs so you can report synchronously without a network round-trip:

```json
{
  "uuid": "6B2B... (server-generated call UUID, matches your signaling)",
  "handle": "14085550101",
  "callerName": "Acme Bank — Fraud Line",
  "hasVideo": false
}
```

- Generate the call `UUID` server-side and reuse it across the push and your signaling channel so both sides agree on identity.
- Keep it small; APNs caps VoIP payloads (a few KB). Push the minimum to render the call; fetch richer detail after `reportNewIncomingCall`'s completion.

## Handler discipline

```swift
func pushRegistry(_ registry: PKPushRegistry,
                  didReceiveIncomingPushWith payload: PKPushPayload,
                  for type: PKPushType,
                  completion: @escaping () -> Void) {
    // 1. Parse (pure, no I/O).
    // 2. reportNewIncomingCall(...) { completion() }   <-- synchronous, no await before it
    // 3. Only inside/after that completion: connect sockets, hit the network, etc.
}
```

- **No `await`, no `DispatchQueue.global().async`, no network before the report.** The report must happen in the same run of the handler.
- If your parse fails or the call is already dead, still report a placeholder call, then immediately end it with `reportCall(with:endedAt:reason:.remoteEnded)` (or `.failed`). Reporting-then-ending is compliant; skipping the report is not.
- `didInvalidatePushTokenFor` means the OS rotated/removed the token — stop your server from sending to the old one and re-register.

## Why the enforcement exists

Before iOS 13, apps used VoIP pushes as silent background wakeups without showing a call. iOS 13 made CallKit reporting mandatory: the push is delivered *pre-warmed for a call*, and the OS audits that a call appears. Non-compliant apps have their VoIP push delivery throttled or the token invalidated. Use standard remote notifications (`push-notifications` skill) or `background-processing` (BGTaskScheduler) for anything that is not an actual call.

## Testing

- VoIP pushes can be delivered to a **device** (not the Simulator for real APNs), but you can drive the *CallKit* side in the Simulator by calling `reportNewIncomingCall` directly from a debug button.
- Verify lock-screen answer: audio must start only in `provider(_:didActivate:)`, or you get one-way/no audio on first answer.
- Confirm the `.voip` topic and `apns-push-type: voip` header — a mismatched topic is the most common "push never arrives" cause.
