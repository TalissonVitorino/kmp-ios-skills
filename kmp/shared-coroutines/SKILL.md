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
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
            implementation("org.jetbrains.kotlinx:kotlinx-datetime:0.7.1")
            // datetime 0.7: Instant/Clock moved to kotlin.time; LocalDate/TimeZone stay in kotlinx.datetime.
        }
    }
    val androidMain by getting {
        dependencies {
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
        }
    }
}
```

## Platform Dispatchers

```kotlin
// commonMain/kotlin/coroutines/PlatformDispatcher.kt
interface PlatformDispatcher {
    val main: CoroutineDispatcher
    val io: CoroutineDispatcher
    val default: CoroutineDispatcher
    val unconfined: CoroutineDispatcher
}

expect object PlatformDispatchers : PlatformDispatcher
```

### Android Implementation

```kotlin
// androidMain/kotlin/coroutines/PlatformDispatcher.android.kt
actual object PlatformDispatchers : PlatformDispatcher {
    actual val main: CoroutineDispatcher = Dispatchers.Main
    actual val io: CoroutineDispatcher = Dispatchers.IO
    actual val default: CoroutineDispatcher = Dispatchers.Default
    actual val unconfined: CoroutineDispatcher = Dispatchers.Unconfined
}
```

### iOS Implementation

```kotlin
// iosMain/kotlin/coroutines/PlatformDispatcher.ios.kt
actual object PlatformDispatchers : PlatformDispatcher {
    // Dispatchers.Main is backed by the Darwin main queue out of the box in
    // modern kotlinx-coroutines — no hand-rolled main-queue dispatcher needed.
    actual val main: CoroutineDispatcher = Dispatchers.Main

    actual val io: CoroutineDispatcher =
        DispatchQueueDispatcher(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT.toLong(), 0))

    actual val default: CoroutineDispatcher =
        DispatchQueueDispatcher(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT.toLong(), 0))

    actual val unconfined: CoroutineDispatcher = Dispatchers.Unconfined
}

class DispatchQueueDispatcher(
    private val queue: dispatch_queue_t
) : CoroutineDispatcher() {
    override fun dispatch(context: CoroutineContext, block: Runnable) {
        dispatch_async(queue) { block.run() }
    }
}
```

## Common Scopes

```kotlin
// commonMain/kotlin/coroutines/Scopes.kt
// Application scope - lives for app lifetime
class ApplicationScope : CoroutineScope {
    private val job = SupervisorJob()

    override val coroutineContext: CoroutineContext
        get() = job + PlatformDispatchers.main +
        CoroutineExceptionHandler { _, throwable ->
            println("Unhandled exception: $throwable")
        }

    fun cancel() {
        job.cancel()
    }
}

// View scope - tied to a view/presenter lifecycle
class ViewScope : CoroutineScope {
    private val job = SupervisorJob()

    override val coroutineContext: CoroutineContext
        get() = job + PlatformDispatchers.main

    fun cancel() {
        job.cancelChildren()
        job.cancel()
    }
}

// Use case scope - for single operations
fun useCaseScope(): CoroutineScope =
    CoroutineScope(
        SupervisorJob() +
        PlatformDispatchers.io +
        CoroutineExceptionHandler { _, throwable ->
            println("Use case failed: $throwable")
        }
    )
```

## Flow Sharing Patterns

### StateFlow for UI State

```kotlin
// Use the real stdlib operators — don't re-declare them.

// Cold Flow -> hot StateFlow for UI state:
val uiState: StateFlow<UiState> = repository.observe()
    .map { UiState.Loaded(it) }
    .stateIn(scope, SharingStarted.WhileSubscribed(5_000), UiState.Loading)

// Share one upstream among many collectors:
val events: SharedFlow<Event> =
    source.shareIn(scope, SharingStarted.WhileSubscribed(5_000), replay = 0)
```

### Connect to Platform Lifecycle

```kotlin
// commonMain/kotlin/coroutines/LifecycleAwareFlow.kt
// There is NO common `Lifecycle` in commonMain. Make collection
// lifecycle-aware per platform instead:
//   androidMain:   lifecycleScope.launch { repeatOnLifecycle(STARTED) { flow.collect { ... } } }
//   iOS (SwiftUI): .task { for await v in flow { ... } }   // SKIE exposes Flow as AsyncSequence

