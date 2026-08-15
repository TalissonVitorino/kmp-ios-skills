# Incremental migration recipes

Migrate live apps in shippable steps. Never a big-bang rewrite on a long-lived branch — each step below compiles, passes tests, and ships on its own.

## 1. `ObservableObject` → `@Observable`

Per model, leaves first:

| Before | After |
|---|---|
| `final class M: ObservableObject` | `@Observable final class M` |
| `@Published var x` | `var x` (remove `@Published`) |
| a non-observed stored dep | `@ObservationIgnored let dep` |
| `@StateObject var m = M()` | `@State private var m = M()` |
| `@ObservedObject var m` | `let m` (or `@Bindable var m` if you need `$`) |
| `@EnvironmentObject var m: M` | `@Environment(M.self) var m` + `.environment(m)` on the parent |

- Bindings to an `@Environment` model: add `@Bindable var m = m` inside `body`.
- Mixed tree is fine during the transition: an `ObservableObject` parent can host an `@Observable` child and vice-versa. Convert bottom-up so a child never observes a not-yet-migrated parent through the old machinery.
- Watch for over-invalidation you were relying on: Observation tracks only *read* properties, so a view that "updated on anything" may now update less — usually a win, occasionally a surprise. Full rules in `swiftui-observation`.

## 2. Massive View / UIKit MVC → SwiftUI MVVM

1. Extract logic from the view controller / giant view into an `@Observable @MainActor` view model with `init`-injected services.
2. Replace `isLoading`/`errorText`/`data` scatter with one `enum ViewState { case loading, loaded(X), failed(Error) }`.
3. Render the new SwiftUI screen inside the old flow with `UIHostingController(rootView:)`; keep the existing navigation driving it.
4. Delete the old controller once the screen is fully ported. Repeat per screen.

- Embed remaining UIKit pieces (a chart, a scanner) into SwiftUI via `UIViewControllerRepresentable`/`UIViewRepresentable`. See `swiftui-uikit-interop`.

## 3. VIPER → MVVM + Clean + Coordinator

Map the five VIPER roles onto modern equivalents, one module at a time:

- **Presenter** → `@Observable` view model (view-facing state + intents).
- **Interactor** → Clean **use case** (`struct DoThing { let repo: Repo; func callAsFunction() ... }`).
- **Entity** → domain model (plain Swift / shared KMP).
- **Router** → **Coordinator** owning a `NavigationPath`.
- **View** → SwiftUI view.

Order: introduce the use case + repo protocol first (behind the existing interactor), then swap the presenter for an `@Observable` model, then lift routing into a coordinator. Drop VIPER protocols as each role migrates.

## 4. Introducing Clean layering into an ad-hoc app

1. Define a `protocol XRepository` and point existing view models at it (concrete impl injected at the composition root).
2. Move the actual network/DB/keychain code into the concrete repository. View models now depend on the protocol only — instant test seam.
3. Extract a **use case** only where a rule is shared across screens or must move money / enforce a limit. Don't manufacture one use case per repository method.
4. Wire everything at one composition root (App entry or DI container; shared DI → `kmp-di`).

## 5. MV/MVVM → TCA (per feature)

- Convert at a navigation boundary; the rest of the app stays as-is. A TCA `StoreOf<Feature>` is created by whatever hosts the screen (TCA or not).
- Steps: `@Reducer` shell with empty `body` → move state into `@ObservableState` → move intents into `Action` → move logic into `Reduce` → replace service calls with `@Dependency` → add a `TestStore` test.
- Keep the blast radius to one feature per PR. A half-TCA feature (some state in the reducer, some in a stray `@State`) is worse than either endpoint — finish the feature before moving on.

## Strangler-fig ordering for a live fintech app

Migrate outside-in so risk stays low and money paths change last:

1. **New screens** ship in the target architecture (MV/MVVM + Clean) from day one — stop growing the old pattern.
2. **Read-only screens** (balances, statements, activity) migrate next — low blast radius, easy to verify.
3. **Settings / profile** flows — introduce the Coordinator here.
4. **Auth / onboarding / KYC** — coordinator-driven flows, biometric seams via `swift-security`.
5. **Money movement** (transfers, payments) **last**, only after the domain use cases and their tests exist — never refactor a live money path and its architecture in the same change.

At every step: the domain layer (use cases, repo protocols, `kmp-money` math) is stable and framework-free, so the UI pattern underneath can change without touching business rules.
