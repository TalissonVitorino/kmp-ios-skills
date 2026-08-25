---
name: swift-patterns
description: Core Swift language patterns, optionals, closures, protocols, generics, and modern Swift features.
---

# Swift Language Patterns

Modern Swift idioms for clean, safe code.

## Optionals

### Safe Unwrapping

```swift
// ✅ Good: guard let for early exit
func processUser(_ user: User?) {
    guard let user = user else {
        print("User is nil")
        return
    }
    // user is non-optional here
    print(user.name)
}

// ✅ Good: if let for conditional
if let email = user.email {
    sendEmail(to: email)
}

// ✅ Good: nil coalescing
let displayName = user.name ?? "Anonymous"

// ✅ Good: Optional chaining
let street = user.address?.street

// ❌ Bad: Force unwrap (crashes if nil)
let email = user.email!  // Don't do this
```

### Optional Mapping

```swift
// ✅ Optional.map — transform the wrapped value (no `?` before .map)
let uppercase = user.name.map { $0.uppercased() }  // String?

// ✅ Optional.flatMap — when the transform itself returns an optional
let domain = user.email.flatMap { $0.split(separator: "@").last }  // Substring?

// ❌ Bad: `user.name?.map { ... }` optional-chains into String's
// Sequence.map — it maps over Characters and yields [String]?, not String?
```

## Closures

### Trailing Closures

```swift
// ✅ Trailing closure syntax
viewModel.fetchUsers { users in
    self.users = users
}

// Equivalent to the non-trailing form
viewModel.fetchUsers(completion: { users in
    self.users = users
})

// ✅ Shorthand argument names
viewModel.fetchUsers {
    self.users = $0
}
```

### Capture Lists

```swift
// ✅ Capture lists to avoid retain cycles
final class UserListViewController: UITableViewController {
    private let viewModel = UserViewModel()
    private var timer: Timer?

    func setupRefresh() {
        viewModel.onRefresh = { [weak self] in
            guard let self else { return }  // shorthand since Swift 5.7
            self.tableView.reloadData()
        }
    }

    // ⚠️ A repeating Timer retains its closure until invalidate() —
    // a strong `[self]` capture there is a retain cycle. Use weak self:
    func setupTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateUI()
        }
    }

    private func updateUI() { tableView.reloadData() }
}
```

### Higher-Order Functions

```swift
let numbers = [1, 2, 3, 4, 5]

// ✅ map - transform
let doubled = numbers.map { $0 * 2 }  // [2, 4, 6, 8, 10]

// ✅ filter - select
let evens = numbers.filter { $0 % 2 == 0 }  // [2, 4]

// ✅ reduce - combine
let sum = numbers.reduce(0) { $0 + $1 }  // 15

// ✅ compactMap - transform and drop nils in one pass
let emails = users.compactMap(\.email)  // [String] from `email: String?`
// (the stdlib has no non-optional overload: a non-optional transform silently
// promotes to `T?`, so compactMap degenerates into map with no diagnostic. Use map.)

// ✅ forEach - side effects
numbers.forEach { print($0) }

// ❌ Don't use forEach for transformation
// ❌ Bad: numbers.forEach { doubled.append($0 * 2) }
// ✅ Good: let doubled = numbers.map { $0 * 2 }
```

## Properties

### Computed Properties

```swift
struct User {
    let firstName: String
    let lastName: String

    // ✅ Computed property
    var fullName: String {
        "\(firstName) \(lastName)"
    }

    // ✅ With setter
    var age: Int {
        get { _age }
        set {
            guard newValue >= 0 else { return }
            _age = newValue
        }
    }
    private var _age: Int = 0
}
```

### Property Observers

`willSet`/`didSet` do **not** fire when the property is assigned inside the type's
own `init`, and assigning inside `didSet` does not re-enter the observer.

```swift
class Settings {
    var theme: Theme = .light {
        didSet {
            saveSettings()
            notifyThemeChanged()
        }
    }

    var score: Int = 0 {
        willSet {
            print("Score will change from \(score) to \(newValue)")
        }
        didSet {
            if oldValue > score {
                print("Score decreased!")
            }
        }
    }
}
```

### Lazy Properties

```swift
// Note: use a class — accessing a lazy var mutates the instance, so in a
// struct every caller would need `mutating` (and a `let` struct can't call it).
final class DataProcessor {
    // ✅ Lazy - created only when accessed (not thread-safe: first access races)
    private lazy var formatter: DateFormatter = {
        let formatter = DateFormatter()
        // A fixed dateFormat MUST pin the locale, or 12/24-hour and non-Gregorian
        // user settings corrupt the output.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    func process(date: Date) -> String {
        formatter.string(from: date)
    }
}
```

