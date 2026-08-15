---
name: mobile-testing
description: Android and JVM testing - JUnit5, MockK, Turbine for Flow, and Compose UI testing for unit, integration, and UI tests; also applies to KMP commonTest running on the JVM/Android target. For iOS/Swift tests (XCTest, Swift Testing, XCUITest) use ios-testing. For TDD methodology and the three-tier test model (fake-first, coroutine and Compose UI testing) on Android/KMP prefer android-skills:android-tdd.
---

# Mobile Testing Patterns

Comprehensive testing for Android.

## Test Dependencies

```kotlin
// build.gradle.kts
dependencies {
    testImplementation("org.junit.jupiter:junit-jupiter:6.1.2") // JUnit 6 / Jupiter 6 — requires Java 17+
    testImplementation("io.mockk:mockk:1.14.9")
    testImplementation("app.cash.turbine:turbine:1.2.1")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
    testImplementation("io.kotest:kotest-assertions-core:6.1.5")
    
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
```

## ViewModel Testing

```kotlin
class HomeViewModelTest {
    @MockK private lateinit var repository: HomeRepository
    private lateinit var viewModel: HomeViewModel

    @BeforeEach
    fun setup() {
        MockKAnnotations.init(this)
        viewModel = HomeViewModel(repository)
    }

    @Test
    fun `loads items successfully`() = runTest {
        coEvery { repository.getItems() } returns Result.success(listOf(item))

        viewModel.state.test {
            viewModel.onIntent(LoadItems)
            awaitItem().isLoading shouldBe true
            awaitItem().items shouldBe listOf(item)
        }
    }
}
```

## Repository Testing

```kotlin
class UserRepositoryTest {
    @MockK private lateinit var api: UserApi
    private lateinit var repository: UserRepository

    @Test
    fun `getUser returns mapped domain model`() = runTest {
        coEvery { api.getUser("1") } returns UserDto("1", "John")

        val result = repository.getUser("1")

        result.isSuccess shouldBe true
        result.getOrNull()?.name shouldBe "John"
    }
}
```

## Compose UI Testing

```kotlin
class HomeScreenTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun `displays items`() {
        rule.setContent {
            HomeContent(state = HomeState(items = listOf(item)))
        }

        rule.onNodeWithText(item.name).assertIsDisplayed()
    }
}
```

## Coverage Target: 80%

```bash
./gradlew koverHtmlReport
```
