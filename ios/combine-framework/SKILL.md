---
name: combine-framework
description: Apple Combine framework for reactive programming - publishers, subscribers, operators, and error handling. Combine is the legacy reactive approach; for modern SwiftUI state management the default is the Observation framework (@Observable) - see swiftui-observation. Use Combine for existing codebases, custom publisher pipelines, and event streams.
---

# Combine Framework

Reactive programming with Apple's Combine framework.

**See also:** Combine is the legacy reactive stack. For new SwiftUI state, prefer the Observation framework (`@Observable`) — see the `swiftui-observation` skill. Reach for Combine for existing `ObservableObject`/`@Published` code, custom publisher pipelines, and event streams.

## Core Concepts

### Publisher & Subscriber

```swift
// ✅ Basic subscription
let publisher = Just("Hello")
let cancellable = publisher.sink { value in
    print(value)  // "Hello"
}  // sink returns AnyCancellable, not a Subscriber
```

### Creating Publishers

```swift
// ✅ Just - single value
Just(42)

// ✅ Future - one async result. Eager: the closure runs immediately at creation
// and the result is cached. Wrap in Deferred for lazy, per-subscriber execution.
Deferred {
    Future<Int, URLError> { promise in
        promise(.success(42))
        // or promise(.failure(URLError(.badServerResponse)))
    }
}

// ✅ PassthroughSubject - broadcast
let subject = PassthroughSubject<String, Never>()
subject.send("Hello")
subject.send(completion: .finished)

// ✅ CurrentValueSubject - holds current value
let currentValue = CurrentValueSubject<Int, Never>(0)
currentValue.send(1)
print(currentValue.value)  // 1

// ✅ @Published in ObservableObject
class ViewModel: ObservableObject {
    @Published var count = 0
}
```

## Common Operators

### Transform

```swift
// ✅ map - transform values
[1, 2, 3].publisher
    .map { $0 * 2 }
    .sink { print($0) }  // 2, 4, 6

// ✅ flatMap - nested publishers
[1, 2, 3].publisher
    .flatMap { value in
        Future<Int, Never> { promise in
            promise(.success(value * 2))
        }
    }
    .sink { print($0) }

// ✅ scan - accumulate
(1...10).publisher
    .scan(0, +)
    .sink { print($0) }  // 1, 3, 6, 10, 15...
```

### Filter

```swift
// ✅ filter
(1...10).publisher
    .filter { $0 % 2 == 0 }
    .sink { print($0) }  // 2, 4, 6, 8, 10

// ✅ removeDuplicates
[1, 1, 2, 2, 3].publisher
    .removeDuplicates()
    .sink { print($0) }  // 1, 2, 3

// ✅ debounce - wait for pause. Prefer DispatchQueue.main over RunLoop.main:
// RunLoop.main does not fire while the run loop is in tracking mode (scrolling).
searchTextPublisher
    .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
    .sink { text in
        performSearch(text)
    }
```

### Combine

```swift
// ✅ combineLatest - emits once both have emitted, then on every change of either
let namePublisher = CurrentValueSubject<String, Never>("")
let agePublisher = CurrentValueSubject<Int, Never>(0)

Publishers.CombineLatest(namePublisher, agePublisher)
    .sink { name, age in
        print("\(name), \(age)")
    }

// ✅ merge - same type, interleaved
let p1 = PassthroughSubject<Int, Never>()
let p2 = PassthroughSubject<Int, Never>()

p1.merge(with: p2)
    .sink { print($0) }

// ✅ zip - pairs up
let names = PassthroughSubject<String, Never>()
let ages = PassthroughSubject<Int, Never>()

names.zip(ages)
    .sink { print("\($0) is \($1) years old") }
```

## Error Handling

```swift
// ✅ catch - recover from error
failingPublisher
    .catch { error in
        return Just("Fallback value")
    }
    .sink { print($0) }

// ✅ retry - resubscribe on failure (up to 3 more times). Failure type is
// unchanged, so the two-closure sink is still required.
failingPublisher
    .retry(3)
    .sink { completion in
        // still fails after retries exhaust
    } receiveValue: { print($0) }

// ✅ replaceError - replace with default
riskyPublisher
    .replaceError(with: "Default")
    .sink { print($0) }

// ✅ mapError - transform error. Errors arrive in receiveCompletion, not receiveValue.
riskyPublisher
    .mapError { MyError.custom($0) }
    .sink { completion in
        if case .failure(let error) = completion {
            print(error)
        }
    } receiveValue: { value in
        print(value)
    }
```

