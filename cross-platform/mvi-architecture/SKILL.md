---
name: mvi-architecture
description: Model-View-Intent architecture patterns for Android with unidirectional data flow, state management, and side effects.
---

# MVI Architecture

Unidirectional data flow architecture for Android and Compose Multiplatform.

```
Intent → ViewModel → State → UI
   ↑                        │
   └────────────────────────┘
```

Everything below compiles in `commonMain`: `ViewModel`/`viewModelScope`, `collectAsStateWithLifecycle`, and `repeatOnLifecycle` all have `commonMain` declarations. Mind the group id — a Compose Multiplatform module consumes the JetBrains-published build, `org.jetbrains.androidx.lifecycle:lifecycle-viewmodel` / `:lifecycle-runtime-compose` (2.11.0); an Android-only module consumes `androidx.lifecycle:*`. AndroidX's own artifacts are multiplatform too, but `lifecycle-runtime-compose` only started publishing Native/Wasm klibs at 2.9.3, while `lifecycle-viewmodel` and `lifecycle-runtime` have shipped them since 2.8.0.

DI wiring: `kmp-di` / `android-di-koin`. `Result` mapping: `error-handling-result`. Test tooling: `mobile-testing`.

## State

One data class per screen, all fields with defaults so the initial value is `HomeState()`.

```kotlin
@Immutable
data class HomeState(
    val isLoading: Boolean = false,
    val items: ImmutableList<Item> = persistentListOf(),
    val error: ErrorState? = null,
    val searchQuery: String = ""
) {
    sealed interface ErrorState {
        data class Network(val message: String) : ErrorState
        data object Unauthorized : ErrorState
    }
}
```

`@Immutable` is an unchecked promise: the Compose compiler trusts it and skips recomposition when the instance compares equal. A plain `List<Item>` satisfies that only if nobody mutates the backing list — an `ArrayList` handed over from a repository breaks it silently. Use `ImmutableList`/`persistentListOf()` from `org.jetbrains.kotlinx:kotlinx-collections-immutable`, or drop the annotation.

## Intent

```kotlin
sealed interface HomeIntent {
    data object LoadItems : HomeIntent
    data object Refresh : HomeIntent
    data class Search(val query: String) : HomeIntent
    data class ItemClicked(val id: String) : HomeIntent
    data object ClearError : HomeIntent
}
```

## Side Effects

```kotlin
sealed interface HomeSideEffect {
    data class NavigateToDetail(val itemId: String) : HomeSideEffect
    data class ShowSnackbar(val message: String) : HomeSideEffect
    data object NavigateToLogin : HomeSideEffect
}
```

Side effects are for things that must happen exactly once and cannot be re-derived from state (navigation, snackbars, sharesheets). Anything the UI can render from state — an error banner, a spinner — belongs in `HomeState`, not here. `receiveAsFlow()` is single-consumer: a second collector steals events, so collect it in exactly one place.

## ViewModel

```kotlin
class HomeViewModel(
    private val getItemsUseCase: GetItemsUseCase
) : ViewModel() {

    private val _state = MutableStateFlow(HomeState())
    val state: StateFlow<HomeState> = _state.asStateFlow()

    private val _sideEffects = Channel<HomeSideEffect>(Channel.BUFFERED)
    val sideEffects: Flow<HomeSideEffect> = _sideEffects.receiveAsFlow()

    init {
        onIntent(HomeIntent.LoadItems)
    }

    fun onIntent(intent: HomeIntent) {
        when (intent) {
            is HomeIntent.LoadItems -> loadItems()
            is HomeIntent.Refresh -> loadItems(refresh = true)
            is HomeIntent.Search -> search(intent.query)
            is HomeIntent.ItemClicked -> {
                viewModelScope.launch {
                    _sideEffects.send(HomeSideEffect.NavigateToDetail(intent.id))
                }
            }
            is HomeIntent.ClearError -> _state.update { it.copy(error = null) }
        }
    }

    private fun loadItems(refresh: Boolean = false) {
        viewModelScope.launch {
            if (!refresh) _state.update { it.copy(isLoading = true) }
            
            getItemsUseCase()
                .onSuccess { items ->
                    _state.update {
                        it.copy(isLoading = false, items = items.toImmutableList(), error = null)
                    }
                }
                .onFailure { error ->
                    _state.update { it.copy(isLoading = false, error = mapError(error)) }
                }
        }
    }
    
    // Text input goes into state on every keystroke so the field stays
    // responsive; debounce the query in a separate flow, not per keystroke.
    private fun search(query: String) {
        _state.update { it.copy(searchQuery = query) }
    }

    private fun mapError(error: Throwable): HomeState.ErrorState {
        return when (error) {
            is UnauthorizedException -> HomeState.ErrorState.Unauthorized
            else -> HomeState.ErrorState.Network(error.message ?: "Unknown error")
        }
    }
}
```

