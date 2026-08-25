---
name: app-lifecycle
description: App lifecycle patterns - process death handling, SavedStateHandle, ViewModel restoration, lifecycle-aware components, and background task management.
---

# App Lifecycle Patterns

## Android

### SavedStateHandle in ViewModel

SavedStateHandle survives both configuration changes and process death:

```kotlin
class ProductDetailViewModel(
    private val savedStateHandle: SavedStateHandle,
    private val productRepository: ProductRepository
) : ViewModel() {

    // Survives process death
    val productId: String = savedStateHandle.get<String>("productId") ?: ""

    // StateFlow backed by SavedStateHandle
    val searchQuery = savedStateHandle.getStateFlow("searchQuery", "")
    val selectedTab = savedStateHandle.getStateFlow("selectedTab", 0)

    fun updateSearchQuery(query: String) {
        savedStateHandle["searchQuery"] = query
    }

    fun selectTab(index: Int) {
        savedStateHandle["selectedTab"] = index
    }

    // Transient state (lost on process death, OK for derived data)
    private val _uiState = MutableStateFlow<UiState>(UiState.Loading)
    val uiState: StateFlow<UiState> = _uiState.asStateFlow()

    init {
        loadProduct(productId)
    }

    private fun loadProduct(id: String) {
        viewModelScope.launch {
            _uiState.value = UiState.Loading
            productRepository.getProduct(id)
                .onSuccess { _uiState.value = UiState.Success(it) }
                .onFailure { _uiState.value = UiState.Error(it.message ?: "Unknown error") }
        }
    }
}
```

### rememberSaveable in Compose

```kotlin
@Composable
fun SearchScreen() {
    // Survives configuration change AND process death
    var searchQuery by rememberSaveable { mutableStateOf("") }
    var isFilterExpanded by rememberSaveable { mutableStateOf(false) }

    // Non-Bundle-compatible collections need an explicit Saver
    val selectedFilters = rememberSaveable(
        saver = listSaver(
            save = { it.toList() },
            restore = { it.toMutableStateList() }
        )
    ) { mutableStateListOf<String>() }

    // Parcelable types are handled by the default autoSaver
    var selectedProduct by rememberSaveable {
        mutableStateOf<Product?>(null)
    }

    Column {
        TextField(
            value = searchQuery,
            onValueChange = { searchQuery = it },
            placeholder = { Text("Search...") }
        )
    }
}
```

`rememberSaveable` writes into the saved-instance-state Bundle, so the value must
be Bundle-compatible (primitives, `Parcelable`, or a custom `Saver`). For a
`@Serializable` type prefer `rememberSerializable` (compose-runtime 1.9+, the
renamed `KSerializer` overload): it goes through kotlinx-serialization and works
in `commonMain`, where `@Parcelize` does not.

For state that must survive Activity recreation but *not* process death — players,
in-memory caches, non-serializable managers — use `retain { }` from
`androidx.compose.runtime:runtime-retain` (Compose 1.10+). It returns the same
(`===`) instance, unlike the saveable APIs which hand back a restored copy.

### Lifecycle-Aware Data Collection

```kotlin
@Composable
fun ProductListScreen(viewModel: ProductListViewModel = hiltViewModel()) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()

    when (val state = uiState) {
        is UiState.Loading -> LoadingIndicator()
        is UiState.Success -> ProductList(state.products)
        is UiState.Error -> ErrorMessage(state.message)
    }
}
```

For non-Compose contexts, use `repeatOnLifecycle`:

```kotlin
class ProductListActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.uiState.collect { state ->
                    updateUI(state)
                }
            }
        }
    }
}
```

### LifecycleEventEffect in Compose

```kotlin
@Composable
fun AnalyticsScreen(screenName: String) {
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        analytics.logScreenView(screenName)
    }

    LifecycleEventEffect(Lifecycle.Event.ON_PAUSE) {
        analytics.logScreenExit(screenName)
    }

    // For start/stop pairs
    LifecycleStartEffect(Unit) {
        val connection = serviceConnection.bind()
        onStopOrDispose {
            connection.unbind()
        }
    }
}
```

### Process Death Testing

