---
name: ios-testing
description: iOS and Apple-platform testing - XCTest and the Swift Testing framework, XCUITest UI tests, mocks, and patterns for Swift/SwiftUI. iOS target tests. For Android/JVM tests (JUnit5, MockK, Turbine, Compose UI test) or KMP commonTest on the JVM use mobile-testing.
---

# iOS Testing

Testing patterns for Swift and SwiftUI apps.

Prefer the **Swift Testing** framework (Xcode 16+) for new unit tests; XCTest is still
required for UI tests (XCUITest) and performance measurement.

## Swift Testing

```swift
import Testing
@testable import MyApp

// @Test replaces test-prefixed methods; the name is a plain description.
@Test("Loading users populates the list")
func loadUsersSucceeds() async throws {
    let mockService = MockUserService()
    mockService.usersToReturn = [User.mock1, User.mock2]
    let sut = UserViewModel(service: mockService)

    await sut.loadUsers()

    // #expect for soft assertions (test continues on failure).
    #expect(sut.users == [User.mock1, User.mock2])
    #expect(sut.isLoading == false)
    #expect(sut.errorMessage == nil)
}

@Test func fetchReturnsUsers() async throws {
    let sut = makeSUT()
    let users = try await sut.fetchUsers()
    // #require unwraps an optional (or checks a condition) and STOPS the test on failure.
    let first = try #require(users.first)
    #expect(!first.name.isEmpty)
}
```

### Suites and setup

```swift
// @Suite groups tests; init replaces setUp and each test gets a fresh
// instance (parallel by default, no shared mutable state). For tearDown,
// use deinit — that requires a class or actor suite, not a struct.
@Suite("UserViewModel")
struct UserViewModelTests {
    let sut: UserViewModel
    let mockService: MockUserService

    init() {
        mockService = MockUserService()
        sut = UserViewModel(service: mockService)
    }

    @Test func failureSetsErrorMessage() async {
        mockService.shouldThrowError = true
        await sut.loadUsers()
        #expect(sut.users.isEmpty)
        #expect(sut.errorMessage != nil)
    }
}
```

### Parameterized tests

```swift
// One @Test runs once per argument (each shown separately in results).
@Test(arguments: [
    "test@example.com",
    "user.name@example.co.uk",
    "user+tag@example.com"
])
func validEmails(_ email: String) {
    #expect(Validator.isValidEmail(email))
}

// Expected errors:
@Test func throwsOnBadInput() async throws {
    await #expect(throws: NetworkError.noConnection) {
        try await sut.failingCall()
    }
}

// confirmation replaces XCTestExpectation for callback-based APIs:
@Test func delegateIsNotified() async {
    await confirmation("delegate called") { confirmed in
        sut.onUpdate = { confirmed() }
        await sut.refresh()
    }
}
```

## Unit Tests (XCTest)

### Basic Unit Test

```swift
import XCTest
@testable import MyApp

class UserViewModelTests: XCTestCase {
    var sut: UserViewModel!
    var mockService: MockUserService!

    override func setUp() {
        super.setUp()
        mockService = MockUserService()
        sut = UserViewModel(service: mockService)
    }

    override func tearDown() {
        sut = nil
        mockService = nil
        super.tearDown()
    }

    func testLoadUsers_whenSuccessful_populatesUsers() async throws {
        // Given
        let expectedUsers = [User.mock1, User.mock2]
        mockService.usersToReturn = expectedUsers

        // When
        await sut.loadUsers()

        // Then
        XCTAssertEqual(sut.users, expectedUsers)
        XCTAssertFalse(sut.isLoading)
        XCTAssertNil(sut.errorMessage)
    }

    func testLoadUsers_whenFailure_setsErrorMessage() async throws {
        // Given
        mockService.shouldThrowError = true

        // When
        await sut.loadUsers()

        // Then
        XCTAssertTrue(sut.users.isEmpty)
        XCTAssertNotNil(sut.errorMessage)
    }
}
```

### Mocking

```swift
// ✅ Protocol-based mocking
protocol UserServiceProtocol {
    func getUsers() async throws -> [User]
}

class MockUserService: UserServiceProtocol {
    var usersToReturn: [User] = []
    var shouldThrowError = false
    var getUsersCalled = false

    func getUsers() async throws -> [User] {
        getUsersCalled = true
        if shouldThrowError {
            throw NetworkError.noConnection
        }
        return usersToReturn
    }
}

// ✅ Verify method calls
func testRefreshButton_callsService() async {
    // When
    await sut.refresh()

    // Then
    XCTAssertTrue(mockService.getUsersCalled)
}
```

## Async Testing (XCTest)

