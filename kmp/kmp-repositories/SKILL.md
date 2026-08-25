---
name: kmp-repositories
description: Repository pattern for Kotlin Multiplatform. Shared interfaces with platform-specific implementations, clean data layer architecture.
---

# KMP Repository Pattern

Implement the repository pattern with shared interfaces in `commonMain` and platform-specific implementations.

## Architecture Overview

```
Presentation   ViewModels · Composables · SwiftUI
     ↓
Domain         use cases
     ↓
Data           Repository interface        (commonMain)
               Repository implementation   (commonMain: coordinates sources,
                                            caching strategy, error mapping)
               Data sources                Remote (network) · Local (database)
                                           · Memory (cache)
```

## Repository Interface

```kotlin
// commonMain/kotlin/data/repository/UserRepository.kt
interface UserRepository {
    // Single shot
    suspend fun getUser(id: String): Result<User>
    suspend fun getUsers(page: Int): Result<PaginatedResponse<User>>
    suspend fun saveUser(user: User): Result<User>
    suspend fun deleteUser(id: String): Result<Unit>

    // Streams
    fun observeUser(id: String): Flow<Result<User>>
    fun observeUsers(): Flow<Result<List<User>>>

    // Cache control
    suspend fun refreshUser(id: String): Result<User>
    suspend fun refreshAll(): Result<Unit>
    suspend fun clearCache(): Result<Unit>
}
```

`kotlin.Result` is an inline value class, and the Kotlin/Native Objective-C export maps
inline classes to their underlying type or `id` — Swift cannot unwrap one. Keep `Result`
inside shared code and convert at the iOS boundary (sealed wrapper, or a shared ViewModel
exposing state): see `error-handling-result` and `kmp-ios-integration`.

## Base Repository

```kotlin
// commonMain/kotlin/data/repository/BaseRepository.kt
abstract class BaseRepository {
    // Execute with error handling.
    // NetworkException/DataException are app-defined error types.
    protected suspend fun <T> execute(
        block: suspend () -> T
    ): Result<T> = try {
        Result.success(block())
    } catch (e: CancellationException) {
        throw e
    } catch (e: NetworkException) {
        Result.failure(e)
    } catch (e: Exception) {
        Result.failure(DataException(cause = e))
    }

    // Wrap a Flow's emissions in Result. Use the .catch operator — a
    // try/catch around collect inside a flow {} builder violates flow
    // exception transparency and can throw IllegalStateException at runtime.
    protected fun <T> flowResult(
        block: () -> Flow<T>
    ): Flow<Result<T>> = block()
        .map { Result.success(it) }
        .catch { e -> emit(Result.failure(e)) }

    // Cache-first strategy: return cache hit, otherwise fetch and persist
    protected suspend fun <T> cacheFirst(
        cacheBlock: suspend () -> T?,
        networkBlock: suspend () -> T,
        saveBlock: suspend (T) -> Unit
    ): Result<T> = execute {
        cacheBlock() ?: networkBlock().also { saveBlock(it) }
    }

    // Network-first strategy: fall back to cache only on network errors
    protected suspend fun <T> networkFirst(
        cacheBlock: suspend () -> T?,
        networkBlock: suspend () -> T
    ): Result<T> = execute {
        try {
            networkBlock()
        } catch (e: NetworkException) {
            cacheBlock() ?: throw e
        }
    }

    // Refresh strategy
    protected suspend fun <T> refresh(
        networkBlock: suspend () -> T,
        cacheBlock: suspend (T) -> Unit
    ): Result<T> = execute {
        val result = networkBlock()
        cacheBlock(result)
        result
    }
}
```

## Concrete Repository

