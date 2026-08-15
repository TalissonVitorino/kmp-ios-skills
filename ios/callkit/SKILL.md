---
name: callkit
description: "VoIP calling on iOS with CallKit + PushKit for a fintech app (advisor/support/verification calls) — CXProvider / CXProviderConfiguration (reportNewIncomingCall, reportCall updates), CXCallController + CXTransaction bundling CXStartCallAction / CXAnswerCallAction / CXEndCallAction / CXSetHeldCallAction, CXProviderDelegate perform-action handling, AVAudioSession activation timing (provider didActivate/didDeactivate), PKPushRegistry VoIP pushes (MUST report a call synchronously on every push), and Call Directory extensions (CXCallDirectoryProvider caller ID + blocking). Use when building incoming/outgoing call UI, registering for VoIP push, wiring call actions, coordinating the call audio session, or shipping caller-ID/blocking. Siblings: push-notifications (APNs/FCM for non-VoIP), contacts-framework (source data for caller ID), background-processing (BGTaskScheduler), swift-concurrency (async/actors), swift-security (token storage for the signaling backend)."
---

# CallKit + PushKit (iOS)

System call UI for VoIP: native incoming/outgoing screens, lock-screen answer,
Recents integration, and caller ID / blocking. Grounded in Apple's CallKit and
PushKit frameworks; iOS 26 era.

- **Two frameworks, one flow:** PushKit wakes the app for an incoming call; CallKit renders the call and owns the audio session.
- **Non-VoIP push** (chat, marketing, transaction alerts) → `push-notifications`. PushKit VoIP pushes are *only* for calls and are policed (see below).
- **Caller-ID source data** (names/labels for numbers) often comes from `contacts-framework` or your backend; the Call Directory extension just publishes it.

## Contents

