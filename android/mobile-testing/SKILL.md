---
name: mobile-testing
description: Android and JVM testing - JUnit5, MockK, Turbine for Flow, and Compose UI testing for unit, integration, and UI tests; also applies to KMP commonTest running on the JVM/Android target. For iOS/Swift tests (XCTest, Swift Testing, XCUITest) use ios-testing. For TDD methodology and the three-tier test model (fake-first, coroutine and Compose UI testing) on Android/KMP prefer android-skills:android-tdd.
---

# Mobile Testing Patterns

## Test Dependencies

```kotlin
// build.gradle.kts
dependencies {
    testImplementation(platform("org.junit:junit-bom:6.1.3")) // JUnit 6 / Jupiter 6 — requires Java 17+
    testImplementation("org.junit.jupiter:junit-jupiter")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher") // mandatory since Gradle 9
    testImplementation("io.mockk:mockk:1.14.11")
    testImplementation("app.cash.turbine:turbine:1.2.1")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
    testImplementation("io.kotest:kotest-assertions-core:6.2.4")

    androidTestImplementation(platform("androidx.compose:compose-bom:2026.08.00"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}

// Without useJUnitPlatform() the Jupiter tests are never discovered — the task
// reports success with zero tests. This form works in JVM, KMP and AGP modules:
tasks.withType<Test>().configureEach { useJUnitPlatform() }
```

- `androidTestImplementation` does not extend `implementation`, so the Compose BOM must be repeated there; `debugImplementation` does extend it, so `ui-test-manifest` inherits the version.
- `android { testOptions { unitTests.all { it.useJUnitPlatform() } } }` still works under `com.android.application`/`com.android.library`. AGP 9 forbids those plugins alongside `org.jetbrains.kotlin.multiplatform`, and the replacement `com.android.kotlin.multiplatform.library` plugin has no `testOptions` DSL — KMP modules need the `tasks.withType<Test>` form.
- Jupiter and MockK are JVM-only (MockK publishes a `jvm` variant and nothing else) — declare them in `jvmTest`/`androidUnitTest` only. `kotlin("test")`, Turbine, `kotlinx-coroutines-test` and `kotest-assertions-core` are all published for every KMP target, so they belong in `commonTest`.

## ViewModel Testing

`viewModelScope` dispatches to `Dispatchers.Main` — replace it in unit tests or every launch crashes. Use a JUnit 5 extension:

```kotlin
class MainDispatcherExtension : BeforeEachCallback, AfterEachCallback {
    override fun beforeEach(context: ExtensionContext) =
        Dispatchers.setMain(UnconfinedTestDispatcher())
    override fun afterEach(context: ExtensionContext) = Dispatchers.resetMain()
}

@ExtendWith(MainDispatcherExtension::class)
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
            awaitItem() shouldBe HomeState() // StateFlow replays current state first
            viewModel.onIntent(LoadItems)
            awaitItem().isLoading shouldBe true
            awaitItem().items shouldBe listOf(item)
        }
    }
}
```

With `UnconfinedTestDispatcher` intermediate states may be conflated — if the loading emission is skipped, assert only the final state or switch to `StandardTestDispatcher` plus `runCurrent()`.

## Repository Testing

```kotlin
class UserRepositoryTest {
    private val api = mockk<UserApi>()
    private val repository = UserRepositoryImpl(api)

    @Test
    fun `getUser returns mapped domain model`() = runTest {
        coEvery { api.getUser("1") } returns UserDto("1", "John")

        val result = repository.getUser("1")

        result.isSuccess shouldBe true
        result.getOrNull()?.name shouldBe "John"
    }
}
```

Prefer hand-written fakes over mocks for repositories consumed by many tests — see android-skills:android-tdd.

## Compose UI Testing

Instrumented tests (`androidTest/`) run on JUnit 4, not Jupiter — keep `@get:Rule`/`@Test` from JUnit 4 here. Backtick method names with spaces need API 30+ devices; use camelCase for wider device coverage.

```kotlin
import androidx.compose.ui.test.junit4.v2.createComposeRule

class HomeScreenTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun displaysItems() {
        rule.setContent {
            HomeContent(state = HomeState(items = listOf(item)))
        }

        rule.onNodeWithText(item.name).assertIsDisplayed()
    }
}
```

Compose 1.12 (BOM `2026.08.00`) deprecates `createComposeRule`/`createAndroidComposeRule`/`AndroidComposeTestRule` in `androidx.compose.ui.test.junit4`; the replacements keep the same names in `androidx.compose.ui.test.junit4.v2`. The v2 rules run composition on `StandardTestDispatcher` instead of `UnconfinedTestDispatcher`, so tests that relied on effects executing eagerly need an explicit `rule.waitForIdle()` or `rule.mainClock.advanceTimeBy(…)`.

Test the stateless content composable with a fixed state, not the stateful screen — no DI or ViewModel needed. Use `createAndroidComposeRule<MainActivity>()` (also from `…junit4.v2`) only when the test needs the real Activity (e.g. string resources, back handling); either rule needs `testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"` in `defaultConfig`.

For Compose Multiplatform, the same assertions run from `commonTest` with the rule-free `runComposeUiTest { setContent { … } }` — import `androidx.compose.ui.test.v2.runComposeUiTest`, annotate `@OptIn(ExperimentalTestApi::class)`, and add `org.jetbrains.compose.ui:ui-test:1.12.0` to `commonTest`.

## Coverage

```kotlin
plugins {
    id("org.jetbrains.kotlinx.kover") version "0.9.9"
}
```

```bash
./gradlew koverHtmlReport
```

Target ~80% on ViewModels, repositories, and mappers; exclude generated code and pure UI.
