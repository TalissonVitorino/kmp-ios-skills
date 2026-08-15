---
name: ios-simulator
description: "Drive the iOS/iPadOS Simulator from the command line with xcrun simctl for a fintech app — list/create/boot/shutdown/erase/delete/clone devices and runtimes; install/launch/terminate/uninstall apps; push remote APNs (aps JSON payload); openurl for custom-scheme deep links and Universal Links; privacy grant/revoke/reset (photos, contacts, location, camera, calendar…); location set/run/clear (fixed coords + built-in scenarios); status_bar override (9:41 time, battery, wifi/cellular bars) for App Store screenshots; io screenshot/recordVideo; spawn log stream --predicate; get_app_container; addmedia; keychain add-root-cert. Also which behaviors REQUIRE a real device (camera capture, Secure Enclave, App Attest/DeviceCheck, some background modes). Use when scripting Simulator setup, CI screenshots, notification/deep-link testing, or permission fixtures. Siblings: push-notifications (APNs auth/production), deep-linking (Universal Links/associated domains), ios-testing (XCUITest launch args), device-integrity (App Attest — real device only), swift-security (Secure Enclave), debugging-instruments (LLDB/Instruments)."
---

# iOS Simulator (`xcrun simctl`)

Command-line control of the iOS/iPadOS/watchOS/tvOS Simulator for scripting,
CI, and local fixtures. Everything routes through `simctl`; the Simulator.app GUI
is optional. Targets Xcode 16/17, iOS 26 era.