```bash
# `am kill` only kills processes "that are safe to kill" — a foregrounded app
# is not, so backgrounding first is required or the command is a silent no-op.
adb shell input keyevent KEYCODE_HOME
adb shell am kill com.myapp.android
# Now tap the app in recents: the Activity is recreated with a non-null
# savedInstanceState, restoring SavedStateHandle and rememberSaveable.

# `am force-stop` kills unconditionally but discards the task's saved state,
# so the relaunch is a cold start — use it to test cold start, not restoration.
adb shell am force-stop com.myapp.android

# "Don't keep activities" finishes the Activity but leaves the process alive:
# it exercises Activity recreation, NOT process death (statics, singletons and
# Application state all survive), so it cannot replace the `am kill` flow.
adb shell settings put global always_finish_activities 1
```

### WorkManager for Background Tasks

```kotlin
class SyncWorker(
    context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params), KoinComponent {

    // Koin: inject via KoinComponent (or use koin-androidx-workmanager's WorkerFactory).
    // Hilt: annotate with @HiltWorker + @AssistedInject instead.
    private val repository: SyncRepository by inject()

    override suspend fun doWork(): Result {
        return try {
            repository.syncPendingChanges()
            Result.success()
        } catch (e: Exception) {
            if (runAttemptCount < 3) Result.retry() else Result.failure()
        }
    }
}

// Schedule periodic sync
fun schedulePeriodicSync(context: Context) {
    val constraints = Constraints.Builder()
        .setRequiredNetworkType(NetworkType.CONNECTED)
        .setRequiresBatteryNotLow(true)
        .build()

    val syncRequest = PeriodicWorkRequestBuilder<SyncWorker>(
        repeatInterval = 1, repeatIntervalTimeUnit = TimeUnit.HOURS,
        flexTimeInterval = 15, flexTimeIntervalUnit = TimeUnit.MINUTES
    )
        .setConstraints(constraints)
        .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
        .build()

    WorkManager.getInstance(context).enqueueUniquePeriodicWork(
        "periodic_sync",
        ExistingPeriodicWorkPolicy.KEEP,
        syncRequest
    )
}
```

### Foreground Service Pattern

Since targetSdk 34, every FGS must declare a type in the manifest
(`<service android:foregroundServiceType="dataSync" .../>` plus the matching
`FOREGROUND_SERVICE_DATA_SYNC` permission) or `startForeground` throws
`MissingForegroundServiceTypeException`:

```kotlin
class UploadService : Service() {
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = NotificationCompat.Builder(this, "upload_channel")
            .setContentTitle("Uploading...")
            .setSmallIcon(R.drawable.ic_upload)
            .setProgress(100, 0, true)
            .build()

        ServiceCompat.startForeground(
            this, NOTIFICATION_ID, notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        )
        startUpload()
        return START_NOT_STICKY
    }

    // Android 15+ caps dataSync at 6h per 24h; the system then calls onTimeout
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val NOTIFICATION_ID = 1001
    }
}
```

Prefer WorkManager (expedited or `setForeground`) over a hand-rolled dataSync FGS for transfers that can tolerate deferral.

---

## iOS

### @SceneStorage for State Restoration

```swift
struct ContentView: View {
    // Automatically saved and restored per scene
    @SceneStorage("selectedTab") private var selectedTab = 0
    @SceneStorage("searchQuery") private var searchQuery = ""
    @SceneStorage("scrollPosition") private var scrollPosition: Double = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeTab()
                .tag(0)
            SearchTab(query: $searchQuery)
                .tag(1)
            ProfileTab()
                .tag(2)
        }
    }
}
```

### ScenePhase in SwiftUI

```swift
@main
struct MyApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            switch newPhase {
            case .active:
                // App is in the foreground and interactive
                refreshDataIfNeeded()
            case .inactive:
                // App is visible but not interactive (e.g., multitasking)
                saveInProgressWork()
            case .background:
                // App has moved to the background
                scheduleBackgroundTasks()
                savePersistentState()
            @unknown default:
                break
            }
        }
    }

    private func refreshDataIfNeeded() {
        let lastRefresh = UserDefaults.standard.object(forKey: "lastRefresh") as? Date ?? .distantPast
        if Date().timeIntervalSince(lastRefresh) > 300 { // 5 minutes
            Task { await DataManager.shared.refresh() }
        }
    }

    private func savePersistentState() {
        UserDefaults.standard.set(Date(), forKey: "lastBackgroundTime")
    }
}
```

