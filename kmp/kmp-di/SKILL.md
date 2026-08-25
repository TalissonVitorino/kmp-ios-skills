---
name: kmp-di
description: Dependency injection for Kotlin Multiplatform (KMP/CMP) - shared Koin modules in commonMain, expect/actual platform modules, initKoin()/KoinApplication startup shared across Android and iOS, and consuming the Koin graph from Swift/iOS. Use for multiplatform or shared DI wiring. For an Android-only app use android-di-koin; for Koin DSL and scope fundamentals use koin-patterns.
---

# KMP Dependency Injection

Cross-platform dependency injection with Koin.

## Koin Multiplatform Setup

### Dependencies

```kotlin
// build.gradle.kts (shared module) — Koin 4.x, BOM-managed versions
kotlin {
    sourceSets {
        commonMain.dependencies {
            implementation(platform("io.insert-koin:koin-bom:4.2.2"))
            implementation("io.insert-koin:koin-core")
            // Compose Multiplatform UI only:
            implementation("io.insert-koin:koin-compose")
            implementation("io.insert-koin:koin-compose-viewmodel")
            // No Compose? The viewModel DSL alone is "io.insert-koin:koin-core-viewmodel"
            // (koin-compose-viewmodel already includes it transitively).
        }
        commonTest.dependencies {
            implementation("io.insert-koin:koin-test")  // test-only, never commonMain
        }
        androidMain.dependencies {
            implementation("io.insert-koin:koin-android")
        }
    }
}
```

### Module Definition

```kotlin
// commonMain/kotlin/di/AppModule.kt
val sharedModule = module {
    // ViewModels — multiplatform since Koin 4.x (viewModel DSL in commonMain)
    viewModelOf(::HomeViewModel)
    viewModelOf(::DetailViewModel)

    // Use Cases
    factory { GetUsersUseCase(get()) }
    factory { GetUserDetailUseCase(get()) }

    // Repositories
    single<UserRepository> { UserRepositoryImpl(get(), get()) }

    // Data Sources
    single { UserApi(get()) }
    single { createDatabase(get()) }
}
```

### Platform Modules

```kotlin
// androidMain/kotlin/di/PlatformModule.kt
val androidPlatformModule = module {
    includes(sharedModule)

    // Android-specific dependencies — Context comes from androidContext()
    // (configured in startKoin below), never `Context()` (it's abstract).
    single { PlatformConnectivityMonitor(androidContext()) }
    single { PlatformFileService(androidContext()) }
}

// iosMain/kotlin/di/PlatformModule.kt
val iosPlatformModule = module {
    includes(sharedModule)

    // iOS-specific dependencies
    single { PlatformConnectivityMonitor() }
    single { PlatformFileService() }
}
```

## Koin Start

### Android

```kotlin
// androidMain/kotlin/MyApp.kt
class MyApp : Application() {
    override fun onCreate() {
        super.onCreate()
        startKoin {
            androidContext(this@MyApp)
            modules(androidPlatformModule)
        }
    }
}
```

### iOS

```kotlin
// iosMain/kotlin/di/KoinInit.kt
fun initKoin() {
    startKoin {
        modules(iosPlatformModule)
    }
}

// Koin's get()/inject() are inline + reified, so they are not exported to
// Objective-C/Swift. Expose a helper object that resolves on the Kotlin side:
object KoinIOS : KoinComponent {
    val userRepository: UserRepository get() = get()
    val getUsersUseCase: GetUsersUseCase get() = get()
}

// Swift:
//   KoinInitKt.doInitKoin()
//   let repo = KoinIOS.shared.userRepository
```

### Compose Multiplatform

```kotlin
// commonMain — let Compose own the Koin lifecycle (koin-compose).
// Use this OR the platform startKoin calls above, not both.
@Composable
fun App() {
    KoinApplication(configuration = koinConfiguration {
        modules(sharedModule)
    }) {
        AppContent()
    }
}

// Desktop-only alternative: call startKoin { modules(...) } in jvmMain's
// fun main() before application { }.
```

## ViewModel Injection

Since Koin 4.x, androidx `ViewModel` is multiplatform: define ViewModels in
commonMain (declare with `viewModelOf(::HomeViewModel)` or `viewModel { }` in
the module) and inject them in shared composables with `koinViewModel()` from
`koin-compose-viewmodel` — no Android/iOS split needed.

```kotlin
// commonMain/kotlin/ui/HomeScreen.kt
@Composable
fun HomeScreen(
    viewModel: HomeViewModel = koinViewModel()
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    HomeContent(state)
}
```

For non-ViewModel dependencies in composables use `koinInject()` from
`koin-compose`. `getScreenModel<T>()` is a Voyager API — only if you use
voyager-koin.

## Definition Lifetimes

```kotlin
// ✅ factory - creates new instance each time
factory { GetUsersUseCase(get()) }

// ✅ single - shared instance
single<UserRepository> { UserRepositoryImpl(get(), get()) }

// ✅ scoped - tied to a scope's lifetime; only valid INSIDE a scope block
scope(named("home")) {
    scoped { HomeData(get()) }
}
```

## Named Dependencies

```kotlin
// ✅ Named dependencies
module {
    single(named("default")) { DefaultLogger() }
    single(named("analytics")) { AnalyticsLogger() }

    factory { MyRepository(logger = get(named("default"))) }
}
```

## Manual DI (Alternative)

### Simple Service Locator

```kotlin
// commonMain/kotlin/di/ServiceLocator.kt
object ServiceLocator {
    private val services = mutableMapOf<String, Any>()

    fun <T> get(key: String): T {
        return services[key] as T
    }

    fun register(key: String, service: Any) {
        services[key] = service
    }

    fun init() {
        register("repository", UserRepositoryImpl())
        register("api", UserApi())
    }
}
```

### Pure Kotlin DI

```kotlin
// commonMain/kotlin/di/AppContainer.kt
class AppContainer(
    private val platformService: PlatformService
) {
    val api: UserApi = UserApi()
    val database: AppDatabase = createDatabase()

    val userRepository: UserRepository by lazy {
        UserRepositoryImpl(api, database)
    }

    val homeViewModel: HomeViewModel by lazy {
        HomeViewModel(userRepository, platformService)
    }
}
```

## Testing with DI

```kotlin
// commonTest/kotlin/di/TestModule.kt
val testModule = module {
    single<MockUserService> { MockUserService() }
    // Modules loaded later override earlier definitions by default; the old
    // per-definition `override = true` param no longer exists. To forbid
    // overrides, enable strict mode with allowOverride(false) in startKoin.
    single<UserService> { get<MockUserService>() }
}

// In tests
@BeforeTest
fun setup() {
    startKoin { modules(testModule) }
}

@AfterTest
fun tearDown() {
    stopKoin()
}
```
