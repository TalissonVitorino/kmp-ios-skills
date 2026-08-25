---
name: offline-first
description: Offline-first architecture patterns - NetworkBoundResource, sync strategies, conflict resolution, cache invalidation, and connectivity monitoring.
---

# Offline-First Architecture Patterns

## NetworkBoundResource Pattern

The core abstraction that coordinates cache and network data sources.

```kotlin
inline fun <ResultType, RequestType> networkBoundResource(
    crossinline query: () -> Flow<ResultType>,
    crossinline fetch: suspend () -> RequestType,
    crossinline saveFetchResult: suspend (RequestType) -> Unit,
    crossinline shouldFetch: (ResultType) -> Boolean = { true },
    crossinline onFetchFailed: (Throwable) -> Unit = { }
): Flow<Resource<ResultType>> = flow {
    val cachedData = query().first()

    val result = if (shouldFetch(cachedData)) {
        emit(Resource.Loading(cachedData))
        try {
            saveFetchResult(fetch())
            query().map { Resource.Success(it) }
        } catch (e: Exception) {
            if (e is CancellationException) throw e // never swallow cancellation
            onFetchFailed(e)
            // Surface the failure to the UI while still serving cached data
            query().map { Resource.Error(e.message ?: "Fetch failed", it) }
        }
    } else {
        query().map { Resource.Success(it) }
    }

    emitAll(result)
}
```

### Resource Wrapper

```kotlin
sealed class Resource<out T> {
    data class Success<T>(val data: T) : Resource<T>()
    data class Loading<T>(val data: T? = null) : Resource<T>()
    data class Error<T>(val message: String, val data: T? = null) : Resource<T>()
}
```

### Usage in Repository

```kotlin
class ArticleRepository(
    private val api: ArticleApi,
    private val dao: ArticleDao,
    private val cachePolicy: CachePolicy
) {
    fun getArticles(): Flow<Resource<List<Article>>> = networkBoundResource(
        query = { dao.observeAll() },
        fetch = { api.getArticles() },
        saveFetchResult = { articles ->
            // Room @Transaction DAO method (deleteAll + insertAll atomically);
            // in SQLDelight wrap in queries.transaction { }
            dao.replaceAll(articles.map { it.toEntity() })
            // Stamp freshness only after a successful write, or isExpired() stays true
            // forever and every collection refetches.
            cachePolicy.markFresh("articles")
        },
        shouldFetch = { cachedArticles ->
            cachedArticles.isEmpty() || cachePolicy.isExpired("articles")
        }
    )
}
```

## Cache-First vs Network-First Strategies

### Cache-First (Default for Offline-First)

```kotlin
fun getCacheFirst(): Flow<Resource<List<Item>>> = flow {
    val cached = dao.getAll().first()
    emit(Resource.Loading(cached.takeIf { it.isNotEmpty() }))
    var failure: Throwable? = null
    try {
        dao.replaceAll(api.fetchAll().map { it.toEntity() })
    } catch (e: Exception) {
        currentCoroutineContext().ensureActive()
        failure = e
    }
    // Keep serving the DB, but do NOT relabel stale rows as Success after a failed
    // refresh - the UI needs to know it is showing offline data.
    emitAll(dao.getAll().map { rows ->
        if (failure != null) Resource.Error(failure.message ?: "Network error", rows)
        else Resource.Success(rows)
    })
}
```

### Network-First (For Time-Sensitive Data)

```kotlin
fun getNetworkFirst(): Flow<Resource<List<Item>>> = flow {
    emit(Resource.Loading())
    // Never wrap emit()/emitAll() in the try: catching a downstream exception and then
    // emitting again throws "Flow exception transparency is violated" at runtime.
    // Do the fallible work first, emit after.
    val failure = try {
        dao.replaceAll(api.fetchAll().map { it.toEntity() })
        null
    } catch (e: Exception) {
        currentCoroutineContext().ensureActive()
        e
    }
    emitAll(dao.getAll().map { rows ->
        when {
            failure == null -> Resource.Success(rows)
            rows.isNotEmpty() -> Resource.Error(failure.message ?: "Stale data", rows)
            else -> Resource.Error(failure.message ?: "No data available")
        }
    })
}
```

