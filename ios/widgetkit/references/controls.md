# Control Center controls (iOS 18) — depth

Companion to `../SKILL.md`. Full button + stateful toggle patterns.

A `ControlWidget` renders in **Control Center, the Lock Screen, and the Action button**.
Add it to the app's `WidgetBundle`, gated `@available(iOS 18.0, *)`.

## Button control (discrete action)

```swift
import WidgetKit
import AppIntents
import SwiftUI

struct OpenScannerIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan to Pay"
    static let openAppWhenRun = true          // bring the app forward for this action
    func perform() async throws -> some IntentResult {
        // set a deep-link/route the app reads on activation
        AppRouter.shared.pendingRoute = .scanner
        return .result()
    }
}

@available(iOS 18.0, *)
struct ScanControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.acme.scan") {
            ControlWidgetButton(action: OpenScannerIntent()) {
                Label("Scan to Pay", systemImage: "qrcode.viewfinder")
            }
        }
        .displayName("Scan to Pay")
        .description("Open the scanner to pay a code.")
    }
}
```

- `openAppWhenRun = true` (or conforming the intent to `OpenIntent`) launches the app; omit it for a purely background action.
- Buttons are for **actions**, not state. For on/off use a toggle.

## Stateful, configurable toggle

A toggle needs its action intent to conform to **`SetValueIntent`** and needs a **value provider**
so the rendered state survives a system relaunch (the control process is not always alive).

```swift
import AppIntents
import WidgetKit
import SwiftUI

// 1. The write side: WidgetKit sets `value` before calling perform().
struct SetRoundUpIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Round-Up Savings"
    @Parameter(title: "Account") var account: AccountEntity
    @Parameter(title: "Enabled") var value: Bool

    init() {}
    init(account: AccountEntity) { self.account = account }

    func perform() async throws -> some IntentResult {
        await SavingsStore.shared.setRoundUp(value, for: account.id)
        return .result()
    }
}

// 2. The configuration intent: lets the user pick which account this control drives.
struct RoundUpControlIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Round-Up Control"
    @Parameter(title: "Account") var account: AccountEntity?
}

// 3. The value provider: reads current state for the chosen configuration.
@available(iOS 18.0, *)
struct RoundUpProvider: AppIntentControlValueProvider {
    func previewValue(configuration: RoundUpControlIntent) -> RoundUpValue {
        RoundUpValue(account: .sample, isEnabled: false)
    }
    func currentValue(configuration: RoundUpControlIntent) async throws -> RoundUpValue {
        let account = configuration.account ?? .primary
        let on = await SavingsStore.shared.isRoundUpEnabled(account.id)
        return RoundUpValue(account: account, isEnabled: on)
    }
}

struct RoundUpValue { let account: AccountEntity; let isEnabled: Bool }

@available(iOS 18.0, *)
struct RoundUpControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "com.acme.roundup",
                                      provider: RoundUpProvider()) { value in
            ControlWidgetToggle("Round-Up Savings",
                                isOn: value.isEnabled,
                                action: SetRoundUpIntent(account: value.account)) { isOn in
                Label(isOn ? "On" : "Off", systemImage: "arrow.up.forward.circle")
            }
        }
        .displayName("Round-Up Savings")
    }
}
```

- Flow: the **provider reads** current state → the **toggle renders** it → the tap runs the **`SetValueIntent` which writes** state → the control refreshes.
- Keep app state and control state in sync from the app side by asking the system to refresh:

```swift
import WidgetKit
ControlCenter.shared.reloadControls(ofKind: "com.acme.roundup")
```

- **Fintech guardrail:** a control may enable a setting or open a flow, but a money transfer must go through the app with explicit user confirmation — never complete a transfer inside `perform()`.