### Background Tasks (BGTaskScheduler)

Prerequisites: add each identifier to `BGTaskSchedulerPermittedIdentifiers` in Info.plist and enable the Background Modes capability (`fetch` for BGAppRefreshTask, `processing` for BGProcessingTask). `register` returns `false` — it does not crash — for an identifier missing from the plist, so check the return value; submitting a task whose handler was never registered raises `NSInternalInconsistencyException` at runtime.

```swift
// Register before the app finishes launching (AppDelegate or App init)
func registerBackgroundTasks() {
    BGTaskScheduler.shared.register(
        forTaskWithIdentifier: "com.myapp.refresh",
        using: nil
    ) { task in
        handleAppRefresh(task: task as! BGAppRefreshTask)
    }

    BGTaskScheduler.shared.register(
        forTaskWithIdentifier: "com.myapp.sync",
        using: nil
    ) { task in
        handleSync(task: task as! BGProcessingTask)
    }
}

func scheduleAppRefresh() {
    let request = BGAppRefreshTaskRequest(identifier: "com.myapp.refresh")
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 min
    try? BGTaskScheduler.shared.submit(request)
}

func handleAppRefresh(task: BGAppRefreshTask) {
    scheduleAppRefresh() // Reschedule for next time

    let refreshTask = Task {
        do {
            try await DataManager.shared.refresh()
            task.setTaskCompleted(success: true)
        } catch {
            task.setTaskCompleted(success: false)
        }
    }

    // Set before/immediately after starting work — expiration can fire any time
    task.expirationHandler = {
        refreshTask.cancel()
    }
}
```

iOS 26+ adds `BGContinuedProcessingTask` for user-initiated work (exports, uploads) that continues after backgrounding, with system-surfaced progress UI — submit it only in direct response to a user action.

Test on a physical device (BGTaskScheduler does not fire in the Simulator) — pause in the debugger and run:
```
e -l objc -- (void)[[BGTaskScheduler sharedScheduler]
    _simulateLaunchForTaskWithIdentifier:@"com.myapp.refresh"]
```

---

## Cross-Platform Patterns

### State Preservation Strategy

| State Type | Android | iOS | Survives Process Death |
|-----------|---------|-----|----------------------|
| UI state (scroll, tab) | `SavedStateHandle` | `@SceneStorage` | Yes |
| Form input | `rememberSaveable` | `@SceneStorage` | Yes |
| ViewModel data | Re-fetch on restore | Re-fetch on restore | No (re-load) |
| User session | Keystore-backed storage (see mobile-security) | Keychain | Yes |
| Cache | Room/DataStore | SwiftData/Core Data/UserDefaults | Yes |
| Player, non-serializable manager | `retain { }` (Compose 1.10+) | `@State` on a root view | No (recreate) |

### Memory Pressure Handling

```kotlin
// Android — as of API 34 only UI_HIDDEN and BACKGROUND are still delivered;
// the RUNNING_*/MODERATE/COMPLETE levels are deprecated
class MyApplication : Application() {
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        when (level) {
            TRIM_MEMORY_UI_HIDDEN -> releaseUIResources()      // UI no longer visible
            TRIM_MEMORY_BACKGROUND -> ImageCache.trimToSize(50) // process is cache-eligible
        }
    }
}
```

```swift
// iOS
NotificationCenter.default.addObserver(
    forName: UIApplication.didReceiveMemoryWarningNotification,
    object: nil,
    queue: .main
) { _ in
    ImageCache.shared.removeAll()
    URLCache.shared.removeAllCachedResponses()
}
```

### Background/Foreground Transition Checklist

When entering background:
1. Save unsaved user input
2. Cancel non-essential network requests
3. Persist critical state to disk
4. Schedule background tasks if needed
5. Release large in-memory resources

When returning to foreground:
1. Check if session is still valid (token expiry)
2. Refresh stale data (compare timestamps)
3. Re-establish WebSocket connections
4. Sync any offline changes
5. Update UI with fresh data
