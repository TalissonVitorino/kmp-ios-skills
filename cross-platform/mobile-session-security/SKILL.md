---
name: mobile-session-security
description: "KMP + iOS/Android session hardening for a fintech app — inactivity auto-lock (track last-interaction, idle timeout, biometric/passcode re-auth), biometric re-lock on background/foreground with a grace period, and screen-capture/snapshot protection. Android: WindowManager FLAG_SECURE (blocks screenshots + recents thumbnail + recording), ProcessLifecycleOwner foreground/background, BiometricPrompt re-auth. iOS: touch interception (UIWindow.sendEvent override), app-switcher snapshot hiding via a resign-active blur overlay, UIScreen.isCaptured / capturedDidChangeNotification recording detection — with the honest caveat that iOS has NO API to block screenshots. A shared SessionLockController drives the state. Use when adding idle logout, re-lock on resume, or hiding balances/PANs from snapshots and screen recording. Cross-refs: swift-security (Keychain/LAContext), authentication (biometrics), mobile-security (Keystore), app-lifecycle (scene phases), expect-actual (KMP boundary)."
---

# Mobile Session Security (KMP + iOS / Android)

Session-layer hardening for a fintech app: lock the session after inactivity or on
background, force biometric/passcode re-auth to resume, and keep sensitive UI
(balances, PANs, tokens) out of app-switcher snapshots and screen recordings.
Grounded in AndroidX Lifecycle/BiometricPrompt, WindowManager, UIKit, and
LocalAuthentication.

- **Secret storage / biometric-gated keys (iOS):** `swift-security` (Keychain, `LAContext`, Secure Enclave).
- **Secret storage (Android/KMP):** `mobile-security` (Keystore, `setUserAuthenticationRequired`).
- **Login / passkeys / OAuth:** `authentication`. This skill covers *re-auth of an existing session*, not first sign-in.
- **Scene/process lifecycle plumbing:** `app-lifecycle`. **KMP boundary shape:** `expect-actual`.

## Contents

