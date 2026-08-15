# System surfaces: dependencies, Spotlight, widgets, results — depth

Grounded in Apple's App Intents / Core Spotlight documentation.

## Dependency injection (AppDependencyManager)

Register services once at launch; resolve them in intents and queries with
`@Dependency`. This keeps `perform()` testable and avoids UI-touching singletons in
out-of-process runs.

```swift
@main
struct BankApp: App {
    init() {
        AppDependencyManager.shared.add { LedgerService.live }
        AppDependencyManager.shared.add { PayeeDirectory.live }
    }
    var body: some Scene { WindowGroup { RootView() } }
}

struct CheckBalanceIntent: AppIntent {
    @Dependency var ledger: LedgerService   // resolved by type
    // …
}
```

- The dependency's type must match exactly. Register every service an intent/query
  in *any* target (app, widget extension) might resolve — the extension has its own
  process and must register too, or share a registration entry point.

## IntentResult composition

Compose the result protocols you actually return, then pick the matching `.result`:

| Declared return | `.result` call |
|---|---|
| `some IntentResult` | `.result()` |
| `… & ReturnsValue<T>` | `.result(value: t)` |
| `… & ProvidesDialog` | `.result(dialog: "…")` |
| `… & ReturnsValue<T> & ProvidesDialog` | `.result(value: t, dialog: "…")` |
| `… & ShowsSnippetView` | `.result(view: SomeView())` |
| `… & OpensIntent` | `.result(opensIntent: OtherIntent())` |
| producing action + snippet | `.result(value:dialog:snippetIntent:)` |

`IntentDialog` supports a full/supporting split for voice vs screen:

```swift
IntentDialog(full: "The closest branch is \(branch.name).",
             supporting: "\(branch.name) is \(branch.distance) away.")
```

## Spotlight indexing details

Two paths to make `IndexedEntity` instances searchable:

1. **App already uses Core Spotlight** — Spotlight picks up entities automatically
   once they conform to `IndexedEntity` and you index them.
2. **App doesn't** — create a named index and push entities:

```swift
try await CSSearchableIndex(name: "AppEntities_Payees")
    .indexAppEntities(payees, priority: 0)
```

Enrich beyond `@Property`:

```swift
extension PayeeEntity {
    // Map a computed value onto a standard Spotlight key.
    @ComputedProperty(indexingKey: \.contentDescription)
    var summary: String { "\(name) · \(kind)" }

    // A custom, app-namespaced key.
    @ComputedProperty(customIndexingKey:
        CSCustomAttributeKey(keyName: "com_bank_PayeeEntity_kind")!)
    var kindKey: String { kind }

    var attributeSet: CSSearchableItemAttributeSet {
        let a = CSSearchableItemAttributeSet(contentType: .content)
        a.keywords = [name, "payee"]
        a.displayName = name
        return a
    }
}
```

- Re-indexing an entity with the same `id` updates the existing record; delete with
  `deleteAppEntities(...)` / the index's delete APIs when data is removed.
- Pair with an `OpenIntent` whose `target` is the entity so a Spotlight tap deep-links.
- **Exclude sensitive fields.** Spotlight is a shared on-device search corpus; index
  names/labels/keywords, never balances, account numbers, or tokens.

## Widget configuration ↔ WidgetKit

The `WidgetConfigurationIntent` only declares the options. The widget wires them:

```swift
// In the widget extension (WidgetKit):
struct AccountWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "AccountWidget",
            intent: AccountWidgetIntent.self,
            provider: AccountProvider()) { entry in
                AccountWidgetView(entry: entry)
            }
    }
}
```

- The provider is an `AppIntentTimelineProvider`; each timeline entry receives the
  resolved configuration intent. Full timeline mechanics live in the `widgetkit` skill.
- Control Center: a `ControlConfigurationIntent` configures a `ControlWidget`
  (`ControlWidgetButton`/`ControlWidgetToggle`) — again, the control's view lives in
  the WidgetKit side.

## Foreground continuation vs. openAppWhenRun

- `openAppWhenRun = true` — always launches the app to run the intent. Blunt; use
  for `OpenIntent`-style navigation.
- `ForegroundContinuableIntent` — starts in the background and only pulls the app
  forward *when it must* (needs sign-in, a picker, or UI). Preferred for actions that
  usually complete silently but occasionally need the user.

```swift
throw needsToContinueInForegroundError("Sign in to continue.") {
    await Router.shared.presentSignIn()      // runs on the main actor after launch
}
// or, to run work inline after coming forward:
let picked = try await requestToContinueInForeground("Pick an account") {
    await Router.shared.presentAccountPicker()
}
```

## Testing intents

- `App Intents` testing (`AppIntentsTesting`) exposes entity definitions so you can
  drive queries: `definitions.entities["PayeeEntity"].entities(matching: "…")`,
  `.entities(identifiers: […])`, `.allEntities()`.
- For `perform()`, register test doubles via `AppDependencyManager.shared.add { … }`
  in setup and assert on the returned value/dialog. See `ios-testing` for the harness.
