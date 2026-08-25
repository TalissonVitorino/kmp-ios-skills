---
name: shared-coroutines
description: Coroutines and Flow in Kotlin Multiplatform shared code - expect/actual dispatchers, iOS main-thread/Darwin constraints, a CoroutineScope shared from commonMain, and exposing StateFlow/Flow to Swift (KMP-NativeCoroutines/SKIE). Use for commonMain/iosMain concurrency. For general, non-multiplatform coroutine and Flow patterns use coroutines-patterns. For source-backed Flow/StateFlow/SharedFlow/Channel depth see android-skills:kotlin-flows and android-skills:kotlin-coroutines.
---

# Shared Coroutines for KMP

Configure coroutines for cross-platform async operations with platform-appropriate dispatchers.

## Dependencies

```kotlin
// build.gradle.kts
sourceSets {
    val commonMain by getting {
        dependencies {
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
        }
    }
    val commonTest by getting {
        dependencies {
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
        }
    }
    val androidMain by getting {
        dependencies {
            // Runtime artifact that provides the Android Dispatchers.Main implementation.
            // Without it, touching Dispatchers.Main throws IllegalStateException.
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
        }
    }
}
```

## Platform Dispatchers

Do NOT hand-roll GCD-backed dispatchers or expect/actual dispatcher objects — the built-ins cover Android and iOS:

- `Dispatchers.Default` and `Dispatchers.Main` are declared in the library's **commonMain**. On Darwin, `Default` is GCD's global concurrent queue and `Main` is `dispatch_get_main_queue()`; `Main.immediate` is supported there too. On Android, `Main` comes from the `kotlinx-coroutines-android` runtime artifact.
- `Dispatchers.IO` is declared in the library's **`concurrent`** source set (JVM + Native only) — there is no JS/Wasm implementation. It therefore resolves from *your* commonMain only while every target is JVM/Android/Native. Add a `js`/`wasmJs` target and commonMain stops seeing it; that is the one case where an expect/actual IO dispatcher is still required.
- On Native, `Dispatchers.IO` is a 2048-thread pool exposed at parallelism 64. As on JVM, `Dispatchers.IO.limitedParallelism(n)` views are *elastic*: they are not capped by IO's own 64, they just share its threads.

Keep a small abstraction anyway so tests can inject a `TestDispatcher`:

```kotlin
// commonMain/kotlin/coroutines/PlatformDispatcher.kt
interface PlatformDispatcher {
    val main: CoroutineDispatcher
    val io: CoroutineDispatcher
    val default: CoroutineDispatcher
}

object PlatformDispatchers : PlatformDispatcher {
    override val main: CoroutineDispatcher get() = Dispatchers.Main
    override val io: CoroutineDispatcher get() = Dispatchers.IO
    override val default: CoroutineDispatcher get() = Dispatchers.Default
}
```

expect/actual is only warranted for a genuinely platform-specific dispatcher (e.g. a specific GCD QoS queue on iOS, or an IO dispatcher when the project has a JS/Wasm target). If you do write one, remember interface members in the `actual object` are `override val`, not `actual val` — only members declared in the `expect` take the `actual` modifier. For serialized access, prefer `Dispatchers.Default.limitedParallelism(1)` in commonMain over a custom serial-queue dispatcher — but note it only serializes execution, it does not confine work to one thread, so never rely on thread affinity or thread-locals behind it.

## Common Scopes

`CoroutineScope` should not be implemented by hand — the KDoc recommends the `CoroutineScope(...)` factory plus `by`-delegation, which also avoids rebuilding the context on every access.

```kotlin
// commonMain/kotlin/coroutines/Scopes.kt
// Application scope - lives for app lifetime.
class ApplicationScope : CoroutineScope by CoroutineScope(
    SupervisorJob() + PlatformDispatchers.main +
        CoroutineExceptionHandler { _, throwable -> logger.e(throwable) { "Unhandled" } }
) {
    fun close() = cancel()   // CoroutineScope.cancel() cancels the SupervisorJob
}

// View scope - tied to a view/presenter lifecycle.
class ViewScope : CoroutineScope by CoroutineScope(SupervisorJob() + PlatformDispatchers.main) {
    fun close() = cancel()
}
```

A cancelled scope is dead: create a new one per lifecycle instead of reusing it. When the scope itself must survive, cancel only its children — `coroutineContext.cancelChildren()` (`cancelChildren` is declared on `Job` and `CoroutineContext`; there is no `CoroutineScope.cancelChildren()`). For logging from commonMain use Kermit rather than `println` — see the `kmp-logging` skill.

## Flow Sharing Patterns

### StateFlow for UI State