For user-facing dates prefer `date.formatted(...)` / `Date.FormatStyle` over
`DateFormatter` — see the `swift-formatstyle` skill.

## Protocols

### Protocol-Oriented Programming

```swift
// ✅ Protocol with associated type
protocol Repository {
    associatedtype Item
    func fetch(id: String) async throws -> Item
    func save(_ item: Item) async throws
}

// ✅ Protocol extension providing a default implementation
// `withThrowingTaskGroup(of:)` requires a Sendable child result, so omitting
// `Item: Sendable` is a hard error; `Self: Sendable` clears the SendableMetatypes
// warning for capturing `Self.Type` in the child task. Constrain the extension
// rather than the protocol.
extension Repository where Self: Sendable, Item: Sendable {
    // Results arrive in completion order, not input order.
    func fetchAll(ids: [String]) async throws -> [Item] {
        try await withThrowingTaskGroup(of: Item.self) { group in
            for id in ids {
                group.addTask { try await self.fetch(id: id) }
            }
            return try await group.reduce(into: [Item]()) { $0.append($1) }
        }
    }
}
```

### Protocol Extensions

```swift
// ⚠️ This custom `Identifiable` shadows Swift's stdlib `Swift.Identifiable`.
// Don't redeclare it — conform to `Swift.Identifiable` (its `id` is an associated
// `ID: Hashable`, not `String`) and put the helper in an extension instead:
//   extension Identifiable { func debugInfo() -> String { "ID: \(id)" } }
// Renamed below to avoid the clash.
protocol DebugIdentifiable {
    var id: String { get }
}

extension DebugIdentifiable {
    func debugInfo() -> String {
        "ID: \(id)"
    }
}

struct User: DebugIdentifiable {
    let id: String
    let name: String
}

let user = User(id: "123", name: "John")
print(user.debugInfo())  // "ID: 123"
```

## Generics

### Generic Functions

```swift
// ✅ Generic function
func first<T>(_ array: [T]) -> T? {
    array.first
}

// ✅ With constraints
func sorted<T: Comparable>(_ array: [T]) -> [T] {
    array.sorted()
}

// ✅ Multiple constraints
func process<T: Sequence & Sendable>(_ items: T) where T.Element: Hashable {
    // Process items
}
```

### Associated Types

```swift
// ✅ Declare a primary associated type (Swift 5.7+) so callers can constrain it
protocol DataSource<Item> {
    associatedtype Item
    func getItems() async throws -> [Item]
}

final class RemoteDataSource: DataSource {
    // Item is inferred as User from getItems(); no explicit typealias needed
    func getItems() async throws -> [User] {
        try await api.getUsers()
    }
}

// Lets you write constrained opaque and existential types instead of generics
func show(_ source: some DataSource<User>) { }
let erased: any DataSource<User> = RemoteDataSource()
```

## Result Type

Prefer `async throws` for async APIs — `Result` is for bridging completion handlers,
storing an outcome as state, or deferring error handling. Since Swift 6, a thrown
error can also be typed (`func load() throws(NetworkError) -> User`, SE-0413), which
covers most of what `Result`'s `Failure` generic was used for. See the
`error-handling-result` skill for the full decision table.

```swift
// Bridging / storing an outcome — not the default shape for a new async API
func fetchUser(id: String) async -> Result<User, Error> {
    do {
        let user = try await api.getUser(id)
        return .success(user)
    } catch {
        return .failure(error)
    }
}

// Usage
let result = await fetchUser(id: "123")
switch result {
case .success(let user):
    displayUser(user)
case .failure(let error):
    showError(error)
}

// ✅ map, flatMap on Result (key path literals convert to functions, SE-0249)
let nameResult = await fetchUser(id: "123").map(\.name)  // Result<String, Error>
```

## Async/Await

Language-level basics only — for actors, isolation, `Sendable`, and Swift 6 data-race
diagnostics use the `swift-concurrency` skill (`swift-concurrency-6-2` for the 6.2
model: `nonisolated(nonsending)`, `@concurrent`, `-default-isolation MainActor`).

### Structured Concurrency