```kotlin
// commonMain/kotlin/data/repository/UserRepositoryImpl.kt
// Main-safety belongs in the data sources (see UserLocalDataSourceImpl below),
// not here — the repository just coordinates them.
// MemoryCache is app-defined: get<T>(key) / put / remove / clear.
class UserRepositoryImpl(
    private val remoteDataSource: UserRemoteDataSource,
    private val localDataSource: UserLocalDataSource,
    private val memoryCache: MemoryCache
) : BaseRepository(), UserRepository {

    override suspend fun getUser(id: String): Result<User> =
        networkFirst(
            // read the memory tier too — otherwise the puts below are dead writes
            cacheBlock = { memoryCache.get<User>("user:$id") ?: localDataSource.getUser(id) },
            networkBlock = { remoteDataSource.getUser(id).also { user ->
                localDataSource.saveUser(user)
                memoryCache.put("user:$id", user)
            }}
        )

    override suspend fun getUsers(page: Int): Result<PaginatedResponse<User>> =
        execute {
            remoteDataSource.getUsers(page).also { response ->
                localDataSource.saveUsers(response.items)
            }
        }

    override suspend fun saveUser(user: User): Result<User> =
        execute {
            remoteDataSource.createUser(user).also { savedUser ->
                localDataSource.saveUser(savedUser)
                memoryCache.put("user:${savedUser.id}", savedUser)
            }
        }

    override suspend fun deleteUser(id: String): Result<Unit> =
        execute {
            remoteDataSource.deleteUser(id).also {
                localDataSource.deleteUser(id)
                memoryCache.remove("user:$id")
            }
        }

    override fun observeUser(id: String): Flow<Result<User>> =
        flowResult {
            localDataSource.observeUser(id)
        }

    override fun observeUsers(): Flow<Result<List<User>>> =
        flowResult {
            localDataSource.observeAllUsers()
        }

    override suspend fun refreshUser(id: String): Result<User> =
        refresh(
            networkBlock = { remoteDataSource.getUser(id) },
            cacheBlock = { user -> localDataSource.saveUser(user) }
        )

    override suspend fun refreshAll(): Result<Unit> =
        execute {
            remoteDataSource.getUsers(page = 1).items.forEach { user ->
                localDataSource.saveUser(user)
            }
        }

    override suspend fun clearCache(): Result<Unit> =
        execute {
            localDataSource.clearAll()
            memoryCache.clear()
        }
}
```

## Data Sources

### Remote Data Source

```kotlin
// commonMain/kotlin/data/datasource/remote/UserRemoteDataSource.kt
interface UserRemoteDataSource {
    suspend fun getUser(id: String): User
    suspend fun getUsers(page: Int): PaginatedResponse<User>
    suspend fun createUser(user: User): User
    suspend fun updateUser(id: String, user: User): User
    suspend fun deleteUser(id: String)
}

class UserRemoteDataSourceImpl(
    private val api: UserApi
) : UserRemoteDataSource {
    override suspend fun getUser(id: String): User = api.getUser(id)
    override suspend fun getUsers(page: Int): PaginatedResponse<User> = api.getUsers(page)
    override suspend fun createUser(user: User): User = api.createUser(user)
    override suspend fun updateUser(id: String, user: User): User = api.updateUser(id, user)
    override suspend fun deleteUser(id: String) = api.deleteUser(id)
}
```

### Local Data Source

```kotlin
// commonMain/kotlin/data/datasource/local/UserLocalDataSource.kt
interface UserLocalDataSource {
    suspend fun getUser(id: String): User?
    suspend fun getAllUsers(): List<User>
    suspend fun saveUser(user: User)
    suspend fun saveUsers(users: List<User>)
    suspend fun deleteUser(id: String)
    suspend fun clearAll()
    fun observeUser(id: String): Flow<User>
    fun observeAllUsers(): Flow<List<User>>
}

// SQLDelight 2.x (current 2.3.2). asFlow/mapToList/mapToOneOrNull come from
// app.cash.sqldelight:coroutines-extensions — 2.x requires the explicit
// CoroutineContext argument. Dispatchers.IO exists on JVM/Native only (coroutines
// `concurrent` source set, since 1.7), so it resolves from commonMain in an
// Android+iOS project but vanishes if you add a js/wasmJs target — inject the
// dispatcher (as below) instead of hardcoding it at call sites.
class UserLocalDataSourceImpl(
    private val database: AppDatabase,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO
) : UserLocalDataSource {
    private val queries get() = database.userQueries  // generated property, not a function

    override suspend fun getUser(id: String): User? = withContext(dispatcher) {
        queries.getById(id).executeAsOneOrNull()?.toDomain()
    }

    override suspend fun getAllUsers(): List<User> = withContext(dispatcher) {
        queries.getAll().executeAsList().map { it.toDomain() }
    }

    override suspend fun saveUser(user: User) = withContext(dispatcher) {
        queries.insert(user.toEntity())
    }

    override suspend fun saveUsers(users: List<User>) = withContext(dispatcher) {
        // transaction {} takes a non-suspending lambda — call generated
        // query methods directly inside it, not suspend functions
        queries.transaction {
            users.forEach { queries.insert(it.toEntity()) }
        }
    }

    override suspend fun deleteUser(id: String) = withContext(dispatcher) {
        queries.deleteById(id)
    }

    override suspend fun clearAll() = withContext(dispatcher) {
        queries.deleteAll()
    }

    override fun observeUser(id: String): Flow<User> =
        queries.getById(id).asFlow()
            .mapToOneOrNull(dispatcher)
            .filterNotNull()
            .map { it.toDomain() }

    override fun observeAllUsers(): Flow<List<User>> =
        queries.getAll().asFlow()
            .mapToList(dispatcher)
            .map { rows -> rows.map { it.toDomain() } }
}
```

## Use Cases

