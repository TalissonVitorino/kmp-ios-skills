---
name: swift-architecture
description: "Choose and migrate an Apple-platform app architecture for a fintech iOS app (iOS 26 era). Covers MV with Observation (@Observable, @Environment injection, @Bindable), MVVM, hand-rolled MVI/unidirectional store+reducer, The Composable Architecture (@Reducer, @ObservableState, StoreOf, Effect.run, @Dependency, @Presents, TestStore), Clean Architecture (use cases + repository protocols), the Coordinator pattern (NavigationStack path), and legacy VIPER; plus module/dependency boundaries, state ownership, test seams, when to escalate a feature past plain SwiftUI MV, and incremental migration. Use when picking an architecture, refactoring a ViewModel, deciding MV vs MVVM vs TCA, or untangling state ownership. The KMP counterpart is `mvi-architecture`; for the Observation state mechanics see `swiftui-observation`; for Swift-side DI/testing seams see `swift-protocol-di-testing`; for navigation stacks see `navigation`."
---

# Swift App Architecture (iOS / macOS)

Pick the smallest architecture a feature actually needs, and keep state
ownership, module boundaries, and test seams explicit. Grounded in Apple's
SwiftUI + Observation frameworks; TCA specifics from pointfree's swift-composable-architecture.

- **KMP counterpart:** `mvi-architecture` — if the domain/state lives in shared Kotlin (`commonMain`), the iOS layer is a thin view over a shared store; don't rebuild the reducer in Swift.
- **State mechanics:** `swiftui-observation` (`@Observable`, `@State`, `@Environment`, `@Bindable` tracking rules). This skill is about *structure*; that one is about the *machinery*.
- **Test seams / DI:** `swift-protocol-di-testing`. **Navigation:** `navigation`. **Concurrency in models:** `swift-concurrency`.

## Contents

