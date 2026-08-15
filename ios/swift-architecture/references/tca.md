# TCA depth — navigation, dependencies, testing

Grounded in `pointfreeco/swift-composable-architecture` (modern 1.7+ surface). Use only after you've decided a feature earns TCA (see the main skill's decision table).

## Reducer composition

- A feature's `body` is a `some ReducerOf<Self>` built from reducer operators. Compose children into a parent with `Scope`, `.ifLet`, `.forEach`:

```swift
var body: some ReducerOf<Self> {
    Scope(state: \.settings, action: \.settings) { SettingsFeature() }  // always-present child
    Reduce { state, action in
        // parent logic; observe child delegate actions here
        switch action {
        case .settings(.delegate(.signedOut)):
            state = State()               // react to child
            return .none
        default: return .none
        }
    }
    .ifLet(\.$editItem, action: \.editItem) { EditItemFeature() }        // optional child
    .forEach(\.rows, action: \.rows) { RowFeature() }                    // collection of children
}
```

- **Child → parent** communication uses a `delegate` action the child emits via `.send(.delegate(...))`; the parent matches on it. Don't reach into child state from the parent's reducer.

## Navigation

### Tree-based (optionals / enums)

```swift
@ObservableState
struct State {
    @Presents var destination: Destination.State?
}
@Reducer
enum Destination {                    // one enum reducer for all destinations of a screen
    case addItem(ItemForm)
    case detail(ItemDetail)
}
// in body:
.ifLet(\.$destination, action: \.destination)
```

```swift
// View: drive each case off the scoped destination store
.sheet(item: $store.scope(state: \.destination?.addItem, action: \.destination.addItem)) { store in
    ItemFormView(store: store)
}
```

### Stack-based (push navigation)

```swift
@ObservableState
struct State { var path = StackState<Path.State>() }
enum Action { case path(StackActionOf<Path>) }
@Reducer enum Path { case detail(Detail); case settings(Settings) }
// in body:
.forEach(\.path, action: \.path)
```

```swift
NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
    RootView(store: store)
} destination: { store in
    switch store.case {
    case .detail(let s):   DetailView(store: s)
    case .settings(let s): SettingsView(store: s)
    }
}
```

## Dependencies

```swift
struct NumberFactClient: Sendable {
    var fetch: @Sendable (Int) async throws -> String
}
extension NumberFactClient: DependencyKey {
    static let liveValue = Self { count in
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://numbersapi.com/\(count)")!)
        return String(decoding: data, as: UTF8.self)
    }
    static let testValue = Self(fetch: unimplemented("NumberFactClient.fetch"))  // fails if unexpectedly called
}
extension DependencyValues {
    var numberFact: NumberFactClient {
        get { self[NumberFactClient.self] }
        set { self[NumberFactClient.self] = newValue }
    }
}
```

- Read with `@Dependency(\.numberFact) var numberFact` inside the reducer.
- TCA ships controlled versions of common deps: `\.uuid`, `\.date`, `\.continuousClock`, `\.mainQueue`, `\.withRandomNumberGenerator`. Use these instead of `UUID()`, `Date()`, `Task.sleep` so effects are deterministic in tests.
- Override at any scope with `withDependencies { $0.date = .constant(.init(...)) }`.

## Effects

- `.run { send in ... }` — async work; can `await send(...)` many times. Auto-cancelled when the feature is torn down.
- `.cancellable(id:)` / `.cancel(id:)` — dedupe or cancel in-flight work (search-as-you-type, refresh).
- `.merge(...)` / `.concatenate(...)` — combine effects.
- Long-living effects (websocket, location stream): model as an `AsyncStream` from a dependency, consumed inside `.run`.

## Testing

- `TestStore` asserts **exhaustively**: every state mutation you don't describe, and every effect action you don't `receive`, fails the test.

```swift
@Test func search() async {
    let clock = TestClock()
    let store = await TestStore(initialState: Search.State()) { Search() }
        withDependencies: {
            $0.continuousClock = clock
            $0.numberFact.fetch = { "\($0)!" }
        }
    await store.send(.queryChanged("1")) { $0.query = "1" }
    await clock.advance(by: .milliseconds(300))          // fire the debounce
    await store.receive(\.response) { $0.result = "1!" }
}
```

- Use `store.exhaustivity = .off` (or `.off(showSkippedAssertions: true)`) for large integration-style tests where asserting every field is noise; keep exhaustive for unit-level reducer tests.
- `receive(\.caseKeyPath)` matches by case; provide the trailing closure to assert the resulting state.
- `TestClock` / immediate clock replaces real time so debounces and timers are instant and deterministic.

## Migration into an existing app

- Adopt at a navigation boundary: one screen becomes a `@Reducer` feature; its parent (still MV/UIKit) hosts it by constructing a `Store` and passing `StoreOf<Feature>` into the SwiftUI view.
- A TCA parent can embed a non-TCA SwiftUI child directly (it's just a view). A non-TCA screen can present a TCA screen by owning the `Store` in `@State`.
- Don't convert leaf models to `@Dependency` until the feature itself is TCA — mixing halfway adds ceremony without the payoff.