The same rule applies to `networkBoundResource` above: the `try` there wraps only `fetch` and
`saveFetchResult`, and every branch builds a flow that is emitted once at the end.

## TTL-Based Cache Invalidation

```kotlin
import kotlin.time.Clock          // stdlib, stable since Kotlin 2.3 (no opt-in needed)
import kotlin.time.Duration
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.hours

class CachePolicy(
    private val settings: Settings,        // com.russhwolf:multiplatform-settings
    private val clock: Clock = Clock.System // inject a fake clock in tests
) {
    fun isExpired(key: String, ttl: Duration = DEFAULT_TTL): Boolean {
        val lastFetch = settings.getLong("cache_ts_$key", 0L)
        if (lastFetch == 0L) return true
        return clock.now().toEpochMilliseconds() - lastFetch > ttl.inWholeMilliseconds
    }

    fun markFresh(key: String) =
        settings.putLong("cache_ts_$key", clock.now().toEpochMilliseconds())

    fun invalidate(key: String) = settings.remove("cache_ts_$key")

    companion object {
        val DEFAULT_TTL = 15.minutes
        val SHORT_TTL = 2.minutes
        val LONG_TTL = 24.hours
    }
}
```

- `Clock`/`Instant` live in `kotlin.time` (stdlib) since Kotlin 2.1.20 and are stable as of 2.3. `kotlinx-datetime` 0.7.1 keeps `kotlinx.datetime.Clock`/`Instant` only as typealiases — new code should import from `kotlin.time`.
- Wall-clock TTLs go wrong when the user changes the device clock. Clamp: treat `lastFetch > now` as expired too, or store the server's `Date`/`ETag` and let the backend arbitrate freshness.
- Android-only projects can back this with `DataStore<Preferences>` instead of `Settings` (see `android-skills:datastore`); avoid `SharedPreferences` for new code.

## Connectivity Monitoring

### Android (ConnectivityManager)

Requires `<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />`.

```kotlin
class AndroidConnectivityMonitor(context: Context) : ConnectivityMonitor {

    private val cm = context.getSystemService(ConnectivityManager::class.java)

    override val isConnected: Flow<Boolean> = callbackFlow {
        val callback = object : ConnectivityManager.NetworkCallback() {
            // VALIDATED = the system probed and reached the internet.
            // NET_CAPABILITY_INTERNET alone is still true behind a captive portal.
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                trySend(caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED))
            }
            override fun onLost(network: Network) { trySend(false) }
            // onUnavailable() only fires for requestNetwork() (timed out, or the request
            // can never be fulfilled) - never for register*NetworkCallback, so not here
        }
        // registerDefaultNetworkCallback tracks the ONE network the system routes app
        // traffic over. registerNetworkCallback(request, ...) reports every matching
        // network, so a Wi-Fi -> cellular handover delivers onLost(wifi) and looks
        // offline while the device is still online.
        cm.registerDefaultNetworkCallback(callback)
        // No synchronous seed: reading getNetworkCapabilities(activeNetwork) here races
        // the callback. The system delivers onCapabilitiesChanged immediately if a
        // default network exists; start collectors from a false/unknown state.
        awaitClose { cm.unregisterNetworkCallback(callback) }
    }.distinctUntilChanged()
}
```

Connectivity state is a hint for UI and for scheduling, never a precondition. Always attempt the request and handle its failure — VALIDATED can be stale, and a reachable network says nothing about your backend being up.

### iOS (NWPathMonitor)

`NWPathMonitor` conforms to `AsyncSequence` (Element `NWPath`), so no `pathUpdateHandler` +
`DispatchQueue` bridging is needed. Iterating starts the monitor; cancelling the task stops it.

```swift
import Network
import Observation

@MainActor
@Observable
final class ConnectivityMonitor {
    private(set) var isConnected = true          // optimistic: never block the first request
    private(set) var isExpensive = false         // cellular / hotspot - defer bulk sync
    private(set) var isConstrained = false       // Low Data Mode

    func monitor() async {
        for await path in NWPathMonitor() {
            isConnected = path.status == .satisfied
            isExpensive = path.isExpensive
            isConstrained = path.isConstrained
        }
    }
}
```

