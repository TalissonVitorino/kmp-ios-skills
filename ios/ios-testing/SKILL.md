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
    // #require unwraps/stops the test when the precondition fails.
    let users = try #require(try await sut.fetchUsers())
    #expect(!users.isEmpty)
}
```

### Suites and setup

```swift
// @Suite groups tests; init/deinit replace setUp/tearDown and give each
// test a fresh instance (parallel by default, no shared mutable state).
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

## Async Testing

```swift
func testAsyncOperation_completesSuccessfully() async throws {
    // Given
    let expectation = expectation(description: "Async completes")

    // When
    Task {
        await sut.asyncOperation()
        expectation.fulfill()
    }

    // Then
    await fulfillment(of: [expectation], timeout: 1.0)
}

// ✅ Swift async/await
func testAsyncFetch_returnsUsers() async throws {
    let users = try await sut.fetchUsers()
    XCTAssertFalse(users.isEmpty)
}
```

## Property Testing

```swift
func testUserValidation_validEmails() {
    let validEmails = [
        "test@example.com",
        "user.name@example.co.uk",
        "user+tag@example.com"
    ]

    for email in validEmails {
        XCTAssertTrue(Validator.isValidEmail(email), "Failed for: \(email)")
    }
}

func testUserValidation_invalidEmails() {
    let invalidEmails = [
        "invalid",
        "@example.com",
        "user@",
        "user @example.com"
    ]

    for email in invalidEmails {
        XCTAssertFalse(Validator.isValidEmail(email), "Passed for: \(email)")
    }
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

        // Then
        XCTAssertTrue(app.staticTexts["welcomeMessage"].exists)
    }
}
```

### Snapshot Testing

```swift
// ✅ Using View snapshot testing
import SwiftUI
import XCTest

struct UserCard_Previews: PreviewProvider {
    static var previews: some View {
        UserCard(user: .mock)
    }
}

// Snapshot test
func testUserCard_snapshot() {
    let view = UserCard(user: .mock)
    assertSnapshot(matching: view, as: .image(layout: .sizeThatFits))
}
```

## Testing SwiftUI Views

```swift
import XCTest
import ViewInspector  // https://github.com/nalexn/ViewInspector

class UserRowTests: XCTestCase {
    func testUserRow_displaysUserName() throws {
        let user = User(id: "1", name: "John Doe", email: "john@example.com")
        let view = UserRow(user: user)

        let text = try view.inspect().find(ViewType.Text.self).string()
        XCTAssertEqual(text, "John Doe")
    }

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

// ✅ Wait helpers
func waitForElementToExist(
    _ element: XCUIElement,
    timeout: TimeInterval = 5.0
) -> Bool {
    let existsPredicate = NSPredicate(format: "exists == true")
    let expectation = expectation(for: existsPredicate, evaluatedWith: element)

    let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
    return result == .completed
}
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