```kotlin
// commonMain/kotlin/domain/usecase/GetUserUseCase.kt
class GetUserUseCase(
    private val repository: UserRepository
) {
    suspend operator fun invoke(id: String): Result<User> =
        repository.getUser(id)
}

// commonMain/kotlin/domain/usecase/ObserveUserUseCase.kt
class ObserveUserUseCase(
    private val repository: UserRepository
) {
    operator fun invoke(id: String): Flow<Result<User>> =
        repository.observeUser(id)
}

// commonMain/kotlin/domain/usecase/RefreshUserDataUseCase.kt
class RefreshUserDataUseCase(
    private val repository: UserRepository
) {
    suspend operator fun invoke(id: String): Result<User> =
        repository.refreshUser(id)
}
```

## Dependency Injection

```kotlin
// commonMain/kotlin/di/DataModule.kt
val dataModule = module {
    // Data sources
    single { UserApi(get()) }
    single<UserRemoteDataSource> { UserRemoteDataSourceImpl(get()) }

    // Local data source (DriverFactory comes from a platform module — see kmp-di)
    single { createDatabase(get()) }
    single<UserLocalDataSource> { UserLocalDataSourceImpl(get()) }

    // Memory cache
    single { MemoryCache() }

    // Repositories
    single<UserRepository> { UserRepositoryImpl(get(), get(), get()) }

    // Use cases
    factory { GetUserUseCase(get()) }
    factory { ObserveUserUseCase(get()) }
    factory { RefreshUserDataUseCase(get()) }
}
```

## Platform-Specific Database Driver

SQLDelight shares the generated `AppDatabase` in `commonMain`; only the driver is per-platform:

```kotlin
// commonMain/kotlin/database/DriverFactory.kt
expect class DriverFactory {
    fun createDriver(): SqlDriver
}

fun createDatabase(driverFactory: DriverFactory): AppDatabase =
    AppDatabase(driverFactory.createDriver())

// androidMain — app.cash.sqldelight:android-driver
actual class DriverFactory(private val context: Context) {
    actual fun createDriver(): SqlDriver =
        AndroidSqliteDriver(AppDatabase.Schema, context, "app.db")
}

// iosMain — app.cash.sqldelight:native-driver
actual class DriverFactory {
    actual fun createDriver(): SqlDriver =
        NativeSqliteDriver(AppDatabase.Schema, "app.db")
}
```

Room (KMP-capable since 2.7.0; current 2.8.3) is the alternative. Deeper coverage: `sqldelight-patterns`, `room-patterns`.

## Repository Testing

MockK is JVM-only — it cannot be used in `commonTest` when the tests also run on iOS/native targets. Use hand-written fakes. Also use camelCase test names: backticked names with spaces don't compile on Kotlin/Native.

```kotlin
// commonTest/kotlin/data/repository/UserRepositoryTest.kt
class FakeUserRemoteDataSource : UserRemoteDataSource {
    var user: User? = null
    var shouldFail = false
    override suspend fun getUser(id: String): User {
        if (shouldFail) throw NetworkException()
        return requireNotNull(user)
    }
    // remaining members omitted
}

class FakeUserLocalDataSource : UserLocalDataSource {
    private val users = MutableStateFlow<Map<String, User>>(emptyMap())
    override suspend fun getUser(id: String) = users.value[id]
    override suspend fun saveUser(user: User) {
        users.update { it + (user.id to user) }
    }
    override fun observeUser(id: String): Flow<User> =
        users.map { it[id] }.filterNotNull().distinctUntilChanged()
    // remaining members omitted
}

class UserRepositoryTest {
    private val remote = FakeUserRemoteDataSource()
    private val local = FakeUserLocalDataSource()
    private val repository = UserRepositoryImpl(remote, local, MemoryCache())

    @Test
    fun fetchesFromNetworkAndWritesThroughToCache() = runTest {
        val user = User(id = "123", name = "John")
        remote.user = user

        val result = repository.getUser("123")

        assertEquals(user, result.getOrNull())
        assertEquals(user, local.getUser("123"))
    }

    @Test
    fun fallsBackToCacheWhenNetworkFails() = runTest {
        val cached = User(id = "123", name = "John")
        local.saveUser(cached)
        remote.shouldFail = true

        val result = repository.getUser("123")

        assertTrue(result.isSuccess)
        assertEquals(cached, result.getOrNull())
    }
}
```

## Best practices

**Do:** define interfaces in commonMain · return `Result` for errors · expose `Flow` for observable state · share common logic via a `BaseRepository` · keep implementations platform-agnostic.

**Don't:** expose platform types (return `User`, not `SQLiteDatabase`) · put business logic in repositories (belongs in use cases) · make repositories depend on each other (coordinate via use cases) · use global object state (use DI).