Drive it from a view with `.task { await monitor.monitor() }` so the loop is cancelled on
disappear. `.satisfied` means a route exists, not that your server answers — treat it as a hint
and still handle request failures. Honour `isConstrained`/`isExpensive` by skipping non-essential
prefetch, and set `allowsConstrainedNetworkAccess = false` on those requests (`URLRequest`
per-request, or `URLSessionConfiguration` for a whole session).

## Sync Queue for Offline Writes

```kotlin
@Entity(tableName = "pending_operations")
data class PendingOperation(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val operationType: String,       // "CREATE", "UPDATE", "DELETE"
    val entityType: String,          // "article", "comment"
    val entityId: String,
    val payload: String,             // JSON-serialized body
    val idempotencyKey: String,      // client-generated UUID, sent as a header
    val createdAt: Long = System.currentTimeMillis(),
    val retryCount: Int = 0,
    val status: String = "PENDING"   // "PENDING" | "FAILED"
)

// DAO must order FIFO: @Query("SELECT * FROM pending_operations
//   WHERE status = 'PENDING' ORDER BY createdAt ASC, id ASC")
class SyncQueue(
    private val pendingOpsDao: PendingOperationDao,
    private val connectivityMonitor: ConnectivityMonitor
) {
    // Single-flight: enqueue() and the background worker both call processQueue(),
    // and two concurrent drains would POST the same operation twice.
    private val mutex = Mutex()

    suspend fun enqueue(operation: PendingOperation) {
        pendingOpsDao.insert(operation)
        if (connectivityMonitor.isConnected.first()) processQueue()
    }

    suspend fun processQueue() = mutex.withLock {
        for (op in pendingOpsDao.getAllPending()) {
            try {
                executeSyncOperation(op)          // sends Idempotency-Key: op.idempotencyKey
                pendingOpsDao.delete(op)
            } catch (e: Exception) {
                currentCoroutineContext().ensureActive()   // never swallow cancellation
                when {
                    // 4xx other than 408/429 will never succeed on replay - fail fast.
                    e is ClientRequestException && e.response.status.value !in setOf(408, 429) ->
                        pendingOpsDao.update(op.copy(status = "FAILED"))
                    op.retryCount + 1 >= MAX_RETRIES ->
                        // Never silently drop a user's write - mark it failed and surface in UI
                        pendingOpsDao.update(op.copy(status = "FAILED"))
                    else -> {
                        pendingOpsDao.update(op.copy(retryCount = op.retryCount + 1))
                        return@withLock          // stop the drain; preserve write ordering
                    }
                }
            }
        }
    }
}
```

- Persist the retry bump **before** the next attempt, or a process death resets the counter and the queue retries forever.
- Stop the drain on the first transient failure. Continuing past it reorders dependent writes (a DELETE landing before its CREATE).
- Coalesce on enqueue: a second UPDATE to the same `entityType`/`entityId` should replace the pending one rather than append; a DELETE should drop pending CREATEs/UPDATEs for that id.
- The server must dedupe on `idempotencyKey`. Without it, any retry after a response that was lost in flight duplicates the write.

## Conflict Resolution Strategies

### Server-Arbitrated (preferred): version / ETag

Let the server reject stale writes instead of guessing on the client. Send the version you read
(`If-Match: <etag>` or a `version` field); on `409 Conflict` / `412 Precondition Failed`, refetch
and re-apply.

```kotlin
suspend fun push(local: Article): Article = try {
    api.update(local.id, local, ifMatch = local.etag)
} catch (e: ResponseException) {
    if (e.response.status in setOf(HttpStatusCode.PreconditionFailed, HttpStatusCode.Conflict)) {
        val remote = api.get(local.id)
        api.update(local.id, merge(base = local.baseSnapshot, local, remote), ifMatch = remote.etag)
    } else throw e
}
```

### Last-Write-Wins

```kotlin
fun resolveLastWriteWins(local: SyncEntity, remote: SyncEntity): SyncEntity =
    if (local.updatedAt >= remote.updatedAt) local else remote
```

Only safe when `updatedAt` is **server-assigned**. Comparing client clocks silently loses writes:
a device whose clock is minutes fast wins every conflict. If the write originated offline, the
client timestamp records intent order only — stamp the authoritative time on receipt.

### Field-Level Merge