```kotlin
// Use the real kotlinx-coroutines operators — don't re-declare them.

// Cold Flow -> hot StateFlow for UI state:
val uiState: StateFlow<UiState> = repository.observe()
    .map { UiState.Loaded(it) }
    .stateIn(scope, SharingStarted.WhileSubscribed(5_000), UiState.Loading)

// Share one upstream among many collectors:
val events: SharedFlow<Event> =
    source.shareIn(scope, SharingStarted.WhileSubscribed(5_000), replay = 0)
```

### Connect to Platform Lifecycle

There is NO common `Lifecycle` in commonMain. Make collection lifecycle-aware per platform instead:

- androidMain: `lifecycleScope.launch { repeatOnLifecycle(STARTED) { flow.collect { ... } } }` (or `collectAsStateWithLifecycle()` in Compose)
- iOS (SwiftUI): `.task { for await v in flow { ... } }` — SKIE exposes `Flow` as `AsyncSequence`, and `.task` cancels collection when the view disappears

Pair this with `SharingStarted.WhileSubscribed(5_000)` on the shared `StateFlow` so upstream work stops when no platform view is collecting.

### Exposing Flows to Swift

Default Kotlin/Native interop is poor: `suspend` functions become completion-handler methods with no cancellation bridging, and `Flow` surfaces as a non-generic protocol (`Flow` erased to `Any?`). The old "suspend functions must be called from the main thread" restriction was lifted in Kotlin 2.0.20 — if `kotlin.native.binary.objcExportSuspendFunctionLaunchThreadRestriction=none` is still in `gradle.properties`, delete it. Use one of:

- **SKIE** (`co.touchlab.skie` Gradle plugin, 0.10.x, tracks Kotlin 2.0–2.4) — zero annotations; `suspend` becomes Swift `async` (cancellation bridged), `Flow<T>` becomes a typed `AsyncSequence`, sealed classes become Swift enums for `switch`.
- **KMP-NativeCoroutines** (Gradle plugin `com.rickclephas.kmp.nativecoroutines`, 1.0.x) — annotate with `@NativeCoroutines`/`@NativeCoroutinesState`; consume from Swift via the `KMPNativeCoroutinesAsync` (async/await), Combine, or RxSwift packages.

Pick one, not both. For a `StateFlow`, expose `value` for the initial state plus the flow for updates (SKIE and `@NativeCoroutinesState` both handle this).

Do not put `kotlin.Result` on a public API that iOS consumes: value/inline classes are unsupported in Objective-C export and are mapped to their underlying type or `id`, so Swift loses the success/failure distinction. Keep `Result` internal to shared code and expose a sealed class (SKIE turns it into a Swift enum) at the boundary — see the `error-handling-result` skill.

## Repository Layer Coroutines

```kotlin
// commonMain/kotlin/data/repository/BaseRepository.kt
// Inject PlatformDispatcher instead of touching PlatformDispatchers directly,
// so commonTest can swap in a TestDispatcher.
abstract class BaseRepository(
    protected val dispatchers: PlatformDispatcher
) {

    protected suspend fun <T> execute(
        dispatcher: CoroutineDispatcher = dispatchers.io,
        block: suspend () -> T
    ): Result<T> = withContext(dispatcher) {
        try {
            Result.success(block())
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    // Single-shot: emits exactly one Result, then completes. To actually observe
    // changes, return the source Flow (e.g. SQLDelight's asFlow()) and map it instead.
    protected fun <T> resultFlow(
        dispatcher: CoroutineDispatcher = dispatchers.io,
        block: suspend () -> T
    ): Flow<Result<T>> = flow {
        emit(withContext(dispatcher) {
            try {
                Result.success(block())
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Result.failure(e)
            }
        })
    }

    // For single-shot database operations
    protected suspend fun <T> databaseQuery(
        block: suspend () -> T
    ): T = withContext(dispatchers.io) {
        block()
    }

    // For network operations with timeout. Ktor already applies its own request
    // timeouts — use this only for an end-to-end budget across several calls.
    protected suspend fun <T> networkCall(
        timeout: Duration = 30.seconds,
        block: suspend () -> T
    ): T = withTimeout(timeout) {
        withContext(dispatchers.io) {
            block()
        }
    }
}

// Usage
class UserRepository(
    private val remoteDataSource: UserRemoteDataSource,
    private val localDataSource: UserLocalDataSource,
    dispatchers: PlatformDispatcher = PlatformDispatchers
) : BaseRepository(dispatchers) {

    suspend fun getUser(id: String): Result<User> = execute {
        remoteDataSource.getUser(id).also { user ->
            localDataSource.saveUser(user)
        }
    }

    suspend fun getAllUsers(): Result<List<User>> = execute { remoteDataSource.getUsers() }

    fun loadUser(id: String): Flow<Result<User>> = resultFlow {
        localDataSource.getUser(id) ?: remoteDataSource.getUser(id).also {
            localDataSource.saveUser(it)
        }
    }
}
```