- **Device counterpart:** hardware-backed features (camera, Secure Enclave, App Attest) do **not** work in the Simulator — see [Simulator vs. real device](#device-only) and cross-reference `device-integrity` / `swift-security`.
- **UI-test driving** (tap/type/assert) is XCUITest's job, not `simctl` — see `ios-testing`. `simctl` sets up state *around* the test (permissions, push, media, location).

## Contents

- [Device identity & `booted`](#identity)
- [Lifecycle: create / boot / erase / delete](#lifecycle)
- [Apps: install / launch / terminate / uninstall](#apps)
- [Push notifications (APNs)](#push)
- [Deep links & Universal Links (`openurl`)](#openurl)
- [Privacy permissions](#privacy)
- [Location](#location)
- [Status bar overrides](#status-bar)
- [Screenshots & video (`io`)](#io)
- [Logs (`spawn log stream`)](#logs)
- [App container, media, keychain](#misc)
- [Simulator vs. real device](#device-only)
- [Checklist](#checklist)
- Depth: `references/command-reference.md`, `references/device-vs-simulator.md`

<a id="identity"></a>
## Device identity & `booted`

Every device has a UDID. Most subcommands take a **device specifier**: a UDID, a
device name, or the literal `booted` (the single currently-booted device — errors
if zero or more than one is booted).

```bash
xcrun simctl list devices           # all devices, grouped by runtime; shows (Booted)
xcrun simctl list devices booted     # only booted ones
xcrun simctl list devices available -j   # JSON; filter to installed runtimes only
xcrun simctl list runtimes           # installed iOS/watchOS/… runtimes + identifiers
xcrun simctl list devicetypes        # e.g. com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro
```

- Parse JSON (`-j` / `--json`), never scrape the human table, in scripts. `devices` JSON keys each list by runtime identifier; each entry has `udid`, `name`, `state`, `isAvailable`.
- Resolve one UDID in a script:

```bash
UDID=$(xcrun simctl list devices -j \
  | jq -r '.devices[][] | select(.name=="iPhone 16 Pro" and .isAvailable) | .udid' | head -1)
```

- A name is ambiguous if it exists under multiple runtimes — prefer a resolved UDID in CI.

<a id="lifecycle"></a>
## Lifecycle: create / boot / erase / delete

```bash
# Create: <name> <devicetype> [<runtime>]
UDID=$(xcrun simctl create "CI-iPhone" \
  "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro" \
  "com.apple.CoreSimulator.SimRuntime.iOS-26-0")

xcrun simctl boot     "$UDID"        # boot headless (no GUI)
open -a Simulator                    # optionally show the GUI window
xcrun simctl bootstatus "$UDID" -b   # wait until fully booted, then exit
xcrun simctl shutdown "$UDID"        # (or: shutdown all)
xcrun simctl erase    "$UDID"        # wipe to factory — device must be shut down (or: erase all)
xcrun simctl delete   "$UDID"        # remove device (or: delete unavailable / all)
xcrun simctl clone    "$UDID" "CI-iPhone-copy"   # snapshot a configured device
```

- `boot` is idempotent-ish: booting an already-booted device errors — guard with a state check or `|| true` in CI.
- `bootstatus -b` blocks until services are up; use it before `install`/`launch` to avoid races. `boot` returning is **not** the same as "ready".
- `erase all` requires every device shut down first (`shutdown all && erase all`).
- Reset a corrupt CoreSimulator state as a last resort: `xcrun simctl shutdown all && xcrun simctl erase all`.
- Isolate CI state with a private set: prepend `--set <path>` (e.g. `xcrun simctl --set ./.sim create …`) so devices don't pollute the developer's default set.

<a id="apps"></a>
## Apps: install / launch / terminate / uninstall

```bash
xcrun simctl install   booted /path/to/MyApp.app          # install a built .app (Simulator slice)
xcrun simctl launch    booted com.example.myapp            # launch by bundle id
xcrun simctl terminate booted com.example.myapp
xcrun simctl uninstall booted com.example.myapp
```

- Install the **Simulator build** (`.app` from a `iphonesimulator` SDK build), not a device `.ipa`.
- Launch with arguments / environment (consumed by XCUITest launch arguments or your own flags):

```bash
xcrun simctl launch booted com.example.myapp -uiTestMode YES        # launch args after bundle id
SIMCTL_CHILD_MY_FLAG=1 xcrun simctl launch booted com.example.myapp  # SIMCTL_CHILD_* → app's env
xcrun simctl launch --console booted com.example.myapp               # attach stdout/stderr
xcrun simctl launch --wait-for-debugger booted com.example.myapp
```

- `SIMCTL_CHILD_<VAR>` sets `<VAR>` in the launched process's environment — the standard way to inject config/feature flags at launch. Pairs with `ios-testing` `XCUIApplication().launchArguments`.

<a id="push"></a>
## Push notifications (APNs)

Simulate a **remote** notification without a real APNs round-trip.

```bash
xcrun simctl push booted com.example.myapp payload.json
xcrun simctl push booted com.example.myapp -            # read payload from stdin
```

```json
{
  "Simulator Target Bundle": "com.example.myapp",
  "aps": {
    "alert": { "title": "Payment received", "body": "You got $50.00" },
    "badge": 1,
    "sound": "default"
  }
}
```

- Payload rules (enforced): top-level **object**, must contain a valid `aps` key, and be **≤ 4096 bytes**.
- The bundle id can be supplied as the CLI arg **or** via the `"Simulator Target Bundle"` top-level key; the CLI arg wins if both are present.
- **Only ordinary remote pushes.** VoIP (PushKit), Complication, and File Provider pushes are **not** simulable — those need a real device / real APNs. For actual APNs auth-key/token setup and production delivery see `push-notifications`.
- `simctl push` neither prompts nor authorizes notifications itself: the app must have registered for remote notifications and hold notification authorization. There is **no** `notifications` TCC service, so you can't pre-grant it via `privacy` — drive the authorization prompt in-app (or via XCUITest).

<a id="openurl"></a>
## Deep links & Universal Links (`openurl`)

```bash
xcrun simctl openurl booted "myapp://transfer?amount=50&to=alice"   # custom URL scheme
xcrun simctl openurl booted "https://pay.example.com/invoice/42"    # Universal Link
xcrun simctl openurl booted "mailto:test@example.com"              # system-handled URL
```

- Custom-scheme links route to whichever installed app declares the scheme.
- **Universal Links** open in your app only if it ships the `applinks:` Associated Domains entitlement and the `apple-app-site-association` (AASA) file resolves for that domain; otherwise the URL opens in Safari. See `deep-linking` for AASA/entitlement setup.
- **Known issue (Xcode 26 simulators):** Universal Links may fail to route to the app in the Simulator even when correctly configured — verify Universal Link behavior on a real device, and use custom schemes for Simulator smoke tests.

<a id="privacy"></a>
## Privacy permissions

Pre-grant or reset TCC permissions so tests don't stall on system prompts.

```bash
xcrun simctl privacy booted grant  photos   com.example.myapp
xcrun simctl privacy booted revoke location com.example.myapp
xcrun simctl privacy booted reset  all       com.example.myapp   # back to "unasked" → prompt reappears
xcrun simctl privacy booted reset  contacts  com.example.myapp
```

- Actions: `grant`, `revoke`, `reset`. A bundle id is required for `grant`/`revoke`; `reset` accepts a bundle id or applies broadly.
- Services (per `simctl privacy` in Xcode 26): `all`, `calendar`, `contacts-limited`, `contacts`, `location`, `location-always`, `photos-add`, `photos`, `media-library`, `microphone`, `motion`, `reminders`, `siri`, plus `camera` (accepted although omitted from the help text). There is **no** `faceid`, `speech-recognition`, `user-tracking`, or `notifications` service — `simctl privacy` rejects those names; run `xcrun simctl privacy` with no args for the authoritative list.
- `grant`/`revoke` cover services routed through TCC. Some prompts (notification authorization, the ATT dialog) are managed by the app/OS, are **not** standalone `privacy` services, and still surface — drive them in-app; `privacy reset all` returns TCC state broadly to the fresh-prompt state.
- Pre-granting `camera`/`microphone` only silences the *permission* prompt; the Simulator still has **no real camera** (see [device-only](#device-only)).

<a id="location"></a>
## Location

```bash
xcrun simctl location booted set 40.7580,-73.9855          # fixed lat,long (Times Square)
xcrun simctl location booted list                          # built-in scenario names
xcrun simctl location booted run "City Run"                # replay a built-in scenario
xcrun simctl location booted start --speed=25 \
  40.75,-73.98 40.76,-73.97                                # follow a waypoint path
xcrun simctl location booted clear                         # revert to no simulated location
```

- `set` pins one coordinate; `run` replays Apple's built-in scenarios (e.g. City Run, Freeway Drive); `start` follows supplied waypoints (optionally `--speed`, `--distance`, `--interval`); `clear` removes the override.
- This drives CoreLocation for the whole device — the app must still hold `location` (or `location-always`) authorization; grant it via [`privacy`](#privacy).

<a id="status-bar"></a>
## Status bar overrides

Deterministic status bar for App Store screenshots ("9:41", full battery, full bars).

```bash
xcrun simctl status_bar booted override \
  --time "9:41" \
  --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 \
  --batteryState charged --batteryLevel 100

xcrun simctl status_bar booted clear        # remove overrides
```

- Flags: `--time`, `--dataNetwork` (`wifi`/`3g`/`4g`/`lte`/`5g`…), `--wifiMode`/`--wifiBars` (0–3), `--cellularMode`/`--cellularBars` (0–4), `--batteryState` (`charging`/`charged`/`discharging`) + `--batteryLevel` (0–100), `--operatorName`.
- Overrides are **not persistent** — they reset when the device shuts down / relaunches. Re-apply in the screenshot script right before capturing.
- Run `xcrun simctl status_bar booted override` with no flags to print the full option list for the installed Xcode.

<a id="io"></a>
## Screenshots & video (`io`)

```bash
xcrun simctl io booted screenshot shot.png                 # PNG of the current screen
xcrun simctl io booted screenshot --mask=black shot.png    # notch/corner mask: ignored|alpha|black
xcrun simctl io booted recordVideo --codec=h264 demo.mov   # Ctrl-C to stop; default codec hevc
xcrun simctl io booted recordVideo --mask=black --force out.mp4
```

- `screenshot`: `--type` (`png`/`jpeg`), `--display` (`internal`/`external`), `--mask` (`ignored`/`alpha`/`black`). Use `alpha`/`black` for rounded/notched framing in marketing shots.
- `recordVideo`: `--codec` (`hevc` default, or `h264` for broader compatibility), `--mask`, `--force` (overwrite). Stop with `SIGINT` (Ctrl-C); in scripts send `kill -INT` to the recorder PID.

<a id="logs"></a>
## Logs (`spawn log stream`)

Run a process inside the Simulator; commonly the unified-logging `log` tool.

```bash
# Live stream, filtered by predicate:
xcrun simctl spawn booted log stream \
  --level debug \
  --predicate 'subsystem == "com.example.myapp"'

# Filter by process:
xcrun simctl spawn booted log stream --predicate 'processImagePath ENDSWITH "myapp"'

# Dump a past window instead of streaming:
xcrun simctl spawn booted log show --last 5m --predicate 'category == "network"'
```

- The `--predicate` is an `NSPredicate` over unified-logging fields: `subsystem`, `category`, `process`, `processImagePath`, `eventMessage`, `messageType`. Quote carefully in the shell.
- Set `subsystem`/`category` in your `Logger` (os.log) so this filtering is precise — see `debugging-instruments` for the LLDB/Instruments side.

<a id="misc"></a>
## App container, media, keychain

```bash
# Absolute path to a container (inspect sandbox files, DBs, Documents):
xcrun simctl get_app_container booted com.example.myapp data     # app|data|groups|<group id>
DB="$(xcrun simctl get_app_container booted com.example.myapp data)/Documents/app.sqlite"

# Seed the photo library / media:
xcrun simctl addmedia booted photo1.jpg clip.mov

# Trust a self-signed root CA (e.g. Proxyman/Charles TLS interception in dev):
xcrun simctl keychain booted add-root-cert ./proxymanCA.pem
xcrun simctl keychain booted reset                              # clear the device keychain
```

- `get_app_container` container types: `app` (the bundle), `data` (the sandbox — Documents/Library/tmp), `groups` (all App Groups), or a specific `group.<id>`.
- `addmedia` imports into Photos; grant `photos` via [`privacy`](#privacy) if the app reads them.
- `keychain add-root-cert` installs a CA so the Simulator trusts a dev proxy's TLS certs. **Dev only** — never a substitute for real certificate handling; SPKI pinning (see `swift-security`) will still reject an interception proxy by design.
- `--set <path>` also applies here (`xcrun simctl --set previews keychain booted add-root-cert …`) to target a specific device set.

<a id="device-only"></a>
## Simulator vs. real device

The Simulator runs your app against the **host Mac's** CPU, filesystem, and (in
part) frameworks — it is not an emulator of Apple hardware. Anything backed by
device silicon or peripherals behaves differently or is absent.

**Requires a real device (cannot be validated in the Simulator):**

- **Camera capture** — `AVCaptureDevice` for the camera is unavailable; there is no camera feed. (Photo *library* works; use `addmedia`.) Cross-ref `photokit`.
- **Secure Enclave** — `SecureEnclave.isAvailable` is `false`; hardware-backed keys don't exist. Guard and provide a software fallback — see `swift-security`.
- **App Attest / DeviceCheck** — depend on the Secure Enclave; attestation fails. Test on hardware — see `device-integrity`.
- **VoIP / PushKit, Complication, File Provider pushes** — not deliverable via `simctl push`.
- **Real modem/cellular, Bluetooth, NFC, motion sensors, barometer, true GPS** — absent or coarse (location is *simulated*, not sensed).
- **Some background execution** (real background app refresh scheduling, precise power/thermal behavior) and **Face ID/Touch ID hardware** — biometrics are *simulated* via the Simulator menu (Features ▸ Face ID ▸ Enrolled / Matching Face), not a real sensor.

**Gate hardware paths at compile time so Simulator builds stay runnable:**

```swift
#if targetEnvironment(simulator)
    // stub: no camera / no Secure Enclave — return a fixture or software key
#else
    // real AVCaptureSession / SecureEnclave key
#endif
```

- `#if targetEnvironment(simulator)` is a **compile-time** switch (not a runtime `if`), so simulator-only stubs are compiled out of device builds. Prefer feature-detection at runtime (`SecureEnclave.isAvailable`, `UIImagePickerController.isSourceTypeAvailable(.camera)`) where a runtime check is more honest than a build flag.

<a id="checklist"></a>
## Correctness checklist

- [ ] Scripts parse `simctl list -j` JSON and resolve a **UDID**, not a possibly-ambiguous device name.
- [ ] `bootstatus -b` (not bare `boot`) gates `install`/`launch` so services are ready.
- [ ] CI uses `--set <path>` to isolate the device set and cleans up (`shutdown`/`delete`) after.
- [ ] Simulator (`iphonesimulator` SDK) `.app` installed — not a device `.ipa`.
- [ ] Push payload is a top-level object with a valid `aps` key and ≤ 4096 bytes; only remote (non-VoIP) pushes.
- [ ] Permissions pre-set with `privacy grant`; `privacy reset` used to test the first-run prompt path.
- [ ] Universal Links verified on a **real device** (Simulator routing is unreliable on Xcode 26); custom schemes used for Simulator smoke tests.
- [ ] Status-bar override re-applied right before each screenshot (it doesn't persist across boots).
- [ ] `recordVideo` stopped with `SIGINT`; `--codec h264` when broad compatibility matters.
- [ ] Camera, Secure Enclave, App Attest/DeviceCheck, PushKit paths tested on hardware, gated with `#if targetEnvironment(simulator)` or runtime feature checks.
- [ ] `keychain add-root-cert` confined to dev; production relies on ATS + pinning (`swift-security`), which correctly defeats interception proxies.