Three-way merge needs the `base` snapshot the client last synced, stored alongside the row.
Without it you cannot tell "local changed the field" from "remote changed it".

```kotlin
fun merge(base: Article, local: Article, remote: Article): Article = Article(
    id = base.id,
    // local edit wins; if local is unchanged, take whatever remote has
    title = if (local.title != base.title) local.title else remote.title,
    body = if (local.body != base.body) local.body else remote.body,
    updatedAt = maxOf(local.updatedAt, remote.updatedAt)
)
```

A field both sides changed is a genuine conflict — this code silently drops the remote edit.
For text fields users care about, surface a picker instead of merging blind. For counters and
sets, model the field as a CRDT (add/remove sets, grow-only counters) so merges are commutative.

## Retry with Exponential Backoff

```kotlin
suspend fun <T> retryWithBackoff(
    maxRetries: Int = 3,
    initialDelay: Duration = 1.seconds,
    maxDelay: Duration = 30.seconds,
    factor: Double = 2.0,
    retryOn: (Throwable) -> Boolean = ::isTransient,
    block: suspend () -> T
): T {
    var currentDelay = initialDelay
    repeat(maxRetries - 1) {
        try {
            return block()
        } catch (e: Exception) {
            currentCoroutineContext().ensureActive()   // rethrows CancellationException
            if (!retryOn(e)) throw e
            // Full jitter: without it, every client that dropped on the same outage
            // retries in lockstep and stampedes the server back down.
            delay(Random.nextLong(currentDelay.inWholeMilliseconds + 1))
            currentDelay = (currentDelay * factor).coerceAtMost(maxDelay)
        }
    }
    return block() // final attempt, let exception propagate
}

// Retry timeouts, IO failures, 408, 429 and 5xx. Never retry the other 4xx
// (400/401/403/404/422): the request is wrong, and replaying it just burns battery.
fun isTransient(e: Throwable): Boolean = when (e) {
    // In commonMain with Ktor 3.x, IOException is kotlinx.io.IOException
    // (HttpRequestTimeoutException already extends it; listed for clarity).
    is HttpRequestTimeoutException, is IOException -> true
    is ResponseException -> e.response.status.value.let { it == 408 || it == 429 || it >= 500 }
    else -> false
}
```

Honour `Retry-After` when the server sends it — it overrides the computed delay.

## Android WorkManager for Background Sync

```kotlin
// Extra constructor params beyond (context, params) require a custom WorkerFactory
// (Koin: workManagerFactory() + worker { }; Hilt: @HiltWorker) or instantiation fails at runtime.
class SyncWorker(
    context: Context,
    params: WorkerParameters,
    private val syncQueue: SyncQueue
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        return try {
            syncQueue.processQueue()
            Result.success()
        } catch (e: Exception) {
            // WorkManager cancels doWork()'s coroutine on stop; swallowing that here
            // turns a cancellation into a spurious retry.
            currentCoroutineContext().ensureActive()
            if (runAttemptCount < 3) Result.retry() else Result.failure()
        }
    }
}

// Schedule periodic sync
fun scheduleSyncWork(workManager: WorkManager) {
    val constraints = Constraints.Builder()
        // NetworkType.CONNECTED does NOT mean validated internet. Use
        // NetworkType.UNMETERED for bulk payloads; on API 28+ you can pass a full
        // NetworkRequest via Constraints.Builder.setRequiredNetworkRequest(request, CONNECTED).
        .setRequiredNetworkType(NetworkType.CONNECTED)
        .build()

    val syncRequest = PeriodicWorkRequestBuilder<SyncWorker>(15, TimeUnit.MINUTES)
        .setConstraints(constraints)
        // Min backoff is WorkRequest.MIN_BACKOFF_MILLIS (10s); lower values are clamped.
        .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
        .build()

    workManager.enqueueUniquePeriodicWork(
        "sync_work",
        // KEEP ignores the new request if one is already enqueued - so a changed
        // interval or constraint never ships. Use UPDATE to re-apply the spec while
        // preserving the existing period's state.
        ExistingPeriodicWorkPolicy.UPDATE,
        syncRequest
    )
}
```