- [Capabilities & Info.plist](#setup)
- [Architecture](#architecture)
- [CXProvider (system-facing)](#provider)
- [CXProviderDelegate — performing actions](#delegate)
- [Audio session timing](#audio)
- [CXCallController (app-initiated)](#controller)
- [PushKit VoIP push — the golden rule](#pushkit)
- [Call Directory extension (caller ID + blocking)](#directory)
- [Correctness checklist](#checklist)
- References: `references/voip-push.md`, `references/call-directory.md`

<a id="setup"></a>
## Capabilities & Info.plist

- **Background Modes** (`UIBackgroundModes`): `voip` (PushKit wake) **and** `audio` (keep audio alive in background). Without `voip`, `PKPushRegistry` never delivers.
- **Push Notifications** capability + APNs. VoIP pushes use a VoIP-services APNs auth key/token; the VoIP push token is *separate* from the standard `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` token.
- **Microphone:** `NSMicrophoneUsageDescription` is required or audio capture crashes.
- **Call Directory** ships as an app **extension target** (CXCallDirectoryProvider) with its own bundle id; enable it under **Settings → Apps → Phone → Call Blocking & Identification** (or Settings → Phone on older layouts).
- CallKit is **unavailable in some regions** (e.g. mainland China). Guard `CXProvider`-driven UI and degrade to an in-app screen where it isn't permitted.

<a id="architecture"></a>
## Architecture

One long-lived object owns a single `CXProvider` and a single `CXCallController`, and tracks your own call model keyed by `UUID` (CallKit's identity for a call). Keep it a plain object (not a SwiftUI view) so it survives background wakes.

```swift
import CallKit

final class CallManager: NSObject {
    let provider: CXProvider
    let controller = CXCallController()
    private var calls: [UUID: MyCall] = [:]   // your own signaling state

    override init() {
        let config = CXProviderConfiguration()          // init() — see below
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.supportedHandleTypes = [.phoneNumber, .generic]
        config.includesCallsInRecents = true            // false to keep calls out of the system Recents list
        // config.iconTemplateImageData = ...            // template PNG shown on the call UI
        // config.ringtoneSound = "ringtone.caf"         // bundled sound file
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)          // nil = main queue
    }
}
```

- **`CXProviderConfiguration()`** is the current initializer. `init(localizedName:)` is **deprecated** — create with `init()` and set `localizedName` as a property if you need the app name on the call screen.
- Reuse **one** provider for the app's lifetime; `provider.invalidate()` only on teardown (it ends all calls).

<a id="provider"></a>
## CXProvider (system-facing: report call state *to* the OS)

Use the provider to tell CallKit what happened. Identity is always a `UUID` you mint per call.

```swift
// Incoming — MUST be called for every VoIP push (see PushKit section).
func reportIncoming(uuid: UUID, handle: String, name: String?) {
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .phoneNumber, value: handle)  // or .generic / .emailAddress
    update.localizedCallerName = name
    update.hasVideo = false
    update.supportsHolding = true
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsDTMF = false

    provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
        if let error {
            // System refused to show it (Do Not Disturb, screening, blocked, filtered).
            // Do NOT ring/answer; tear down signaling. The call UUID is unusable.
            self?.calls[uuid] = nil
            return
        }
        self?.calls[uuid] = MyCall(uuid: uuid)   // now safe to connect media/signaling
    }
}

// Mutate an existing call (e.g. remote party name resolved late, upgraded to video):
provider.reportCall(with: uuid, updated: update)

// Remote hangup / missed / busy — end without a local user action:
provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
// reasons: .failed, .remoteEnded, .unanswered, .answeredElsewhere, .declinedElsewhere

// Outgoing lifecycle (after your CXStartCallAction is fulfilled):
provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())  // ringing
provider.reportOutgoingCall(with: uuid, connectedAt: Date())          // media up
```

- `reportNewIncomingCall`'s **completion is authoritative**: a non-nil `error` (`CXErrorCodeIncomingCallError`) means the OS suppressed the call — never proceed to answer it.
- `reportCall(with:endedAt:reason:)` is for **remote-driven** endings. When the *local user* ends via the UI, that arrives as a `CXEndCallAction` you fulfill (below) — don't call `reportCall(endedAt:)` for it.

<a id="delegate"></a>
## CXProviderDelegate — performing actions

When the user taps answer/end/hold on the system UI (or you request a transaction), CallKit invokes these. **Every action must be resolved with `action.fulfill()` (success) or `action.fail()` (failure)** — unresolved actions time out and destabilize the call.

```swift
extension CallManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        // System torn down (e.g. provider invalidated). Drop ALL calls & audio immediately.
        calls.removeAll()
    }

    // Outgoing: user/you started a call.
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        // Configure (do NOT activate) the audio session here, then start signaling.
        configureAudioSessionForCall()
        startOutgoingSignaling(uuid: action.callUUID, to: action.handle) { ok in
            ok ? action.fulfill() : action.fail()
        }
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
    }

    // Incoming answered from the system UI.
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        configureAudioSessionForCall()          // configure only; CallKit will activate
        answerSignaling(uuid: action.callUUID) { ok in
            ok ? action.fulfill() : action.fail()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        endSignaling(uuid: action.callUUID)
        calls[action.callUUID] = nil
        action.fulfill()                         // fulfill AFTER your teardown starts
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        setHold(uuid: action.callUUID, onHold: action.isOnHold)  // pause/resume media
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        setMuted(uuid: action.callUUID, muted: action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        // You didn't resolve an action in time — clean up defensively.
    }

    // Audio session lifecycle — see next section.
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) { startAudio() }
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) { stopAudio() }
}
```

<a id="audio"></a>
## Audio session timing (the part everyone gets wrong)

CallKit — not your app — **activates** the `AVAudioSession`. Your job is to *configure* it early and to *start/stop media* on the delegate callbacks.

1. In `perform: CXAnswerCallAction` / `CXStartCallAction`, set the **category/mode/options** but **do not call `setActive(true)`**:

   ```swift
   func configureAudioSessionForCall() {
       let session = AVAudioSession.sharedInstance()
       try? session.setCategory(.playAndRecord, mode: .voiceChat,
                                 options: [.allowBluetoothHFP, .allowBluetoothA2DP])  // .allowBluetooth renamed to .allowBluetoothHFP in iOS 26
       // No setActive(true) here — CallKit activates with the correct priority.
   }
   ```

2. CallKit activates the session and calls **`provider(_:didActivate:)`** — start your audio engine / WebRTC media *here*, not before. Starting audio before activation causes silent or dropped audio, especially when answering from the lock screen.
3. On end, stop media; CallKit deactivates and calls **`provider(_:didDeactivate:)`** — release audio resources there.
4. Configuring the session before reporting the call (or before fulfilling the answer action) lets the system route the ringtone and hand you an already-primed session on activation.

<a id="controller"></a>
## CXCallController (app-initiated: request actions *from* the OS)

When your UI (not the system UI) triggers something — user dials out, taps your in-app end/hold button — **request a transaction**; CallKit validates it and calls the matching delegate `perform` method.

```swift
// Outgoing call from your dial screen:
func startCall(to handle: String) {
    let uuid = UUID()
    let cxHandle = CXHandle(type: .phoneNumber, value: handle)
    let action = CXStartCallAction(call: uuid, handle: cxHandle)
    action.isVideo = false
    controller.request(CXTransaction(action: action)) { error in
        if let error { /* surface: couldn't start call */ }
    }
}

// End / hold from your own UI:
controller.request(CXTransaction(action: CXEndCallAction(call: uuid)))          { _ in }
controller.request(CXTransaction(action: CXSetHeldCallAction(call: uuid, onHold: true))) { _ in }

// Bundle actions atomically:
let tx = CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: true))
tx.addAction(CXSetHeldCallAction(call: uuid, onHold: true))
controller.request(tx) { _ in }
```

- `controller.request(_:completion:)` takes a `CXTransaction`; `requestTransaction(with:completion:)` takes a bare `[CXAction]`. Both route through your delegate's `perform` methods — **don't** mutate media directly in the button handler; do it in `perform`.
- `controller.callObserver` (`CXCallObserver`) reports the live set of `CXCall`s (hasEnded, isOutgoing, isOnHold, hasConnected) — use it to reconcile UI, not as the source of truth for your own signaling.
- **Answer/decline of an incoming call is driven by CallKit's UI**, not the controller — those arrive as `CXAnswerCallAction` / `CXEndCallAction` in the delegate.

<a id="pushkit"></a>
## PushKit VoIP push — the golden rule

> **On iOS 13+, every VoIP push MUST result in a synchronous `reportNewIncomingCall(with:update:)` inside the push handler, before you call its `completion`.** Miss it and the system kills the call, and repeated violations get your VoIP push token disabled — the app stops receiving VoIP pushes entirely.

```swift
import PushKit

final class VoIPPushHandler: NSObject, PKPushRegistryDelegate {
    let registry = PKPushRegistry(queue: nil)   // main queue
    let callManager: CallManager

    init(callManager: CallManager) {
        self.callManager = callManager
        super.init()
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
    }

    // Register the VoIP token with YOUR server (distinct from the standard APNs token).
    func pushRegistry(_ registry: PKPushRegistry,
                      didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        sendVoIPTokenToServer(credentials.token)   // Data → hex
    }

    func pushRegistry(_ registry: PKPushRegistry,
                      didInvalidatePushTokenFor type: PKPushType) {
        // Token gone — tell your server to stop sending, then re-register when able.
    }

    func pushRegistry(_ registry: PKPushRegistry,
                      didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType,
                      completion: @escaping () -> Void) {
        let dict = payload.dictionaryPayload
        let uuid = (dict["uuid"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        let handle = dict["handle"] as? String ?? "Unknown"
        let name = dict["callerName"] as? String

        // Report SYNCHRONOUSLY. Call PushKit's completion only from CallKit's completion.
        callManager.provider.reportNewIncomingCall(
            with: uuid,
            update: makeUpdate(handle: handle, name: name)
        ) { error in
            completion()   // <-- the one call that keeps your VoIP token alive
        }
    }
}
```

- **Even a malformed / "cancel" / stale push must report a call.** If the call is already over, report it then immediately `provider.reportCall(with:uuid, endedAt:Date(), reason:.remoteEnded)` — but *report first*. Never `return` from the handler without reporting.
- Do all reporting **before** any `await` / async network hop; kick signaling off only inside (or after) the CallKit completion. Blocking on the network first risks missing the synchronous-report window.
- The VoIP token is not the notification token — send the PushKit `credentials.token`, and re-send on every `didUpdate`.
- Server sends the push to APNs with topic `<bundle-id>.voip` and `apns-push-type: voip`. Payload details in `references/voip-push.md`.

<a id="directory"></a>
## Call Directory extension (caller ID + blocking)

A separate extension target that hands the OS a sorted list of numbers to **label** (caller ID) and/or **block**. It runs out-of-process, on demand, under tight memory limits — it does no networking; your host app stages data (App Group / shared DB) and the extension reads it.

```swift
import CallKit

class CallDirectoryHandler: CXCallDirectoryProvider {
    override func beginRequest(with context: CXCallDirectoryExtensionContext) {
        context.delegate = self

        if context.isIncremental {
            // Only the delta since last successful reload.
            addOrRemoveIncrementalEntries(to: context)
        } else {
            // Full rebuild: add ALL entries.
            addAllBlockingEntries(to: context)
            addAllIdentificationEntries(to: context)
        }
        context.completeRequest()
    }

    private func addAllIdentificationEntries(to context: CXCallDirectoryExtensionContext) {
        // MUST be in ascending numerical order. CXCallDirectoryPhoneNumber == Int64, E.164 (no +).
        let entries: [(CXCallDirectoryPhoneNumber, String)] = [
            (14085550101, "Acme Bank — Fraud Line"),
            (14085550125, "Acme Bank — Support"),
        ]
        for (number, label) in entries {
            context.addIdentificationEntry(withNextSequentialPhoneNumber: number, label: label)
        }
    }

    private func addAllBlockingEntries(to context: CXCallDirectoryExtensionContext) {
        for number in sortedBlockedNumbers {   // ascending, Int64
            context.addBlockingEntry(withNextSequentialPhoneNumber: number)
        }
    }

    private func addOrRemoveIncrementalEntries(to context: CXCallDirectoryExtensionContext) {
        context.addIdentificationEntry(withNextSequentialPhoneNumber: 14085550130, label: "Acme Bank — New")
        context.removeIdentificationEntry(withPhoneNumber: 14085550101)
        // context.removeAllIdentificationEntries() / removeAllBlockingEntries() for a reset
    }
}

extension CallDirectoryHandler: CXCallDirectoryExtensionContextDelegate {
    func requestFailed(for extensionContext: CXCallDirectoryExtensionContext,
                       withError error: Error) {
        // Log and recover. A crash/timeout/out-of-order add fails the WHOLE reload.
    }
}
```

- **Ordering is mandatory:** phone numbers must be added in strictly ascending order; one out-of-order add fails the entire request. Sort in the host app.
- **Incremental vs full:** honor `context.isIncremental`. On a full request, add everything. On incremental, apply only adds/removes since the last success. `remove*` methods are valid only in incremental mode.
- The host app triggers reloads with `CXCallDirectoryManager.sharedInstance.reloadExtension(withIdentifier:completionHandler:)` and checks user-enablement with `getEnabledStatusForExtension(withIdentifier:completionHandler:)`. Full flow, App Group staging, and memory-budget guidance in `references/call-directory.md`.

<a id="checklist"></a>
## Correctness checklist

- [ ] `UIBackgroundModes` includes both `voip` and `audio`; `NSMicrophoneUsageDescription` present.
- [ ] **Every** VoIP push calls `reportNewIncomingCall` synchronously; PushKit `completion()` fires only from CallKit's completion — no early `return`, even for stale/cancel pushes.
- [ ] VoIP token (`PKPushCredentials.token`) registered with the server and re-sent on `didUpdate`; handled `didInvalidatePushTokenFor`.
- [ ] One long-lived `CXProvider` + `CXCallController`; calls keyed by `UUID`; `CXProviderConfiguration()` (not deprecated `init(localizedName:)`).
- [ ] Every delegate action resolved with `fulfill()` or `fail()`; `providerDidReset` drops all calls and audio.
- [ ] Audio session **configured** (category/mode) in the answer/start action but **activated by CallKit**; media started in `didActivate`, released in `didDeactivate` — no manual `setActive(true)`.
- [ ] App-initiated call changes go through `CXCallController` transactions, not direct media mutation; incoming answer/decline handled as delegate actions.
- [ ] Remote endings use `reportCall(with:endedAt:reason:)`; local UI end handled as `CXEndCallAction`.
- [ ] `reportNewIncomingCall` completion error treated as "suppressed — do not proceed."
- [ ] Call Directory entries added in ascending numeric order; `isIncremental` honored; `remove*` only in incremental mode; `requestFailed` implemented.
- [ ] Region check: fall back to in-app call UI where CallKit is unavailable.
