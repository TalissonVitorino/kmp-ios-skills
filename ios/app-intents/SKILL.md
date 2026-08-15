---
name: app-intents
description: "Expose a fintech iOS app's actions and data to Siri, Shortcuts, Spotlight, widgets, Control Center, and Apple Intelligence with the App Intents framework — AppIntent.perform + IntentResult, @Parameter (options/defaults/dependencies), AppEntity + EntityQuery/EntityStringQuery, AppShortcutsProvider phrases, IndexedEntity Spotlight indexing, OpenIntent, ForegroundContinuableIntent, SnippetIntent, WidgetConfigurationIntent, ControlConfigurationIntent, and @AssistantIntent/@AssistantEntity assistant schemas (iOS 18+). Also covers authenticationPolicy for money-moving intents. Use when adding a Shortcut action, a Siri phrase, a Spotlight-searchable entity, a configurable widget/control, or an assistant-visible action. For the widget UI/timeline see `widgetkit`; Live Activities see `activitykit`; biometric gating of sensitive actions see `swift-security`; URL-scheme routing see `deep-linking`."
---

# App Intents (iOS)

Expose your app's verbs (actions) and nouns (entities) to the system so Siri,
Spotlight, the Shortcuts app, widgets, Control Center, the Action button, and
Apple Intelligence can invoke them. Pure Swift, code-first — **no `.intentdefinition`
file and no Info.plist registration**; the compiler discovers your types via the
App Intents extension metadata. Framework is iOS 16+; newer surfaces are flagged inline.

- **Widget/control UI & timelines:** `widgetkit` (this skill covers only the *configuration intent*, not the view).
- **Live Activities driven by an intent:** `activitykit` (`LiveActivityIntent`).
- **Gate money-moving actions behind biometrics:** `swift-security` (`LAContext`, biometry-gated Keychain).
- **URL-scheme / Universal Link routing:** `deep-linking`.
- **iOS-locale formatting inside dialogs/snippets:** `swift-formatstyle`.

## Contents