## UI Integration

```kotlin
@Composable
fun HomeScreen(
    viewModel: HomeViewModel = koinViewModel(),
    onNavigateToDetail: (String) -> Unit,
    onNavigateToLogin: () -> Unit
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val snackbarHostState = remember { SnackbarHostState() }
    val lifecycle = LocalLifecycleOwner.current.lifecycle

    // Collect side effects only while STARTED, so navigation never fires on a
    // stopped screen. The Channel holds whatever is sent while collection is
    // suspended and delivers it when the screen restarts.
    // No LoadItems dispatch here: the ViewModel's init already triggers the
    // initial load, and dispatching again on composition would double-load.
    LaunchedEffect(lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            viewModel.sideEffects.collect { effect ->
                when (effect) {
                    is HomeSideEffect.NavigateToDetail -> onNavigateToDetail(effect.itemId)
                    is HomeSideEffect.ShowSnackbar -> snackbarHostState.showSnackbar(effect.message)
                    is HomeSideEffect.NavigateToLogin -> onNavigateToLogin()
                }
            }
        }
    }
    
    HomeContent(
        state = state,
        onIntent = viewModel::onIntent,
        snackbarHostState = snackbarHostState
    )
}

@Composable
private fun HomeContent(
    state: HomeState,
    onIntent: (HomeIntent) -> Unit,
    snackbarHostState: SnackbarHostState
) {
    Scaffold(
        snackbarHost = { SnackbarHost(snackbarHostState) }
    ) { padding ->
        Box(Modifier.padding(padding)) {
            // Local val: `state.error` does not smart-cast to non-null when
            // HomeState lives in a different module.
            val error = state.error
            when {
                state.isLoading -> LoadingIndicator()
                error != null -> ErrorContent(
                    error = error,
                    onRetry = { onIntent(HomeIntent.LoadItems) }
                )
                else -> ItemList(
                    items = state.items,
                    onItemClick = { onIntent(HomeIntent.ItemClicked(it)) }
                )
            }
        }
    }
}
```

Imports that are easy to get wrong:

- `androidx.lifecycle.compose.LocalLifecycleOwner` — moved out of `androidx.compose.ui.platform` in Lifecycle 2.8; the Compose UI one is deprecated.
- `androidx.lifecycle.compose.collectAsStateWithLifecycle` and `androidx.lifecycle.repeatOnLifecycle` — `lifecycle-runtime-compose` / `lifecycle-runtime`, both multiplatform.
- `org.koin.compose.viewmodel.koinViewModel` from `io.insert-koin:koin-compose-viewmodel` for shared code; Android-only modules may instead use `org.koin.androidx.compose.koinViewModel` from `koin-androidx-compose`.

`HomeContent` takes only `state` + `onIntent`, so it previews and tests without a ViewModel. Keep the ViewModel out of every composable below the screen root.

## Testing

`viewModelScope` runs on `Dispatchers.Main`, so replace it with a test dispatcher; `runTest` then reuses that dispatcher's scheduler, so virtual time is shared. StateFlow conflates rapid emissions: when the use case returns without suspending, the transient `isLoading = true` value is overwritten before the collector resumes — assert the settled state, not intermediates.

```kotlin
private val getItemsUseCase = mockk<GetItemsUseCase>()

@BeforeEach
fun setUp() {
    Dispatchers.setMain(StandardTestDispatcher())
}

@AfterEach
fun tearDown() {
    Dispatchers.resetMain()
}

@Test
fun `when LoadItems succeeds, state contains items`() = runTest {
    val items = listOf(Item("1", "Test"))
    coEvery { getItemsUseCase() } returns Result.success(items)

    val viewModel = HomeViewModel(getItemsUseCase) // init dispatches LoadItems

    viewModel.state.test {
        awaitItem() // initial HomeState()

        val loaded = awaitItem() // conflated final state
        loaded.isLoading shouldBe false
        loaded.items shouldBe items
    }
}
```