// Simple repeat on view active
fun <T> Flow<T>.repeatOnViewActive(
    isActive: () -> Boolean,
    minInterval: Duration = 1.seconds
): Flow<T> = channelFlow {
    var lastValue: T? = null
    val collectorJob = launch {
        collect { value ->
            lastValue = value
            if (isActive()) {
                send(value)
            }
        }
    }

    while (isActive()) {
        lastValue?.let { send(it) }
        delay(minInterval)
    }

    collectorJob.cancel()
}
```

## Repository Layer Coroutines

```kotlin
// commonMain/kotlin/data/repository/BaseRepository.kt
abstract class BaseRepository {

    protected suspend fun <T> execute(
        dispatcher: CoroutineDispatcher = PlatformDispatchers.io,
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

    protected suspend fun <T> flowFrom(
        dispatcher: CoroutineDispatcher = PlatformDispatchers.io,
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
    ): T = withContext(PlatformDispatchers.io) {
        block()
    }

    // For network operations with timeout
    protected suspend fun <T> networkCall(
        timeout: Duration = 30.seconds,
        block: suspend () -> T
    ): T = withTimeout(timeout) {
        withContext(PlatformDispatchers.io) {
            block()
        }
    }
}

// Usage
class UserRepository(
    private val localDataSource: UserLocalDataSource,
    private val remoteDataSource: UserRemoteDataSource
) : BaseRepository() {

    suspend fun getUser(id: String): Result<User> = execute {
        remoteDataSource.getUser(id).also { user ->
            localDataSource.saveUser(user)
        }
    }

    fun observeUser(id: String): Flow<Result<User>> = flowFrom {
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
    suspend operator fun invoke(parameters: P): Result<R> {
        return try {
            execute(parameters).let { Result.success(it) }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    protected abstract suspend fun execute(parameters: P): R
}

// No parameters
abstract class BaseNoParamsUseCase<R> {
    suspend operator fun invoke(): Result<R> {
        return try {
            execute().let { Result.success(it) }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    protected abstract suspend fun execute(): R
}

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
) : BaseNoParamsUseCase<List<User>>() {
    override suspend fun execute(): List<User> {
        return repository.getAllUsers()
    }
}

class ObserveUserUseCase(
    private val repository: UserRepository
) : FlowUseCase<String, User>() {
    override suspend fun execute(parameters: String): User {
        return repository.getUser(parameters)
    }

    fun flow(id: String): Flow<Result<User>> {
        return repository.observeUser(id)
    }
}
```

## Worker for Background Tasks

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
                } catch (e: Exception) {
                    println("Worker $key failed: $e")
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
// commonTest/kotlin/coroutines/TestDispatcher.kt
class TestPlatformDispatcher : PlatformDispatcher {
    private val testDispatcher = StandardTestDispatcher()

    override val main: CoroutineDispatcher = testDispatcher
    override val io: CoroutineDispatcher = testDispatcher
    override val default: CoroutineDispatcher = testDispatcher
    override val unconfined: CoroutineDispatcher = testDispatcher

    fun advanceUntilIdle() {
        testDispatcher.scheduler.advanceUntilIdle()
    }
}

// Usage in tests
class UserRepositoryTest {
    private lateinit var testDispatcher: TestPlatformDispatcher

    @BeforeTest
    fun setup() {
        testDispatcher = TestPlatformDispatcher()
    }

    @Test
    fun `fetches user from remote`() = runTest {
        val repository = UserRepository(mockRemote, mockLocal)
        val result = repository.getUser("123")

        testDispatcher.advanceUntilIdle()

        assertTrue(result.isSuccess)
    }
}
```

## Best practices

**Do:** reach dispatchers through an abstraction (`PlatformDispatchers.io`) · scope coroutines to a lifecycle · re-throw `CancellationException` if you catch it · expose state as `StateFlow` · name coroutines (`CoroutineName(...)`) for debugging.

**Don't:** use `GlobalScope` · `runBlocking` in production · launch work that throws unhandled · hardcode `Dispatchers.Main` (use the KMP-safe `PlatformDispatchers.main`).