```swift
// ✅ async let for concurrent work
func loadDashboard() async throws -> Dashboard {
    async let user = getUser()
    async let notifications = getNotifications()
    async let stats = getStats()

    return try await Dashboard(
        user: user,
        notifications: notifications,
        stats: stats
    )
}

// ✅ TaskGroup for dynamic concurrency.
// The child result type must be Sendable, and results arrive in completion
// order — collect (index, value) pairs if you need the input order back.
func downloadAll(urls: [URL]) async throws -> [Data] {
    try await withThrowingTaskGroup(of: Data.self) { group in
        for url in urls {
            group.addTask {
                try await URLSession.shared.data(from: url).0
            }
        }

        var results: [Data] = []
        for try await data in group {
            results.append(data)
        }
        return results
    }
}
```

### MainActor

```swift
// ✅ MainActor for UI updates
@MainActor
@Observable
final class HomeViewModel {
    var users: [User] = []

    func loadUsers() async {
        // Already on the main actor; the `await` suspends without leaving it
        self.users = (try? await api.getUsers()) ?? []
    }
}

// ✅ Hop to the main actor only from non-isolated code
final class NetworkService: Sendable {
    func fetch(from url: URL) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: url)
        await MainActor.run {
            // UI work, isolated to the main actor
        }
        return data
    }
}

// ⚠️ A nonisolated `async` function does not guarantee a background thread.
// Under Swift 6.2's `NonisolatedNonsendingByDefault` it runs on the caller's
// actor, so calling it from `@MainActor` code keeps the work on main. Mark it
// `@concurrent` to force it off the caller's actor.
```

## Enums

### Associated Values

```swift
// ✅ Enum with associated values
enum NetworkError: Error {
    case invalidURL
    case noConnection
    case serverError(code: Int, message: String)
    case decodingError(Error)
}

func handle(_ error: NetworkError) {
    switch error {
    case .invalidURL:
        print("Invalid URL")
    case .noConnection:
        print("No connection")
    case .serverError(let code, let message):
        print("Server error \(code): \(message)")
    case .decodingError(let error):
        print("Decoding failed: \(error)")
    }
}
```

### Enum as State

```swift
// ✅ Enum for exhaustive state
enum LoadState<T> {
    case idle
    case loading
    case loaded(T)
    case error(Error)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var value: T? {
        if case .loaded(let value) = self { return value }
        return nil
    }
}

// Usage — a plain `var` on an @Observable model (iOS 17+); @Published only exists
// inside an ObservableObject and is legacy for new code. See swiftui-observation.
@MainActor
@Observable
final class UsersModel {
    var state: LoadState<[User]> = .idle
}

struct UsersScreen: View {
    @State private var model = UsersModel()

    var body: some View {
        switch model.state {
        case .idle:
            EmptyView()
        case .loading:
            ProgressView()
        case .loaded(let users):
            UserList(users: users)
        case .error(let error):
            ErrorView(error: error)
        }
    }
}
```

## Access Control

```swift
// ✅ Use explicit access control
public struct PublicAPI {
    public var value: String

    // ✅ public init must be explicit — the memberwise init is internal,
    // so without this the type can't be constructed from other modules
    public init(value: String = "default") {
        self.value = value
    }

    // ✅ private (this declaration, plus same-type extensions in this file)
    private var helper: String {
        "helper"
    }

    // ✅ internal (default, same module)
    var internalValue: String = "internal"

    // ✅ fileprivate (same file)
    fileprivate var fileOnly: String = "fileOnly"

    // ✅ package (Swift 5.9+) — visible to every module in the same SwiftPM
    // package, but not to its clients. The right level for cross-module
    // internals in a modularized app; needs `-package-name` when built by hand.
    package var sharedAcrossModules: String = "package"
}

// `public` classes cannot be subclassed outside their module — use `open` for that.
open class Plugin {}
```

## Key Paths

```swift
// ✅ Key paths for type-safe references
struct User {
    let name: String
    let email: String
    let age: Int
}

let users = [User(name: "Ada", email: "ada@example.com", age: 36)]

// ✅ Key path literal used as a function (SE-0249)
let names = users.map(\.name)  // [String]

// ✅ Key path stored as a value
let nameKeyPath: KeyPath<User, String> = \.name
let firstName = users[0][keyPath: nameKeyPath]

// ✅ Generic over the value type, not hardcoded to String
func sorted<T, V: Comparable>(_ items: [T], by keyPath: KeyPath<T, V>) -> [T] {
    items.sorted { $0[keyPath: keyPath] < $1[keyPath: keyPath] }
}

let byName = sorted(users, by: \.name)
let byAge = sorted(users, by: \.age)
```