```swift
// ✅ async functions: just await them directly — no expectation needed.
func testAsyncFetch_returnsUsers() async throws {
    let users = try await sut.fetchUsers()
    XCTAssertFalse(users.isEmpty)
}

// Expectations are for CALLBACK-based APIs only. In an async test use the
// async-safe fulfillment(of:), never waitForExpectations/wait(for:).
func testCallbackAPI_completes() async {
    let exp = expectation(description: "callback fired")
    sut.legacyFetch { _ in exp.fulfill() }
    await fulfillment(of: [exp], timeout: 1.0)
}
```

## UI Tests

### Basic UI Test

```swift
import XCTest

class LoginUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
    }

    func testLoginButton_enabledWhenFieldsFilled() {
        // When
        let emailField = app.textFields["emailField"]
        let passwordField = app.secureTextFields["passwordField"]
        let loginButton = app.buttons["loginButton"]

        // Then
        XCTAssertFalse(loginButton.isEnabled)

        // When
        emailField.tap()
        emailField.typeText("test@example.com")

        passwordField.tap()
        passwordField.typeText("password123")

        // Then
        XCTAssertTrue(loginButton.isEnabled)
    }

    func testSuccessfulLogin_navigatesToHome() {
        // Given
        app.textFields["emailField"].tap()
        app.textFields["emailField"].typeText("test@example.com")

        app.secureTextFields["passwordField"].tap()
        app.secureTextFields["passwordField"].typeText("password123")

        // When
        app.buttons["loginButton"].tap()

        // Then — after navigation, wait; a bare .exists check races the transition.
        XCTAssertTrue(app.staticTexts["welcomeMessage"].waitForExistence(timeout: 5))
    }
}
```

### Snapshot Testing

```swift
// pointfreeco/swift-snapshot-testing (1.19+); works in XCTest and Swift Testing.
import SnapshotTesting
import SwiftUI

// assertSnapshot(of:as:) — the old matching: label is deprecated.
func testUserCard_snapshot() {
    let view = UserCard(user: .mock)
    assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
    // Or pin to a device: .image(layout: .device(config: .iPhone13))
}
```

Record and compare on the same simulator model/OS — rendering differs across devices.

## Testing SwiftUI Views

```swift
import XCTest
import ViewInspector  // https://github.com/nalexn/ViewInspector

// With a Swift 6 compiler ViewInspector's `inspect()` is @MainActor-isolated, so the
// test methods must be too. Annotate the methods, not the class: a @MainActor subclass
// of the nonisolated XCTestCase is itself an isolation error in Swift 6 language mode.
final class UserRowTests: XCTestCase {
    @MainActor
    func testUserRow_displaysUserName() throws {
        let user = User(id: "1", name: "John Doe", email: "john@example.com")
        let view = UserRow(user: user)

        let text = try view.inspect().find(ViewType.Text.self).string()
        XCTAssertEqual(text, "John Doe")
    }

    @MainActor
    func testUserRow_tapping_callsAction() throws {
        let user = User(id: "1", name: "John", email: "john@example.com")
        var tapped = false
        let view = UserRow(user: user, onTap: { tapped = true })

        try view.inspect().find(ViewType.Button.self).tap()

        XCTAssertTrue(tapped)
    }
}
```

## Test Helpers

```swift
// ✅ Test doubles
extension User {
    static let mock1 = User(id: "1", name: "John", email: "john@example.com")
    static let mock2 = User(id: "2", name: "Jane", email: "jane@example.com")
}

// ✅ Waiting in UI tests: use the built-in API, not predicate expectations.
XCTAssertTrue(app.buttons["loginButton"].waitForExistence(timeout: 5))

// For conditions other than existence, use XCTNSPredicateExpectation + XCTWaiter:
let hittable = XCTNSPredicateExpectation(
    predicate: NSPredicate(format: "isHittable == true"),
    object: app.buttons["loginButton"]
)
XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 5), .completed)
```

## Performance Tests

```swift
func testUserParsing_performance() {
    let jsonData = largeUserJSONData

    measure {
        _ = try? JSONDecoder().decode([User].self, from: jsonData)
    }
}
```

## Test Organization

```
Tests/
├── Unit/
│   ├── ViewModels/
│   │   ├── HomeViewModelTests.swift
│   │   └── ProfileViewModelTests.swift
│   ├── Services/
│   │   ├── UserServiceTests.swift
│   │   └── NetworkServiceTests.swift
│   └── Models/
│       └── UserTests.swift
├── UI/
│   ├── LoginUITests.swift
│   └── HomeUITests.swift
└── Mocks/
    ├── MockUserService.swift
    └── MockNetworkService.swift
```
