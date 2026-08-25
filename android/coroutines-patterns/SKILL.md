---
name: coroutines-patterns
description: General Kotlin Coroutines and Flow patterns - structured concurrency, scopes, error handling (supervisorScope, CoroutineExceptionHandler), cancellation, and Flow operators. Single-platform/JVM-oriented concepts. For multiplatform shared code, iOS main-thread/Darwin dispatchers, or exposing Flow to Swift, use shared-coroutines. For deeper, source-backed coroutine coverage (dispatcher selection, cancellation, exception handling) prefer android-skills:kotlin-coroutines; for Flow/StateFlow/SharedFlow/Channel depth use android-skills:kotlin-flows.
---

# Coroutines Patterns

Structured concurrency for Kotlin.

## Coroutine Scopes

```kotlin
// ✅ ViewModel scope (auto-cancelled)
class HomeViewModel : ViewModel() {
    fun loadData() {
        viewModelScope.launch {
            // Cancelled when ViewModel cleared
        }
    }
}

// ✅ Lifecycle scope
class MainActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        lifecycleScope.launch {
            // Cancelled when lifecycle destroyed
        }
    }
}

// ❌ AVOID: GlobalScope
GlobalScope.launch { }  // Never cancelled, memory leaks
```

## Dispatchers

```kotlin
// Main - UI operations
withContext(Dispatchers.Main) {
    textView.text = "Updated"
}

// IO - Network, disk
withContext(Dispatchers.IO) {
    api.fetchData()
    database.query()
}

// Default - CPU intensive
withContext(Dispatchers.Default) {
    list.sortedBy { it.score }
}
```

## Flow Patterns

```kotlin
// StateFlow for UI state
private val _state = MutableStateFlow(HomeState())
val state: StateFlow<HomeState> = _state.asStateFlow()

// SharedFlow for events (replay=0: emissions with no active
// collector are dropped — extraBufferCapacity does NOT save them,
// it only buffers for slow existing subscribers; for must-deliver
// events use Channel(BUFFERED).receiveAsFlow() instead)
private val _events = MutableSharedFlow<Event>()
val events: SharedFlow<Event> = _events.asSharedFlow()

// Collect with lifecycle
@Composable
fun HomeScreen(viewModel: HomeViewModel) {
    val state by viewModel.state.collectAsStateWithLifecycle()
}
```

## Flow Operators

```kotlin
flow
    .filter { it.isActive }
    .map { transform(it) }
    .distinctUntilChanged()
    .debounce(300)  // still @FlowPreview: needs @OptIn(FlowPreview::class)
    .catch { emit(fallback) }
    .collect { process(it) }
```

## Error Handling

```kotlin
// Try-catch in coroutine (same _state: MutableStateFlow<HomeState> as above;
// don't name a state subtype `Error` — kotlin.Error is a default import and
// `Error(e.message)` silently resolves to the Throwable)
viewModelScope.launch {
    try {
        _state.value = HomeState(data = repository.fetchData())
    } catch (e: CancellationException) {
        throw e  // Never swallow cancellation
    } catch (e: Exception) {
        _state.value = HomeState(error = e.message)
    }
}

// supervisorScope - siblings don't cancel
supervisorScope {
    launch { task1() }  // Failure doesn't cancel task2
    launch { task2() }
}

// CoroutineExceptionHandler - last-resort logging for uncaught
// exceptions in launch. Only effective on root coroutines (or
// supervisorScope children); async surfaces failures via await().
val handler = CoroutineExceptionHandler { _, e -> log(e) }
scope.launch(handler) { risky() }
```

## Cancellation

```kotlin
// Cooperative cancellation in CPU-bound loops
suspend fun processItems(items: List<Item>) {
    items.forEach { item ->
        // Bare ensureActive() needs a CoroutineScope receiver;
        // in a plain suspend fun use the context extension:
        coroutineContext.ensureActive()
        process(item)
    }
}

// CancellationException handling
try {
    coroutineWork()
} catch (e: CancellationException) {
    throw e  // Don't swallow!
} catch (e: Exception) {
    handleError(e)
}
```
