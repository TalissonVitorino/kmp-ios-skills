---
name: kmp-di
description: Dependency injection for Kotlin Multiplatform (KMP/CMP) - shared Koin modules in commonMain, expect/actual platform modules, initKoin()/KoinApplication startup shared across Android and iOS, and consuming the Koin graph from Swift/iOS. Use for multiplatform or shared DI wiring. For an Android-only app use android-di-koin; for Koin DSL and scope fundamentals use koin-patterns.
---

# KMP Dependency Injection

Cross-platform dependency injection with Koin.

## Koin Multiplatform Setup

### Dependencies

```kotlin
// build.gradle.kts (shared module)
sourceSets {
    val commonMain by getting {
        dependencies {
            implementation("io.insert-koin:koin-core:${koinVersion}")
            implementation("io.insert-koin:koin-test:${koinVersion}")
        }
    }
    val androidMain by getting {
        dependencies {
            implementation("io.insert-koin:koin-android:${koinVersion}")
        }
    }
}
```

### Module Definition

```kotlin
// commonMain/kotlin/di/AppModule.kt
val sharedModule = module {
    // ViewModels (Android) / ScreenModels (multiplatform)
    factory { HomeViewModel(get(), get()) }
    factory { DetailViewModel(get()) }

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

// Koin objects aren't directly resolvable from Swift — expose a helper that
// resolves for you, so Swift can pull dependencies out of the graph:
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
// commonMain/kotlin/Main.kt
fun main() {
    startKoin {
        modules(sharedModule)
    }

    App()
}
```

## ViewModel Injection

### Android (ViewModel)

```kotlin
// androidMain/kotlin/ui/HomeScreen.kt
@Composable
fun HomeScreen(
    viewModel: HomeViewModel = koinViewModel()
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    HomeContent(state)
}
```

### iOS (ScreenModel)

```kotlin
// commonMain/kotlin/ui/HomeScreen.kt
@Composable
fun HomeScreen() {
    // Generic Compose Multiplatform: koinInject() from koin-compose.
    // getScreenModel<T>() is a Voyager API — only if you use voyager-koin.
    val model: HomeScreenModel = koinInject()
    val state by model.state.collectAsState()

    HomeContent(state)
}
```

## Repository Pattern

### Factory vs Single

```kotlin
// ✅ factory - creates new instance each time
factory { HomeViewModel(get(), get()) }

// ✅ single - shared instance
single<UserRepository> { UserRepositoryImpl(get(), get()) }

// ✅ scoped - tied to component lifetime
scoped(HomeScope.homeScope) { HomeData(get()) }
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
    // Modules loaded later override earlier definitions by default;
    // the per-definition `override = true` param was deprecated in Koin 3.2+.
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