- [Decision table](#decision)
- [MV with Observation (default)](#mv)
- [MVVM](#mvvm)
- [MVI / unidirectional store + reducer](#mvi)
- [The Composable Architecture (TCA)](#tca)
- [Clean Architecture](#clean)
- [Coordinator](#coordinator)
- [Legacy VIPER](#viper)
- [Boundaries, state ownership, test seams](#boundaries)
- [When to escalate past MV](#escalate)
- [Incremental migration](#migration)
- [Correctness checklist](#checklist)
- References: `references/tca.md`, `references/migration.md`

<a id="decision"></a>
## Decision table

| Feature shape | Use |
|---|---|
| View maps almost 1:1 to model state; light logic | **MV** with `@Observable` |
| Non-trivial presentation logic, formatting, validation you want to unit-test off-view | **MVVM** (one `@Observable` model per screen) |
| Complex event flow, many interdependent actions, you want time-travel/replayable state | **MVI** (hand-rolled) or **TCA** |
| Large team, deep feature composition, exhaustive testing, shared conventions across many screens | **TCA** |
| Domain shared with Android | Domain in KMP (`mvi-architecture`); iOS = MV/MVVM shell |
| Business rules must outlive UI framework churn | **Clean** layering (use cases + repo protocols) — orthogonal to the UI pattern above |
| Flow/routing logic tangled into views | Add a **Coordinator**; keep the screen pattern as-is |

- These compose: a fintech app is typically **MV/MVVM at the screen level + Clean-style domain layer + a Coordinator for flows**. TCA replaces the first two, not the domain layer.
- Default to **MV**. Escalate a *single feature* when it earns it (see [below](#escalate)); do not adopt one heavy pattern app-wide on day one.

<a id="mv"></a>
## MV with Observation (default, iOS 17+)

No ViewModel per view. An `@Observable` reference type is the model; SwiftUI tracks
only the properties a view actually reads (property-level, not object-level).

```swift
import Observation

@Observable @MainActor
final class AccountModel {
    private(set) var balance: Money = .zero(.usd)
    private(set) var isLoading = false
    var loadError: String?

    @ObservationIgnored private let ledger: LedgerService   // deps aren't view state

    init(ledger: LedgerService) { self.ledger = ledger }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do { balance = try await ledger.currentBalance() }
        catch { loadError = String(describing: error) }
    }
}
```

- Mark stored dependencies `@ObservationIgnored` so mutating them never invalidates views.
- Expose mutation through methods; keep setters `private(set)` — the model is the single writer of its state.

### Ownership + injection

```swift
struct AccountScreen: View {
    @State private var model: AccountModel          // this view OWNS the model's lifetime

    init(ledger: LedgerService) {
        _model = State(initialValue: AccountModel(ledger: ledger))
    }

    var body: some View {
        List { Text(model.balance.formatted()) }
            .task { await model.refresh() }
    }
}
```

- `@State` for the view that **creates and owns** the model; pass the instance (not a new one) to children as a plain `let` or via `.environment(_:)`.
- App-wide singletons (session, feature flags) go in the environment:

```swift
@main struct BankApp: App {
    @State private var session = SessionModel()
    var body: some Scene {
        WindowGroup { RootView().environment(session) }
    }
}

struct ProfileView: View {
    @Environment(SessionModel.self) private var session   // type is the key
    var body: some View {
        @Bindable var session = session                    // bindings to an @Observable
        Toggle("Face ID", isOn: $session.biometricsEnabled)
    }
}
```

- `@Environment(Type.self)` reads an injected `@Observable`; `@Bindable` (local shadow in `body`, or a stored `@Bindable var`) is how you get `$`-bindings to it. No `@EnvironmentObject`/`@Published`.
- Do **not** put money math, currency rounding, or ledger rules in the view or model — keep them in the domain layer / `kmp-money`. The model orchestrates; it doesn't compute.

<a id="mvvm"></a>
## MVVM

MVVM here is just MV where the model is a dedicated, testable *view model* that
never imports SwiftUI. Reach for it when presentation logic (formatting,
validation, derived state, multi-step submit) is worth testing in isolation.

```swift
@Observable @MainActor
final class TransferViewModel {
    var amountText = ""
    var recipient: Account?
    private(set) var canSubmit = false
    private(set) var submitState: SubmitState = .idle

    @ObservationIgnored private let transfers: TransferService

    init(transfers: TransferService) { self.transfers = transfers }

    func validate() {
        canSubmit = recipient != nil && Money.parse(amountText, .usd)?.isPositive == true
    }

    func submit() async {
        guard canSubmit, let amount = Money.parse(amountText, .usd), let to = recipient
        else { return }
        submitState = .sending
        do { submitState = .sent(try await transfers.send(amount, to: to)) }
        catch { submitState = .failed(error) }
    }
}
```

- One view model per screen, owned by the screen via `@State`. Inject services through `init` (protocol types → swappable in tests; see `swift-protocol-di-testing`).
- The view is a pure function of `submitState` etc. `enum SubmitState` makes the impossible states unrepresentable — prefer an enum over scattered `isLoading`/`errorMessage` bools.
- MVVM vs MV: identical mechanics. Call it MVVM when the model is substantial and unit-tested; call it MV when it's a thin state holder. Don't add an empty pass-through view model just to name the pattern.

<a id="mvi"></a>
## MVI / unidirectional store + reducer

One state value, actions in, a pure reducer, effects out. Predictable and
replayable without a dependency. Good when a screen has many interacting events.

```swift
enum Effect<Action: Sendable>: Sendable {
    case none
    case run(@Sendable (_ send: @Sendable (Action) async -> Void) async -> Void)
}

@Observable @MainActor
final class Store<State, Action: Sendable> {
    private(set) var state: State
    @ObservationIgnored private let reduce: (inout State, Action) -> Effect<Action>

    init(_ initial: State, reduce: @escaping (inout State, Action) -> Effect<Action>) {
        self.state = initial
        self.reduce = reduce
    }

    func send(_ action: Action) {
        switch reduce(&state, action) {
        case .none: break
        case .run(let work):
            Task { await work { [weak self] a in await self?.send(a) } }
        }
    }
}
```

```swift
struct Counter {
    struct State { var count = 0; var fact: String? }
    enum Action: Sendable { case inc, factTapped, factResponse(String) }

    static func reduce(_ s: inout State, _ a: Action) -> Effect<Action> {
        switch a {
        case .inc: s.count += 1; return .none
        case .factTapped:
            return .run { [count = s.count] send in
                await send(.factResponse("\(count) is interesting"))
            }
        case .factResponse(let f): s.fact = f; return .none
        }
    }
}
```

- The reducer is a **pure function of `(state, action)`** — no I/O, no `Date()`, no randomness inline; those go through effects/injected deps so the reducer stays unit-testable by calling it directly.
- View sends actions (`store.send(.inc)`) and reads `store.state`; it never mutates state.
- This is the DIY version of TCA. If you find yourself adding navigation, cancellation, dependency overrides, and exhaustive tests, adopt TCA instead of reinventing it. If the reducer belongs to a shared KMP domain, use `mvi-architecture` and bridge.

<a id="tca"></a>
## The Composable Architecture (TCA)

Batteries-included unidirectional architecture (SPM: `pointfreeco/swift-composable-architecture`). Use for large, deeply-composed apps that value exhaustive testing and shared conventions.

```swift
import ComposableArchitecture

@Reducer
struct Feature {
    @ObservableState
    struct State: Equatable {
        var count = 0
        var fact: String?
        @Presents var alert: AlertState<Action.Alert>?
    }

    enum Action {
        case incrementTapped, factTapped, factResponse(String), alert(PresentationAction<Alert>)
        enum Alert: Equatable {}
    }

    @Dependency(\.numberFact) var numberFact          // injected, overridable in tests

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .incrementTapped:
                state.count += 1
                return .none
            case .factTapped:
                return .run { [count = state.count] send in
                    await send(.factResponse(try await numberFact.fetch(count)))
                }
            case let .factResponse(fact):
                state.fact = fact
                return .none
            case .alert:
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }
}
```

```swift
struct FeatureView: View {
    @Bindable var store: StoreOf<Feature>            // StoreOf<Feature> == Store<Feature.State, Feature.Action>
    var body: some View {
        Form {
            Text("\(store.count)")                    // read state directly (ObservableState)
            Button("Increment") { store.send(.incrementTapped) }
            if let fact = store.fact { Text(fact) }
        }
        .alert($store.scope(state: \.alert, action: \.alert))
    }
}
```

- **Modern (1.7+) surface:** `@Reducer` on the feature, `@ObservableState` on `State`, read `store.state` directly, `@Bindable var store` for bindings. `WithViewStore`/`@PresentationState` are the pre-1.7 forms — don't use them in new code.
- Effects: `.run { send in ... }` for async work (auto-cancels with the store's lifetime; supports `.cancellable(id:)`); `.send` is only for child→parent delegate actions, not sharing logic.
- Navigation: `@Presents var child: Child.State?` + `.ifLet`, drive sheets/pushes with `$store.scope(...)`. Tree- and stack-based navigation both supported.
- Dependencies: `@Dependency(\.x)` with a `DependencyKey` (`liveValue` / `testValue`); override per-test. Testing: `TestStore` asserts every state mutation and received effect exhaustively:

```swift
@Test func increments() async {
    let store = await TestStore(initialState: Feature.State()) { Feature() }
        withDependencies: { $0.numberFact.fetch = { "\($0) is good" } }
    await store.send(.incrementTapped) { $0.count = 1 }
    await store.send(.factTapped)
    await store.receive(\.factResponse) { $0.fact = "1 is good" }
}
```

- Cost: a real dependency and a distinct mental model. Worth it at scale; overkill for a handful of simple screens. Deep dive in `references/tca.md`.

<a id="clean"></a>
## Clean Architecture (layering — orthogonal to the UI pattern)

Separate **what the app does** (domain) from **how** (UI, network, DB). The domain
layer knows nothing about SwiftUI, Ktor, or Core Data.

- **Domain:** entities + `protocol` use cases + `protocol` repositories. Pure Swift (or shared KMP). No framework imports.
- **Data:** repository *implementations* (network, DB, keychain) conforming to the domain protocols.
- **Presentation:** MV/MVVM/TCA depending only on the domain protocols.

```swift
// Domain — no framework imports
protocol AccountRepository: Sendable {
    func balance() async throws -> Money
}
struct FetchBalance: Sendable {                       // a use case = one verb
    let repo: AccountRepository
    func callAsFunction() async throws -> Money { try await repo.balance() }
}

// Data — conforms to the domain protocol
struct RemoteAccountRepository: AccountRepository {
    let api: BankAPI
    func balance() async throws -> Money { try await api.getBalance().asMoney() }
}
```

- Dependencies point **inward**: presentation → domain ← data. The domain never imports the outer layers (Dependency Inversion via protocols).
- Don't over-layer a CRUD screen — a repository protocol alone is often enough. Use cases earn their keep when a rule is reused across screens or must be tested independently of any repository. Fintech rule of thumb: money movement, limits, and eligibility checks belong in domain use cases, never in a view model.
- Injection: wire concrete repos to protocols at the composition root (App/DI container). Shared DI across KMP → `kmp-di`.

<a id="coordinator"></a>
## Coordinator (navigation/flow ownership)

Pull routing out of views so screens don't know what comes next — valuable for
multi-step fintech flows (onboarding, KYC, transfer wizard).

```swift
@Observable @MainActor
final class OnboardingCoordinator {
    var path = NavigationPath()
    enum Route: Hashable { case terms, identity, linkBank, done }

    func advance(to route: Route) { path.append(route) }
    func restart() { path = NavigationPath() }
}

struct OnboardingFlow: View {
    @State private var coordinator = OnboardingCoordinator()
    var body: some View {
        NavigationStack(path: $coordinator.path) {
            TermsScreen(onAccept: { coordinator.advance(to: .identity) })
                .navigationDestination(for: OnboardingCoordinator.Route.self) { route in
                    switch route {
                    case .terms:    TermsScreen(onAccept: { coordinator.advance(to: .identity) })
                    case .identity: IdentityScreen(onDone: { coordinator.advance(to: .linkBank) })
                    case .linkBank: LinkBankScreen(onDone: { coordinator.advance(to: .done) })
                    case .done:     DoneScreen()
                    }
                }
        }
    }
}
```

- Screens receive callbacks (`onDone:`) and stay reusable; the coordinator owns the `path` and decides transitions. Deep-linking sets `path` directly.
- One coordinator per flow, not one god-coordinator. For the full navigation surface (type-safe routes, `NavigationSplitView`, Nav3 on the KMP side) use `navigation`.

<a id="viper"></a>
## Legacy VIPER (recognize, don't start new)

View–Interactor–Presenter–Entity–Router, usually UIKit-era. You'll meet it in
existing code; don't build new features in it.

- **View** (passive) ↔ **Presenter** (view logic) ↔ **Interactor** (business logic) → **Entity**; **Router** handles navigation.
- Maps onto modern Swift as: View = SwiftUI view, Presenter ≈ `@Observable` view model, Interactor ≈ Clean use case, Router ≈ Coordinator. Migrate module-by-module toward MVVM+Clean+Coordinator (see `references/migration.md`), not in one rewrite.
- Its ceremony (5 types + protocols per screen) rarely pays off in SwiftUI; the Observation + use-case combination gives the same seams with far less boilerplate.

<a id="boundaries"></a>
## Boundaries, state ownership, test seams

- **Single writer:** every piece of state has exactly one owner that mutates it (`private(set)` + methods, or a reducer). Everyone else reads. This is the rule that prevents most state bugs.
- **Own vs observe:** the view that *creates* a model uses `@State`; views that *use* it take it as `let`/`@Bindable`/`@Environment`. Never create a model in a child that a parent already owns — you'll get two copies.
- **Module boundaries:** feature modules depend on a domain module, not on each other. Cross-feature communication goes through the domain or a coordinator, not direct imports. Enforce with SPM targets (`swift-package-manager`).
- **Test seams:** inject collaborators as `protocol`/closure types through `init` (or `@Dependency` in TCA). A screen is testable when you can construct its model with fakes and assert on its state enum — no live network, keychain, or clock. See `swift-protocol-di-testing`; secrets/biometric seams via `swift-security`.
- **`@MainActor`** the models/stores that back UI; push blocking work into injected services (actors / background). See `swift-concurrency`.

<a id="escalate"></a>
## When to escalate a feature past plain MV

Escalate a *single feature* (MV → MVVM → MVI/TCA) when several are true — not preemptively:

- The view has grown branching logic that you can't unit-test without a simulator.
- Many actions mutate overlapping state and order matters (races, half-applied updates).
- You need deterministic replay, undo, or exhaustive "every state change is asserted" tests.
- Multiple child features must compose and share/forward state and effects.
- Impossible states keep appearing (`isLoading && error != nil`) — first fix with an `enum`; if that's not enough, go unidirectional.

Escalate the *domain* (add Clean use cases) independently, when a rule is reused or must move money — regardless of the screen pattern. Escalating everything at once is the common over-engineering failure; so is never escalating a genuinely complex flow.

<a id="migration"></a>
## Incremental migration

- **`ObservableObject` → `@Observable`:** drop `: ObservableObject`, remove `@Published`, add `@Observable`; change `@StateObject`→`@State`, `@ObservedObject`→plain `let` or `@Bindable`, `@EnvironmentObject`→`@Environment(Type.self)`. Migrate leaf models first. Details in `swiftui-observation`.
- **UIKit MVC/VIPER → SwiftUI MVVM:** wrap new SwiftUI screens in `UIHostingController`, or host UIKit in SwiftUI via representables; convert screen-by-screen behind the existing router/coordinator. See `swiftui-uikit-interop`.
- **MV/MVVM → TCA:** adopt per feature at a navigation boundary. A TCA feature can host a non-TCA child (and vice-versa) during the transition; don't rewrite the whole app in one branch.
- **Toward Clean:** introduce a repository `protocol` first, point view models at it, then extract use cases only where logic is shared. Each step ships independently.
- Full step-by-step recipes (including a strangler-fig ordering for a live fintech app) in `references/migration.md`.

<a id="checklist"></a>
## Correctness checklist

- [ ] Default is MV with `@Observable`; heavier patterns adopted per-feature with a concrete reason, not app-wide by default.
- [ ] Every state value has a single writer; readers get `private(set)`/`let`/`@Bindable`, not their own copy.
- [ ] Model owner uses `@State`; consumers use `@Environment`/`@Bindable`/`let`. No child re-creates a parent-owned model.
- [ ] Dependencies stored on models are `@ObservationIgnored` (or `@Dependency` in TCA) — never treated as view state.
- [ ] Money/eligibility/limit rules live in a domain use case or shared KMP, never in a view or view model (`kmp-money`).
- [ ] Impossible states removed with enums before reaching for a reducer.
- [ ] Reducers (MVI/TCA) are pure: no I/O, `Date()`, or randomness inline — routed through effects/injected deps.
- [ ] Collaborators injected via `protocol`/closure/`@Dependency` through `init` — screen testable with fakes, no live network/keychain/clock.
- [ ] Navigation/flow logic lives in a Coordinator or TCA navigation, not scattered across screens.
- [ ] New code uses modern TCA (`@Reducer` + `@ObservableState` + `@Bindable var store`), not `WithViewStore`/`@PresentationState`.
- [ ] UI-backing models/stores are `@MainActor`; blocking work is off the main actor in injected services.
- [ ] Domain shared with Android lives in KMP (`mvi-architecture`); iOS is a thin MV/MVVM shell, not a duplicated reducer.