- [Anatomy & when to use which protocol](#anatomy)
- [AppIntent + perform / IntentResult](#appintent)
- [@Parameter](#parameter)
- [AppEntity + EntityQuery](#appentity)
- [AppShortcutsProvider (Siri phrases)](#shortcuts)
- [Spotlight: IndexedEntity](#spotlight)
- [OpenIntent](#openintent)
- [Confirmation, authentication & foreground continuation](#confirmation)
- [SnippetIntent (interactive result views)](#snippet)
- [Widget & Control configuration intents](#config)
- [Assistant schemas (Apple Intelligence, iOS 18+)](#assistant)
- [Correctness checklist](#checklist)
- References: `references/entities-queries.md`, `references/system-surfaces.md`

<a id="anatomy"></a>
## Anatomy & when to use which protocol

| Goal | Conform to |
|---|---|
| A callable action (Shortcuts/Siri) | `AppIntent` |
| A model object the system can reference/pass | `AppEntity` (+ an `EntityQuery`) |
| Fixed set of choices | `AppEnum` |
| One or more Siri phrases, auto-registered | `AppShortcutsProvider` |
| Open an entity in your app | `OpenIntent` |
| Configure a WidgetKit widget | `WidgetConfigurationIntent` |
| Configure a Control Center control | `ControlConfigurationIntent` |
| Drive a Live Activity (→ `activitykit`) | `LiveActivityIntent` |
| Return an interactive SwiftUI snippet | `SnippetIntent` |
| Continue in the foreground after a partial run | `ForegroundContinuableIntent` |
| Be discoverable by Apple Intelligence (iOS 18+) | `@AssistantIntent(schema:)` / `@AssistantEntity(schema:)` |

<a id="appintent"></a>
## AppIntent + perform / IntentResult

`perform()` is `async throws` and returns `some IntentResult`. `title` and
`description` are static metadata shown in the Shortcuts editor.

```swift
import AppIntents

struct CheckBalanceIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Balance"
    static let description = IntentDescription(
        "Shows the current balance of one of your accounts.",
        categoryName: "Accounts")

    // Must be true for any intent an App Shortcut uses.
    static let isDiscoverable = true
    // Keep false unless the action genuinely needs your UI in front.
    static let openAppWhenRun = false

    @Parameter(title: "Account")
    var account: AccountEntity

    // Inject app services registered via AppDependencyManager (see references).
    @Dependency var ledger: LedgerService

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Money> {
        let balance = try await ledger.balance(of: account.id)
        return .result(
            value: balance,
            dialog: "Your \(account.name) balance is \(balance.formatted)")
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Check the balance of \(\.$account)")
    }
}
```

- Return-value builders you compose after `some IntentResult`: `ReturnsValue<T>`,
  `ProvidesDialog`, `ShowsSnippetView`, `OpensIntent`. Match the `.result(...)`
  overload to the protocols you declared.
- `.result()` — no value; `.result(value:)` — returns data to the caller;
  `.result(dialog:)` — spoken/visible text; combine as needed.
- **Never use `Double` for a returned amount** — return a `Money`/`Decimal`-backed
  value (see `kmp-money`, `swift-formatstyle`), and format only in the dialog.
- `perform()` may run **outside your app's process** (e.g. from a widget or when
  `openAppWhenRun == false`). Don't touch UIKit/`UIApplication` there; do work
  through a shared service and App Group storage.
- Throw a `CustomLocalizedStringResourceConvertible` error to surface a readable
  failure; the system shows its message.

<a id="parameter"></a>
## @Parameter

```swift
@Parameter(title: "Amount", description: "How much to move")
var amount: Double            // prefer IntentCurrencyAmount / a custom type over raw Double

@Parameter(title: "Note", default: "")
var note: String

@Parameter(title: "Account",
           requestValueDialog: "Which account?")   // asked if unresolved
var account: AccountEntity

// Dynamic option list (Shortcuts picker) — recomputed each time.
struct PayeeOptions: DynamicOptionsProvider {
    @Dependency var directory: PayeeDirectory
    func results() async throws -> [PayeeEntity] { try await directory.recent() }
}
@Parameter(title: "Payee", optionsProvider: PayeeOptions())
var payee: PayeeEntity
```

- Supported types: `String`, `Int`, `Double`, `Bool`, `Date`,
  `Measurement`, `URL`, `IntentFile`, `AppEntity`, `AppEnum`, and arrays thereof.
- A **non-optional** parameter with no default is *required*: the system elicits it
  (via `requestValueDialog`) before `perform()`. Make it `Optional` to allow "skip".
- `parameterSummary` controls how the intent reads in the editor and which
  parameters show; use `When(\.$flag, .equalTo, true) { Summary { … } } otherwise: { … }`
  for conditional visibility.
- `@Dependency` resolves a service you registered at launch with
  `AppDependencyManager.shared.add { … }` — the clean way to reach your ledger/API
  layer without singletons. See `references/system-surfaces.md`.

<a id="appentity"></a>
## AppEntity + EntityQuery

An `AppEntity` is a stable, identifiable model the system can store, pass between
intents, and show in pickers. Every `AppEntity` needs a `defaultQuery`.

```swift
struct AccountEntity: AppEntity {
    let id: String                       // stable, persistable identifier
    @Property(title: "Name") var name: String
    let kind: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Account"
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(kind)")
    }

    static let defaultQuery = AccountQuery()
}

struct AccountQuery: EntityQuery {
    @Dependency var ledger: LedgerService

    // Required: resolve entities from their ids (system round-trips by id).
    func entities(for ids: [AccountEntity.ID]) async throws -> [AccountEntity] {
        try await ledger.accounts(ids: ids)
    }
    // Optional: what the Shortcuts app offers as suggestions.
    func suggestedEntities() async throws -> [AccountEntity] {
        try await ledger.recentAccounts()
    }
}
```

- **`id` must be stable and serializable** — the system persists it inside saved
  shortcuts and re-resolves via `entities(for:)`. A row-order index is not stable.
- Query refinements (pick the one you need; details in `references/entities-queries.md`):
  - `EntityStringQuery` — add `entities(matching: String)` for free-text search in pickers.
  - `EnumerableEntityQuery` — add `allEntities()` when the full set is small and fixed.
  - `EntityPropertyQuery` — structured "find where property …" filtering.
- `@Property` marks fields the system can display/filter on; plain `let`s stay internal.
- `AppEnum` for closed choice sets: conform + provide
  `caseDisplayRepresentations` mapping each case to a title.

<a id="shortcuts"></a>
## AppShortcutsProvider (Siri phrases)

Zero-configuration Siri phrases and Spotlight/Shortcuts entries. Exactly **one**
provider per app target; return up to 10 `AppShortcut`s.

```swift
struct BankShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CheckBalanceIntent(),
            phrases: [
                "Check my balance in \(.applicationName)",
                "What's my balance in \(.applicationName)",
            ],
            shortTitle: "Check Balance",
            systemImageName: "creditcard")
    }
}
```

- **Every phrase must contain `\(.applicationName)`** — Siri requires the app name
  token; phrases without it are ignored. Provide natural variants users actually say.
- To insert a parameter into a phrase, use an `AppShortcutPhraseToken` for the
  parameter (e.g. `"Pay \(\.$payee) in \(.applicationName)"`) and give that
  parameter suggested values via its query.
- The intents referenced here must have `isDiscoverable == true`.
- Phrases update when the provider type changes; test with a device build (Siri
  phrase registration is unreliable in the Simulator).

<a id="spotlight"></a>
## Spotlight: IndexedEntity

Conform an entity to `IndexedEntity` (refines `AppEntity`) to make its instances
appear in Spotlight search and be openable via an `OpenIntent`.

```swift
import CoreSpotlight

struct PayeeEntity: IndexedEntity {
    let id: String
    @Property(title: "Name") var name: String

    static let defaultQuery = PayeeQuery()
    var displayRepresentation: DisplayRepresentation { "\(name)" }

    // Enrich the Spotlight record with non-@Property data.
    var attributeSet: CSSearchableItemAttributeSet {
        let a = CSSearchableItemAttributeSet(contentType: .content)
        a.keywords = [name, "payee", "transfer"]
        return a
    }
}

// Index at an appropriate moment (launch, data change):
try await CSSearchableIndex(name: "Payees").indexAppEntities(payees)
```

- `indexAppEntities(_:priority:)` maps `@Property` values + `attributeSet` into the
  index, keyed by the entity `id`; re-indexing the same id updates in place.
- Use `@ComputedProperty(indexingKey:)` to map a computed value onto a standard
  Spotlight key (e.g. `\.contentDescription`); `customIndexingKey:` for a bespoke key.
- Provide an `OpenIntent` (below) so a Spotlight tap deep-links into your app.
- **Never index sensitive values** (balances, PANs, tokens) into Spotlight — it is
  a shared, on-device search surface. Index names/labels only.

<a id="openintent"></a>
## OpenIntent

An `OpenIntent` opens a specific entity in your app; its single `target` parameter
is the entity. Pairs with Spotlight and with "Open …" Shortcuts.

```swift
struct OpenPayeeIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Payee"
    @Parameter(title: "Payee", requestValueDialog: "Which payee?")
    var target: PayeeEntity

    func perform() async throws -> some IntentResult {
        await Router.shared.show(payee: target.id)   // navigate in-app
        return .result()
    }
}
```

- `OpenIntent` implies `openAppWhenRun == true` — your app is brought to the front.
- Route with your existing navigation stack; see `deep-linking` if you also expose
  a URL scheme for the same destinations.

<a id="confirmation"></a>
## Confirmation, authentication & foreground continuation

For fintech, an intent that moves money must be **hard to trigger accidentally** and
must not run silently on a locked device.

```swift
struct TransferMoneyIntent: AppIntent {
    static let title: LocalizedStringResource = "Transfer Money"
    static let isDiscoverable = true

    // Force device unlock before this intent runs — even from Watch/remote.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Amount") var amount: IntentCurrencyAmount
    @Parameter(title: "To") var payee: PayeeEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Explicit confirmation for a destructive/irreversible action.
        try await requestConfirmation(
            actionName: .send,
            dialog: "Send \(amount.formatted) to \(payee.name)?")

        try await TransferService.shared.send(amount, to: payee.id)
        return .result(dialog: "Sent \(amount.formatted) to \(payee.name).")
    }
}
```

- `authenticationPolicy` default is `.alwaysAllowed` (runs while locked). Set
  `.requiresAuthentication` or `.requiresLocalDeviceAuthentication` for anything
  sensitive; the latter forces the *local* device to be unlocked.
- The policy is a system gate, **not** a substitute for app-level biometric
  re-auth on the actual money movement — keep the transfer credential/key behind a
  biometry-gated Keychain item (`swift-security`).
- `requestConfirmation(...)` returns normally on confirm, throws on cancel; use it
  before irreversible actions.
- **`ForegroundContinuableIntent`** — when work can't finish in the background (needs
  your UI, a login, a picker), conform and call
  `needsToContinueInForegroundError(_:continuation:)` (or
  `requestToContinueInForeground(_:continuation:)`) to bring the app forward and
  resume on the main actor:

```swift
struct AddPayeeIntent: ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Add Payee"
    @Parameter(title: "Name") var name: String

    func perform() async throws -> some IntentResult {
        guard AuthState.shared.isSignedIn else {
            throw needsToContinueInForegroundError("Sign in to add a payee.") {
                await Router.shared.presentSignIn()
            }
        }
        try await PayeeService.shared.add(name: name)
        return .result()
    }
}
```

<a id="snippet"></a>
## SnippetIntent (interactive result views)

A `SnippetIntent` returns a live SwiftUI view (buttons/toggles work) that the system
shows as a snippet — e.g. a "Transfer sent" card with an Undo button. iOS 26 refreshes
the snippet by calling `perform()` again, so read fresh state each time.

```swift
struct BalanceSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "Balance Snippet"
    @Parameter var accountID: String

    func perform() async throws -> some IntentResult & ShowsSnippetView {
        let account = try await LedgerService.shared.account(accountID)  // re-fetch each call
        return .result(view: BalanceCard(account: account))
    }
}
```

- The producing action returns it via
  `.result(value:dialog:snippetIntent:)` (compose `ShowsSnippetIntent`), or a plain
  intent returns `.result(view:)` after conforming its result to `ShowsSnippetView`.
- Because `perform()` can be called repeatedly, keep it **idempotent** and fast —
  no side effects on refresh; move mutations into the buttons' own intents.

<a id="config"></a>
## Widget & Control configuration intents

These are **configuration schemas**, not actions — their parameters become the
user-editable options. `perform()` is not required (widgets read the configured
values via `AppIntentConfiguration`; see `widgetkit` for the timeline).

```swift
struct AccountWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Account"
    static let description = IntentDescription("Pick which account the widget shows.")

    @Parameter(title: "Account")
    var account: AccountEntity?     // AppEntity params drive the widget's picker
}

// Control Center control (iOS 18+):
struct ToggleQuickPayIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Quick Pay Control"
    @Parameter(title: "Account", optionsProvider: AccountOptions())
    var account: AccountEntity
}
```

- Widget side: `AppIntentConfiguration(kind:intent:provider:)` and a
  `TimelineProvider`/`AppIntentTimelineProvider` — that wiring lives in `widgetkit`.
- A `ControlConfigurationIntent` may also implement `perform()` (dual-purpose: the
  same intent both configures and runs the control's action).
- Keep configuration entities free of sensitive data — widget config is stored by
  the system.

<a id="assistant"></a>
## Assistant schemas (Apple Intelligence, iOS 18+)

Assistant schemas let Apple Intelligence understand your intents/entities against a
predefined vocabulary (e.g. financial, mail, photos domains). Apply the macro to an
otherwise-normal `AppIntent`/`AppEntity`; it synthesizes the schema conformance and
requires the exact parameters the schema defines.

```swift
// Each schema fixes the required conformance, parameters, and return type.
// `.system.search` = ShowInAppSearchResultsIntent, takes `criteria`, returns `.result()`.
@AssistantIntent(schema: .system.search)
struct FindTransactionsIntent: ShowInAppSearchResultsIntent {
    static let searchScopes: [StringSearchScope] = [.general]
    var criteria: StringSearchCriteria      // schema-mandated; no @Parameter needed

    func perform() async throws -> some IntentResult {
        await Router.shared.showSearch(term: criteria.term)
        return .result()
    }
}

@AssistantEntity(schema: .system.transaction)  // illustrative; use a schema that exists for your domain
struct TransactionEntity: AppEntity { /* schema-mandated @Property fields */ }
```

- Macros: `@AssistantIntent(schema:)`, `@AssistantEntity(schema:)`,
  `@AssistantEnum(schema:)`. Each pins your type to a system schema so Siri/Apple
  Intelligence can invoke it without bespoke phrase training.
- **Verify the specific schema exists for your domain before adopting it** — the
  schema catalog is domain-scoped and has changed release-to-release. Apple's docs
  mark several of the original iOS 18 assistant-schema symbols as **deprecated in the
  iOS 26 timeframe**; treat the exact macro/schema names as version-sensitive and
  confirm against the current SDK rather than copying an older sample. If a schema
  for your use case isn't available, ship a normal `AppShortcutsProvider` phrase
  instead — it still reaches Siri.
- Assistant-schema intents are additive: the same type still works as a plain
  Shortcuts action.

<a id="checklist"></a>
## Correctness checklist

- [ ] `import AppIntents`; no `.intentdefinition` file, no Info.plist intent keys.
- [ ] Each `AppShortcut` phrase contains `\(.applicationName)`; intents used by
      shortcuts set `isDiscoverable = true`.
- [ ] Exactly one `AppShortcutsProvider` per target; ≤10 shortcuts.
- [ ] Every `AppEntity` has a `defaultQuery`; `id` is stable and serializable, and
      `entities(for:)` round-trips ids correctly.
- [ ] `perform()` does no UIKit/`UIApplication` work (may run out-of-process); reach
      services via `@Dependency` + `AppDependencyManager`, not singletons touching UI.
- [ ] Money returned as a decimal-backed type, never `Double`; formatted only in dialog.
- [ ] Money-moving intents set `authenticationPolicy` and call `requestConfirmation`;
      the actual credential stays behind biometric-gated Keychain (`swift-security`).
- [ ] `openAppWhenRun` only where the UI is genuinely needed; prefer background runs.
- [ ] `SnippetIntent.perform()` is idempotent and re-fetches state (called repeatedly).
- [ ] Spotlight/`IndexedEntity` records exclude balances, PANs, and tokens.
- [ ] Assistant-schema macro/schema names verified against the current SDK, not an
      older sample; fall back to phrases when no schema fits.
- [ ] Widget/Control config entities carry no sensitive data.