- 15 minutes is the platform floor (`PeriodicWorkRequest.MIN_PERIODIC_INTERVAL_MILLIS`); the system batches runs and will fire later than requested. Never treat it as a timer.
- `PeriodicWorkRequest` gives no ordering across runs — the queue drain itself must be idempotent and single-flight.
- To sync immediately after a user write, enqueue a `OneTimeWorkRequest` with `setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)` rather than shortening the period.
- Current stable: `androidx.work:work-runtime-ktx:2.11.2`. For deeper WorkManager coverage prefer `background-processing`.

## iOS BGTaskScheduler Equivalent

Info.plist needs **both**: `BGTaskSchedulerPermittedIdentifiers` listing every identifier, and
`UIBackgroundModes` containing `fetch` (for `BGAppRefreshTask`) and/or `processing` (for
`BGProcessingTask`). Miss either and `submit(_:)` throws `BGTaskScheduler.Error.notPermitted`.

Pick the right request type — this is the usual mistake:

| | `BGAppRefreshTaskRequest` | `BGProcessingTaskRequest` |
|---|---|---|
| For | short catch-up fetch (~30s) | long/heavy work (minutes) |
| Runs | periodically, system-learned schedule | idle windows, typically overnight while charging |
| Options | none | `requiresNetworkConnectivity`, `requiresExternalPower` |

A queue drain that should follow the user's activity is an **app refresh** task. A processing task
with `earliestBeginDate` 15 minutes out will still not run for hours.

```swift
import BackgroundTasks

func registerBackgroundSync() {
    // Must be called before didFinishLaunching returns - registering later traps.
    BGTaskScheduler.shared.register(
        forTaskWithIdentifier: "com.example.sync",
        using: nil
    ) { task in
        handleSync(task: task as! BGAppRefreshTask)
    }
}

func scheduleSync() {
    let request = BGAppRefreshTaskRequest(identifier: "com.example.sync")
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // a floor, not a schedule
    try? BGTaskScheduler.shared.submit(request)
}

func handleSync(task: BGAppRefreshTask) {
    scheduleSync() // submitted tasks run once - resubmit here for the next cycle
    let syncTask = Task {
        do {
            try await SyncService.shared.processQueue()
            task.setTaskCompleted(success: true)
        } catch {
            task.setTaskCompleted(success: false)
        }
    }
    // Set before the work can finish: the system may expire the task almost immediately.
    task.expirationHandler = { syncTask.cancel() }
}
```

The system decides if and when these run, based on usage patterns and budget — a background task
is opportunistic catch-up, never the only path for a pending write. Also drain the queue on
foreground and on connectivity regain. For a sync the user explicitly started and watched
(export, upload), iOS 26's `BGContinuedProcessingTask` continues foreground-initiated work after
backgrounding; it is registered on demand rather than at launch and is expired if it stops
reporting progress.

## Best Practices

- The local database is the single source of truth. The UI observes it; the network only writes into it. Never let a screen render straight from an API response.
- Default to cache-first; use network-first only where staleness causes real harm.
- Set TTLs per data type: user profiles (long), feeds (short), balances and prices (none — fetch on view).
- Persist pending writes in a table so they survive process death, and make every replayable write idempotent.
- Distinguish "no data" from "stale data" in the UI. `Resource.Error(message, data)` carries both; a spinner over stale rows with no explanation is worse than an offline banner.
- Rethrow `CancellationException` (or call `currentCoroutineContext().ensureActive()`) in every `catch (e: Exception)` around suspend calls — swallowing it breaks structured concurrency.
- Never `catch` around `emit`/`emitAll` and then emit again — that violates flow exception transparency and throws at runtime.
- Log sync failures and expose an explicit retry; a write silently stuck in "FAILED" is data loss from the user's view.
- Test with airplane mode, a slow/lossy link (Network Link Conditioner, `adb shell cmd netpolicy`), and process death mid-drain — not just online/offline.

Related skills: `room-patterns` (Android persistence), `sqldelight-patterns` (commonMain persistence), `kmp-repositories` (repository boundary), `multiplatform-settings` (TTL storage), `background-processing` (WorkManager/BGTaskScheduler depth), `error-handling-result` (mapping failures), `pagination-patterns` (Paging 3 `RemoteMediator` is the offline-first pattern for paged lists). For a source-backed treatment of the Android data layer prefer `android-skills:android-data-layer`.
