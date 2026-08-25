---
name: koin-patterns
description: Koin DI fundamentals and DSL reference - module {}, single/factory/scoped declarations, the *Of constructor DSL, scopes, named qualifiers, parameters, and get()/inject() resolution. General Koin concepts, not a platform-specific setup. For Kotlin Multiplatform shared DI use kmp-di; for structuring an Android app's modules per layer use android-di-koin.
---

# Koin Dependency Injection

Pragmatic DI for Kotlin with Koin. Current stable: BOM `io.insert-koin:koin-bom:4.2.2` —
pull `koin-core`, `koin-android`, `koin-androidx-compose`, `koin-compose` +
`koin-compose-viewmodel` (KMP), `koin-test` / `koin-test-junit4` without versions from it.

## Module Setup

```kotlin
// AppModule.kt
val appModule = module {
    // Singletons
    single<AppDatabase> { Room.databaseBuilder(...).build() }
    single { get<AppDatabase>().userDao() }
    
    // Factories (new instance each time)
    factory { DateFormatter() }
}

// NetworkModule.kt
val networkModule = module {
    single<HttpClient> {
        HttpClient(OkHttp) {
            install(ContentNegotiation) {
                json(Json { ignoreUnknownKeys = true })
            }
        }
    }
    
    single<AuthApi> { AuthApiImpl(get()) }
    single<UserApi> { UserApiImpl(get()) }
}

// FeatureModule.kt
val homeModule = module {
    // Repository
    single<HomeRepository> { HomeRepositoryImpl(get(), get()) }
    
    // Use Cases
    factory { GetItemsUseCase(get()) }
    factory { GetItemUseCase(get()) }
    
    // ViewModel
    viewModel { HomeViewModel(get()) }
}
```

## Constructor DSL (*Of)

Constructor references instead of lambdas — Koin resolves each constructor parameter with `get()`:

```kotlin
val homeModule = module {
    singleOf(::HomeRepositoryImpl) bind HomeRepository::class
    factoryOf(::GetItemsUseCase)
    viewModelOf(::HomeViewModel)

    // Options lambda: qualifier, extra bindings, eager creation
    singleOf(::RemoteTracker) {
        named("remote")
        bind<Tracker>()
        createdAtStart()
    }
}
```

`bind<T>()` / `bind T::class` only add a **secondary type** — Koin does not check the
hierarchy, so the class must actually implement `T` or `get<T>()` throws
`ClassCastException` at resolution. Never bind to a final third-party class.

Since Koin 4.0 the ViewModel DSL is multiplatform: import `viewModel`/`viewModelOf` from `org.koin.core.module.dsl` (koin-core-viewmodel). The old `org.koin.androidx.viewmodel.dsl` imports are deprecated.

## Application Setup

```kotlin
class MyApp : Application() {
    override fun onCreate() {
        super.onCreate()
        
        startKoin {
            androidContext(this@MyApp)
            modules(appModule, networkModule, homeModule)
        }
    }
}
```

## ViewModel Injection

```kotlin
// In Compose
@Composable
fun HomeScreen(viewModel: HomeViewModel = koinViewModel()) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    // ...
}

// With parameters — pass a unique key, or the same instance is
// reused for different ids within the same ViewModelStoreOwner
@Composable
fun DetailScreen(itemId: String) {
    val viewModel: DetailViewModel = koinViewModel(key = itemId) { parametersOf(itemId) }
    // ...
}

// ViewModel definition with params
viewModel { params ->
    DetailViewModel(
        itemId = params.get(),
        repository = get()
    )
}
```

## Scopes

```kotlin
// Type-based scope: only MainActivity resolves it
val activityModule = module {
    scope<MainActivity> {
        scoped { NavigationController() }
    }
}

// Usage: AndroidScopeComponent creates/closes the scope with the lifecycle;
// by inject() then resolves from the activity's scope
class MainActivity : AppCompatActivity(), AndroidScopeComponent {
    override val scope: Scope by activityScope()
    
    val nav: NavigationController by inject()
}
```

Prefer **archetype scopes** (`org.koin.androidx.scope.dsl`) — reusable across any
Activity/Fragment instead of one concrete class:

```kotlin
val activityModule = module {
    activityScope { scoped { NavigationController() } }  // dies with the Activity
    activityRetainedScope { scoped { DraftForm() } }     // survives rotation
    fragmentScope { scoped { FragmentPresenter(get()) } }
}
```

`ScopeActivity` / `RetainedScopeActivity` / `ScopeFragment` implement `AndroidScopeComponent`
for you. Override `onCloseScope()` for cleanup — the scope is already closed in `onDestroy()`.

## Qualifiers

```kotlin
val networkModule = module {
    single<HttpClient>(named("auth")) { createAuthClient() }
    single<HttpClient>(named("default")) { createDefaultClient() }

    // Resolve by qualifier at the definition site
    single<UserApi> { UserApiImpl(client = get(named("auth"))) }
}

// In a KoinComponent
private val client: HttpClient by inject(named("auth"))
```

`@Named` on constructor parameters is Koin Annotations (KSP) / compiler-plugin territory — with the classic DSL, qualifiers are resolved via `get(named(...))`/`inject(named(...))`.

## Testing

```kotlin
class HomeViewModelTest : KoinTest {
    
    @get:Rule
    val koinRule = KoinTestRule.create {
        modules(testModule)
    }
    
    private val testModule = module {
        single<HomeRepository> { mockk() }
        viewModel { HomeViewModel(get()) }
    }
    
    private val viewModel: HomeViewModel by inject()
    private val repository: HomeRepository by inject()
    
    @Test
    fun `loads items`() = runTest {
        coEvery { repository.getItems() } returns Result.success(listOf())
        // ...
    }
}
```