- [Threat model / fintech framing](#threat-model)
- [Shared KMP SessionLockController](#controller)
- [Inactivity auto-lock](#inactivity)
- [Re-lock on background / foreground](#background)
- [Biometric / passcode re-auth](#reauth)
- [Screen-capture / snapshot protection](#capture)
- [Correctness checklist](#checklist)

<a id="threat-model"></a>
## Threat model / fintech framing

- **Idle device left unlocked** → someone else sees balances or moves money. Mitigation: **inactivity auto-lock** with re-auth.
- **App-switcher snapshot** → the OS caches a screenshot of the last frame for the multitasking UI; a balance/PAN leaks there. Mitigation: **hide sensitive UI on resign-active** (iOS) / `FLAG_SECURE` (Android).
- **Screen recording / mirroring / AirPlay** → exfiltrates whatever is on screen. Mitigation: `FLAG_SECURE` (Android, hard block) / `UIScreen.isCaptured` detect-and-hide (iOS, best-effort).
- **Compliance:** idle re-auth and snapshot masking are expectations under PCI-DSS-adjacent mobile guidance and OWASP **MASVS-STORAGE-2** (no sensitive data in backups/screenshots) and **MASVS-AUTH**. Treat them as required controls, not nice-to-haves.
- **Honest limits:** the lock is a UX/defense-in-depth control, not a substitute for keeping secrets in the Keychain/Keystore (`swift-security` / `mobile-security`). A jailbroken/rooted device can bypass any client-side lock — gate the *secret material* on biometrics, not just a boolean.

<a id="controller"></a>
## Shared KMP SessionLockController

Keep the lock **state machine** in `commonMain`; feed it platform interaction/lifecycle
events and let each platform render the lock screen. A plain common interface plus a
shared implementation is enough — no `expect/actual` needed for the core logic (only
for the clock, if you want to inject it for tests).

```kotlin
// commonMain
enum class SessionState { UNLOCKED, LOCKED }

class SessionLockController(
    private val idleTimeoutMs: Long = 2 * 60_000,   // N minutes idle
    private val backgroundGraceMs: Long = 10_000,   // brief resume without re-auth
    private val now: () -> Long = { Clock.System.now().toEpochMilliseconds() },
) {
    private val _state = MutableStateFlow(SessionState.LOCKED) // start locked
    val state: StateFlow<SessionState> = _state.asStateFlow()

    private var lastInteraction = now()
    private var backgroundedAt: Long? = null

    /** Call on every user touch/keystroke while UNLOCKED. Cheap; do not allocate. */
    fun onUserInteraction() {
        if (_state.value == SessionState.UNLOCKED) lastInteraction = now()
    }

    /** Poll from a foreground timer (~1s). Locks once idle exceeds the timeout. */
    fun checkIdle() {
        if (_state.value == SessionState.UNLOCKED &&
            now() - lastInteraction >= idleTimeoutMs) lock()
    }

    fun onEnterBackground() { backgroundedAt = now() }

    /** On foreground: lock if we exceeded the grace period (or were already idle). */
    fun onEnterForeground() {
        val bg = backgroundedAt ?: return
        backgroundedAt = null
        if (now() - bg >= backgroundGraceMs) lock()
        else lastInteraction = now() // within grace: treat resume as fresh activity
    }

    fun lock() { _state.value = SessionState.LOCKED }

    /** Call ONLY after a successful biometric/passcode evaluation. */
    fun unlock() {
        _state.value = SessionState.UNLOCKED
        lastInteraction = now()
    }
}
```

- Consume `state` from Compose (`collectAsStateWithLifecycle`) and from SwiftUI (via SKIE/Flow bridge, see `kmp-ios-integration`) to overlay a full-screen lock gate.
- The controller only tracks state — **the actual re-auth prompt is platform code** (below). Never flip to `UNLOCKED` from anywhere except a verified auth callback.

<a id="inactivity"></a>
## Inactivity auto-lock

Track last-interaction on each platform, drive `checkIdle()` from a 1 Hz foreground timer.

### Android — interaction + idle timer

Override `Activity.dispatchTouchEvent` (and key events) to stamp interaction. Run the
idle poll only while the Activity is resumed.

```kotlin
// androidMain — in your single Activity (or a base Activity)
class MainActivity : ComponentActivity() {
    private val session: SessionLockController by inject() // Koin/DI

    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        session.onUserInteraction()
        return super.dispatchTouchEvent(ev)
    }
    override fun dispatchKeyEvent(ev: KeyEvent): Boolean {
        session.onUserInteraction()
        return super.dispatchKeyEvent(ev)
    }

    override fun onResume() {
        super.onResume()
        idleJob = lifecycleScope.launch {
            while (isActive) { session.checkIdle(); delay(1_000) }
        }
    }
    override fun onPause() { super.onPause(); idleJob?.cancel() }
    private var idleJob: Job? = null
}
```

- `dispatchTouchEvent` sees *every* touch before children consume it — the reliable interaction hook. Do only a cheap timestamp write here; no allocation, no logging.
- Cancel the timer in `onPause` so it never runs in the background (background locking is handled separately, below).

### iOS — intercept touches via a UIWindow subclass

Override `sendEvent(_:)` on a custom `UIWindow`; every touch/press flows through it.

```swift
// iosMain / iOS app — custom window
final class SessionWindow: UIWindow {
    var onInteraction: (() -> Void)?
    override func sendEvent(_ event: UIEvent) {
        if event.type == .touches || event.type == .presses { onInteraction?() }
        super.sendEvent(event)
    }
}
```

Wire it up and run a repeating timer while active. For a SwiftUI app, host the window
in the `UIWindowSceneDelegate`, or reuse the scene's existing window and swap its class.

```swift
// Drive the shared controller's idle check on a 1 Hz timer.
window.onInteraction = { session.onUserInteraction() }

idleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
    session.checkIdle()
}
// Invalidate the timer on resign-active; recreate on become-active.
```

- `sendEvent` is the canonical app-wide touch hook — it fires even for gestures children consume, so idle tracking stays accurate.
- A `Timer` only fires while the app is foreground/active, which is exactly the idle window you care about. Background locking is handled by lifecycle notifications, next.

<a id="background"></a>
## Re-lock on background / foreground

Lock when the app leaves the foreground; require unlock on return, minus an optional
short grace period (so a fast task-switch or a system biometric sheet doesn't force a
re-auth loop).

### Android — ProcessLifecycleOwner

`ProcessLifecycleOwner` (`androidx.lifecycle:lifecycle-process`) emits `ON_START` /
`ON_STOP` for the **whole process**, debounced across Activity rotations — unlike a
single Activity's callbacks.

```kotlin
// Application.onCreate()
ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
    override fun onStart(owner: LifecycleOwner) { session.onEnterForeground() }
    override fun onStop(owner: LifecycleOwner)  { session.onEnterBackground() }
})
```

- `onStop` fires once when the app truly backgrounds (not on a config change) — the correct signal to start the background clock.
- Requires `implementation("androidx.lifecycle:lifecycle-process:<version>")`.

### iOS — scene / app active notifications

Use `willResignActive` (about to lose foreground — also fires for the app switcher and
incoming sheets) to start the background clock, and `didBecomeActive` to evaluate the
grace period. For a scene-based app, prefer the `UIScene` equivalents
(`willDeactivateNotification` / `didActivateNotification`).

```swift
let nc = NotificationCenter.default
nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
    session.onEnterBackground()
}
nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
    session.onEnterForeground()   // locks if past the grace period
}
```

- `willResignActive` is also where you show the snapshot cover (below) — the app switcher captures the frame at resign-active, so cover *before* backgrounding, not on `didEnterBackground` (too late).
- Keep the grace period short (seconds). For high-value fintech flows (money movement), set `backgroundGraceMs = 0` so any background always re-locks.

<a id="reauth"></a>
## Biometric / passcode re-auth

Only call `SessionLockController.unlock()` from a **successful** biometric/passcode
callback. Prefer passcode fallback so users are never locked out.

### Android — BiometricPrompt

`androidx.biometric:biometric` (unifies fingerprint/face/credential across API levels).

```kotlin
fun promptUnlock(activity: FragmentActivity, session: SessionLockController) {
    val canAuth = BiometricManager.from(activity).canAuthenticate(
        BIOMETRIC_STRONG or DEVICE_CREDENTIAL)
    if (canAuth != BiometricManager.BIOMETRIC_SUCCESS) { /* enroll / degrade */ return }

    val prompt = BiometricPrompt(activity, ContextCompat.getMainExecutor(activity),
        object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(r: BiometricPrompt.AuthenticationResult) {
                session.unlock()
            }
            override fun onAuthenticationError(code: Int, msg: CharSequence) {
                // USER_CANCELED / LOCKOUT — stay LOCKED, offer retry
            }
        })

    val info = BiometricPrompt.PromptInfo.Builder()
        .setTitle("Unlock")
        .setAllowedAuthenticators(BIOMETRIC_STRONG or DEVICE_CREDENTIAL) // device PIN fallback
        .build()                                    // no setNegativeButtonText when DEVICE_CREDENTIAL is allowed
    prompt.authenticate(info)
}
```

- `BIOMETRIC_STRONG` (Class 3) is required to gate a Keystore key with
  `setUserAuthenticationRequired(true)` — tie the unlock to *decrypting the session
  token* (see `mobile-security`), not just to a boolean.
- Handle `ERROR_LOCKOUT` / `ERROR_LOCKOUT_PERMANENT`: allowing `DEVICE_CREDENTIAL` lets the user fall back to the device PIN.

### iOS — LAContext re-evaluation

Fresh `LAContext` per unlock; `.deviceOwnerAuthentication` includes passcode fallback.
Full LocalAuthentication detail (policies, `LAError` cases, biometry-gated Keychain
items) lives in `swift-security`.

```swift
import LocalAuthentication

func promptUnlock(_ session: SessionLockController) async {
    let ctx = LAContext()
    var err: NSError?
    guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return }
    do {
        try await ctx.evaluatePolicy(.deviceOwnerAuthentication,
                                     localizedReason: "Unlock your account")
        await MainActor.run { session.unlock() }
    } catch { /* .userCancel / .biometryLockout — stay LOCKED */ }
    ctx.invalidate()
}
```

- Strongest binding: instead of trusting the `evaluatePolicy` boolean, read a
  biometry-gated Keychain item (`kSecAttrAccessControl` + `.biometryCurrentSet`) and use
  it to decrypt the session — see `swift-security`. A patched boolean can be skipped; a
  gated key cannot.
- `NSFaceIDUsageDescription` is required in `Info.plist` or Face ID calls crash.

<a id="capture"></a>
## Screen-capture / snapshot protection

### Android — FLAG_SECURE (real block)

`FLAG_SECURE` marks the window content secure: the OS blocks **screenshots**, **screen
recording**, **casting/mirroring**, and blanks the **recents/app-switcher thumbnail** —
all in one flag.

```kotlin
// Whole-Activity: set before setContentView.
window.setFlags(
    WindowManager.LayoutParams.FLAG_SECURE,
    WindowManager.LayoutParams.FLAG_SECURE)
```

Per-screen toggle in Compose — add on enter, clear on exit:

```kotlin
@Composable
fun SecureScreen() {
    val window = (LocalContext.current as Activity).window
    DisposableEffect(Unit) {
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        onDispose { window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE) }
    }
    // ...sensitive content
}
```

- **Caveat — it's a *window* flag, not a composable one.** All Compose screens share the
  Activity window, so toggling per-screen flips security for the whole window; when
  masking only some screens, guarantee the flag is set before the sensitive frame renders
  and reliably cleared. Simplest robust policy for a fintech app: set `FLAG_SECURE` once
  for the whole Activity and leave it on.
- Content in a **separate window** (dialogs, `Popup`/`Dropdown` with their own window, some `presentation`/external displays) does **not** inherit the flag — secure those windows explicitly.
- Recents blanking follows automatically from `FLAG_SECURE`; no separate app-switcher handling is needed on Android. Emulators without secure display may still allow capture — never rely on it as your only control.

### iOS — no screenshot block; snapshot hiding + recording detection

**Be explicit: iOS has NO public API to prevent the user from taking a screenshot.**
You cannot block it, and `userDidTakeScreenshotNotification` only fires *after* the fact
(useful for audit logging, not prevention). What you *can* do:

**1. Hide sensitive UI in the app switcher.** The system snapshots your UI at
resign-active for the multitasking card. Cover it with an opaque/blurred overlay, remove
on active.

```swift
final class PrivacyCover {
    private var cover: UIView?
    func show(in window: UIWindow) {
        guard cover == nil else { return }
        let v = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        v.frame = window.bounds
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(v)
        cover = v
    }
    func hide() { cover?.removeFromSuperview(); cover = nil }
}
// show(in:) on willResignActive; hide() on didBecomeActive — matches the lock hooks above.
```

**2. Detect screen recording / mirroring / AirPlay** via `UIScreen.isCaptured` and hide
content while captured. This is **best-effort** (mirroring/recording only — not
screenshots).

```swift
// Initial check + observe changes.
func startCaptureMonitoring(hide: @escaping (Bool) -> Void) {
    hide(UIScreen.main.isCaptured)                       // true = being recorded/mirrored/AirPlayed
    NotificationCenter.default.addObserver(
        forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main) { _ in
        hide(UIScreen.main.isCaptured)
    }
}
```

- **iOS 17+ modern path:** register for the `UITraitSceneCaptureState` trait via
  `registerForTraitChanges` and read `traitCollection.sceneCaptureState` — this is
  scene-scoped and the forward-looking API as `UIScreen.main` heads toward deprecation
  (prefer `view.window?.windowScene?.screen`). Keep the `UIScreen.isCaptured` path as the
  pre-17 fallback.
- **3. Per-field secure entry trick.** A `UITextField` with `isSecureTextEntry = true`
  renders into a layer the system excludes from screenshots; some apps embed sensitive
  content inside that field's secure layer to keep a *specific* view out of captures. This
  is a fragile, unsupported hack that breaks across iOS versions — use only for a single
  high-value field, never as a general control, and never claim it "blocks screenshots."
- **Bottom line:** on iOS you mask the app switcher and react to recording; you do **not**
  prevent screenshots. Design so a leaked screenshot is low-value — mask full PANs, avoid
  rendering raw secrets — and keep the real secrets in the Keychain (`swift-security`).

<a id="checklist"></a>
## Correctness checklist

- [ ] `SessionState` starts **LOCKED**; `unlock()` is reachable *only* from a verified biometric/passcode callback.
- [ ] Idle timer runs **foreground-only** (cancelled in `onPause` / on resign-active); interaction stamp is a cheap timestamp write, no allocation/logging.
- [ ] Interaction captured app-wide: Android `dispatchTouchEvent`/`dispatchKeyEvent`; iOS `UIWindow.sendEvent`.
- [ ] Background lock uses **`ProcessLifecycleOwner`** (Android, process-wide, survives rotation) and `willResignActive`/`didBecomeActive` (iOS) — not per-Activity callbacks alone.
- [ ] Grace period is short; money-movement flows use grace = 0 (always re-lock on background).
- [ ] Re-auth allows passcode fallback: Android `DEVICE_CREDENTIAL`, iOS `.deviceOwnerAuthentication`; `ERROR_LOCKOUT` / `.biometryLockout` handled without dead-ending the user.
- [ ] Unlock gates the **session secret** (biometry-bound Keystore/Keychain key), not just a boolean — see `mobile-security` / `swift-security`.
- [ ] Android: `FLAG_SECURE` set (screenshots + recording + recents all covered); separate windows (dialogs/popups) secured explicitly; per-screen toggling verified to set-before-render / clear-after.
- [ ] iOS: resign-active **privacy cover** installed *before* backgrounding; `UIScreen.isCaptured` (or `sceneCaptureState` on 17+) monitored to hide during recording.
- [ ] iOS screenshot reality acknowledged: **no block exists**; `userDidTakeScreenshotNotification` used only for audit; UI designed so a screenshot leaks nothing critical (masked PANs, no raw secrets on screen).
- [ ] `NSFaceIDUsageDescription` present (iOS); `androidx.lifecycle:lifecycle-process` + `androidx.biometric:biometric` on the classpath (Android).