## Use Case Patterns

```kotlin
// commonMain/kotlin/domain/base/BaseUseCase.kt
abstract class BaseUseCase<in P, R> {
    suspend operator fun invoke(parameters: P): Result<R> =
        try {
            Result.success(execute(parameters))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }

    protected abstract suspend fun execute(parameters: P): R
}

// No parameters: use BaseUseCase<Unit, R> plus this convenience overload.
suspend operator fun <R> BaseUseCase<Unit, R>.invoke(): Result<R> = invoke(Unit)

// Flow use case
abstract class FlowUseCase<in P, R> {
    operator fun invoke(parameters: P): Flow<Result<R>> = flow {
        try {
            emit(Result.success(execute(parameters)))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            emit(Result.failure(e))
        }
    }

    protected abstract suspend fun execute(parameters: P): R
}

// Usage
class GetUsersUseCase(
    private val repository: UserRepository
) : BaseUseCase<Unit, List<User>>() {
    // repository.getAllUsers returns Result<List<User>>; unwrap so BaseUseCase re-wraps it.
    override suspend fun execute(parameters: Unit): List<User> =
        repository.getAllUsers().getOrThrow()
}

class ObserveUserUseCase(
    private val repository: UserRepository
) : FlowUseCase<String, User>() {
    // repository.getUser returns Result<User>; unwrap so FlowUseCase re-wraps it.
    override suspend fun execute(parameters: String): User =
        repository.getUser(parameters).getOrThrow()
}
```

## Worker for Background Tasks

The `workers` map is a plain `MutableMap`: under the Kotlin/Native memory model it is shared but not thread-safe, so call `start`/`stop`/`stopAll` from one dispatcher (typically `main`), or guard it with a `Mutex`.

```kotlin
// commonMain/kotlin/coroutines/BackgroundWorker.kt
class BackgroundWorker(
    private val scope: CoroutineScope
) {
    private val workers = mutableMapOf<String, Job>()

    fun start(
        key: String,
        interval: Duration,
        dispatcher: CoroutineDispatcher = PlatformDispatchers.io,
        work: suspend () -> Unit
    ) {
        workers[key]?.cancel()
        workers[key] = scope.launch(dispatcher) {
            while (isActive) {
                try {
                    work()
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    logger.e(e) { "Worker $key failed" }
                }
                delay(interval)
            }
        }
    }

    fun stop(key: String) {
        workers[key]?.cancel()
        workers.remove(key)
    }

    fun stopAll() {
        workers.values.forEach { it.cancel() }
        workers.clear()
    }
}
```

## Testing Helpers

```kotlin
// commonTest/kotlin/coroutines/TestPlatformDispatcher.kt
class TestPlatformDispatcher(dispatcher: CoroutineDispatcher) : PlatformDispatcher {
    override val main: CoroutineDispatcher = dispatcher
    override val io: CoroutineDispatcher = dispatcher
    override val default: CoroutineDispatcher = dispatcher
}

// The code under test must take a PlatformDispatcher constructor parameter —
// that's the whole point of the abstraction. Build the test dispatcher from
// runTest's own scheduler so virtual time stays in sync:
class UserRepositoryTest {
    @Test
    fun fetchesUserFromRemote() = runTest {
        // Note: backticked test names with spaces don't compile on Kotlin/Native
        // targets — use camelCase in commonTest.
        val dispatchers = TestPlatformDispatcher(StandardTestDispatcher(testScheduler))
        val repository = UserRepository(fakeRemote, fakeLocal, dispatchers)

        val result = repository.getUser("123")

        assertTrue(result.isSuccess)
    }
}
```

If some code path still touches `Dispatchers.Main` directly, replace it with `Dispatchers.setMain(StandardTestDispatcher())` in setup and `Dispatchers.resetMain()` in teardown — `setMain` is supported on Kotlin/Native, and the real Darwin `Dispatchers.Main` never runs in a Native test binary because the test blocks the main queue.

## Best practices

**Do:** inject `PlatformDispatcher` rather than referencing dispatchers statically · scope coroutines to a lifecycle and cancel it · re-throw `CancellationException` if you catch it (`catch (e: Exception)` swallows it otherwise) · expose state as `StateFlow` with `WhileSubscribed(5_000)` · name coroutines (`CoroutineName(...)`) for debugging.

**Don't:** use `GlobalScope` · `runBlocking` in production (on iOS it blocks the main queue) · reuse a cancelled scope · expose `kotlin.Result` or bare `Flow` across the Objective-C boundary without SKIE/KMP-NativeCoroutines.