## SwiftUI Integration

### @Published

```swift
class HomeViewModel: ObservableObject {
    @Published var users: [User] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var cancellables = Set<AnyCancellable>()

    func loadUsers() {
        isLoading = true

        service.getUsers()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                self?.isLoading = false
                if case .failure(let error) = completion {
                    self?.errorMessage = error.localizedDescription
                }
            } receiveValue: { [weak self] users in
                self?.users = users
            }
            .store(in: &cancellables)
    }
}
```

### Assign

Both overloads require `Failure == Never` (use `replaceError`/`catch` first).

```swift
// ✅ assign(to:) - republish into an @Published property of the same class.
// No AnyCancellable: lifetime is tied to the Published property.
publisher
    .map(\.name)
    .assign(to: &$userName)

// ✅ assign(to:on:) - write to any key path; returns AnyCancellable.
// ⚠️ Strongly retains `on` - .assign(to: ..., on: self) creates a retain cycle;
// use .sink { [weak self] ... } or assign(to: &$property) instead.
publisher
    .map(\.text)
    .assign(to: \.text, on: label)
    .store(in: &cancellables)
```

## Debounced Search Pipeline

`map` + `switchToLatest` (not `flatMap`) so a new query cancels the in-flight search — `flatMap` merges all in-flight requests and results can arrive out of order.

```swift
class SearchViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var results: [SearchResult] = []

    init() {
        $searchText
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .map { [unowned self] query in  // unowned: pipeline lifetime == self
                search(query)
                    .catch { _ in Just([]) }
            }
            .switchToLatest()
            .receive(on: DispatchQueue.main)
            .assign(to: &$results)
    }

    private func search(_ query: String) -> AnyPublisher<[SearchResult], Error> {
        // Perform search
    }
}
```

## System Publishers

Combine ships publishers for common sources — do not hand-roll them. A truly custom `Publisher` (with its own `Subscription`) is rarely needed; prefer a Subject you `send` into, or `Deferred { Future { ... } }` for callback APIs.

```swift
// ✅ NotificationCenter (built-in)
NotificationCenter.default
    .publisher(for: UIApplication.didBecomeActiveNotification)
    .sink { _ in print("App became active") }
    .store(in: &cancellables)

// ✅ Timer
Timer.publish(every: 1, on: .main, in: .common)
    .autoconnect()
    .sink { date in print(date) }
    .store(in: &cancellables)

// ✅ URLSession
URLSession.shared.dataTaskPublisher(for: url)
    .map(\.data)
    .decode(type: User.self, decoder: JSONDecoder())
    .receive(on: DispatchQueue.main)
    .sink { completion in
        // handle .failure
    } receiveValue: { user in
        print(user)
    }
    .store(in: &cancellables)
```

## Memory Management

A dropped `AnyCancellable` cancels the subscription immediately — never discard `sink`'s return value or hold it in a local variable.

```swift
class ViewModel {
    private var cancellables = Set<AnyCancellable>()
    private var single: AnyCancellable?

    func setup() {
        // ✅ Store in a set - cancelled when the owner deallocates
        publisher
            .sink { value in
                print(value)
            }
            .store(in: &cancellables)

        // ✅ Or hold one cancellable; set to nil to cancel early
        single = otherPublisher
            .sink { value in
                print(value)
            }
    }
}
```

## Bridging to Swift Concurrency

```swift
// ✅ Every publisher exposes .values as an AsyncSequence
for await value in viewModel.$searchText.values {
    print(value)
}

// Failure != Never: iterate with `for try await`
```

## Testing

```swift
func testPublisher_transformsValues() {
    var results: [Int] = []

    let cancellable = [1, 2, 3].publisher
        .map { $0 * 2 }
        .sink { results.append($0) }

    XCTAssertEqual(results, [2, 4, 6])
    cancellable.cancel()
}
```

For time-based operators (`debounce`, `delay`), inject the scheduler and use a test scheduler (e.g. pointfreeco/combine-schedulers) instead of waiting on real time.
