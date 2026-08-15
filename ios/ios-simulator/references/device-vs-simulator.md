# Simulator vs. real device — capability matrix (fintech focus)

The Simulator shares the host Mac's hardware and some frameworks; it does not
emulate Apple silicon or peripherals. Anything hardware-backed is absent or
faked. For a fintech app the security-critical gaps matter most.

## Matrix

| Capability | Simulator | Notes / where to test |
|---|---|---|
| Photo library (`PHPhotoLibrary`) | ✅ | seed with `simctl addmedia`; grant `photos` |
| Camera capture (`AVCaptureDevice`) | ❌ | no camera feed; real device only (`photokit`) |
| Secure Enclave (`SecureEnclave`) | ❌ | `isAvailable == false`; software fallback (`swift-security`) |
| App Attest (`DCAppAttestService`) | ❌ | needs Secure Enclave; real device (`device-integrity`) |
| DeviceCheck (`DCDevice`) | ❌ | real device (`device-integrity`) |
| Face ID / Touch ID | ⚠️ simulated | Features ▸ Face ID ▸ Enrolled/Matching; no real biometric sensor (`swift-security`, `authentication`) |
| Keychain (`SecItem`) | ✅ | data-protection classes behave; but no SE-gated keys |
| Remote push (`simctl push`) | ✅ | ordinary `aps` only |
| VoIP / PushKit | ❌ | real device + real APNs (`callkit`, `push-notifications`) |
| Universal Links | ⚠️ | flaky on Xcode 26 simulators; verify on device (`deep-linking`) |
| Location | ⚠️ simulated | injected via `simctl location`, not sensed GPS |
| Motion / barometer / true GPS / NFC / Bluetooth | ❌ | absent; real device (`core-nfc`) |
| Apple Pay / Wallet provisioning | ⚠️ | sandbox test cards behave differently; validate on device (`passkit`) |
| StoreKit purchases | ✅ (StoreKit testing) | local `.storekit` config works in sim (`storekit`) |
| Background app refresh scheduling / thermal / power | ⚠️ | timing/behavior differ from hardware (`background-processing`, `metrickit`) |

Legend: ✅ works · ⚠️ simulated/partial · ❌ unavailable.

## Compile- vs. run-time gating

```swift
// Compile-time: simulator-only code is stripped from device builds.
#if targetEnvironment(simulator)
let attestationSupported = false
#else
let attestationSupported = true
#endif

// Runtime feature-detection — preferred when a build flag would lie
// (e.g. a device without an enrolled biometric, or an older chip):
guard SecureEnclave.isAvailable else { return softwareKeyFallback() }
guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
```

- Use `#if targetEnvironment(simulator)` for code that literally cannot **compile/link** against a simulator (a device-only symbol) or for injecting test fixtures.
- Use runtime checks (`SecureEnclave.isAvailable`, `DCAppAttestService.shared.isSupported`, source-type availability) for capability that varies by *device*, not just sim-vs-device — they stay honest on real hardware too.
- Never ship a security decision that is *only* a `#if simulator` stub bypass without a genuine device implementation behind it — that is how attestation/biometric checks get accidentally disabled in production.

## Screenshot pipeline (App Store, deterministic)

```bash
UDID=$(xcrun simctl list devices -j | jq -r \
  '[.devices[][] | select(.name=="iPhone 16 Pro Max" and .isAvailable)][0].udid')
xcrun simctl boot "$UDID"; xcrun simctl bootstatus "$UDID" -b
xcrun simctl privacy "$UDID" grant photos com.example.myapp
xcrun simctl install "$UDID" build/MyApp.app
xcrun simctl launch "$UDID" com.example.myapp -screenshotMode YES
xcrun simctl status_bar "$UDID" override --time "9:41" \
  --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 \
  --batteryState charged --batteryLevel 100
# (drive UI via XCUITest / ios-testing, then:)
xcrun simctl io "$UDID" screenshot --mask=black home.png
xcrun simctl shutdown "$UDID"
```

Re-apply the `status_bar override` after any reboot — it does not persist.
