---
name: android-patterns
description: Core Android development patterns for Kotlin, including coroutines, lifecycle management, and functional programming idioms.
---

# Android Development Patterns

Modern Android patterns with Kotlin, coroutines, and functional programming.

## Kotlin Idioms

### Immutability

```kotlin
// ✅ Prefer val over var
val name: String = "John"

// ✅ Read-only collection types (List/Set/Map are read-only, NOT immutable:
// a MutableList held elsewhere can still change behind this reference)
val items: List<Item> = listOf(item1, item2)

// ✅ Data class with copy
data class User(val id: String, val name: String)
val updatedUser = user.copy(name = "Jane")
```

### Null Safety

```kotlin
// ✅ Safe call
val length = name?.length

// ✅ Elvis operator
val displayName = nullableName ?: "Unknown"

// ✅ let for null checks
nullableUser?.let { user ->
    processUser(user)
}

// ✅ Early return with null check
fun processUser(user: User?) {
    user ?: return
    // user is smart-cast to non-null
}
```

### Scope Functions

```kotlin
// let - Transform and return
val transformed = nullable?.let { transform(it) }

// run - Configure and return result
val result = service.run {
    configure()
    execute()
}

// with - Operate on object
with(binding) {
    title.text = "Title"
    subtitle.text = "Subtitle"
}

// apply - Configure and return self (receiver must expose vars;
// a data class of vals is configured with copy(), not apply)
val intent = Intent(context, DetailActivity::class.java).apply {
    putExtra(EXTRA_USER_ID, userId)
    flags = Intent.FLAG_ACTIVITY_CLEAR_TOP
}

// also - Side effects, return self
val user = repository.createUser(name).also {
    logger.log("Created user: ${it.id}")
}
```

### Extensions

```kotlin
// ✅ Extension functions
fun String.isValidEmail(): Boolean {
    return android.util.Patterns.EMAIL_ADDRESS.matcher(this).matches()
}

// ✅ Extension properties
val Context.screenWidth: Int
    get() = resources.displayMetrics.widthPixels

// Usage
if (email.isValidEmail()) { ... }
val width = context.screenWidth
```

## Lifecycle Patterns

### ViewModel

```kotlin
class HomeViewModel(
    private val repository: HomeRepository,
    savedStateHandle: SavedStateHandle
) : ViewModel() {

    private val _state = MutableStateFlow(HomeState())
    val state: StateFlow<HomeState> = _state.asStateFlow()
    
    init {
        loadData()
    }
    
    private fun loadData() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true) }
            
            repository.getItems()
                .onSuccess { items -> _state.update { it.copy(items = items, isLoading = false) } }
                .onFailure { error -> _state.update { it.copy(error = error.message, isLoading = false) } }
        }
    }
}
```

### Lifecycle-aware Collection

```kotlin
@Composable
fun HomeScreen(viewModel: HomeViewModel = koinViewModel()) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    
    HomeContent(state = state)
}
```

## Functional Patterns

### Result Type

```kotlin
// ✅ Use Result for operations that can fail
// ⚠️ runCatching also catches CancellationException — rethrow it,
// or cancellation stops propagating through the coroutine hierarchy
suspend fun fetchUser(id: String): Result<User> = runCatching {
    api.getUser(id).toDomain()
}.onFailure { if (it is CancellationException) throw it }

// ✅ Chain operations
repository.fetchUser(id)
    .map { it.profile }
    .mapCatching { decryptProfile(it) }
    .onSuccess { displayProfile(it) }
    .onFailure { showError(it) }
```

### Higher-Order Functions

```kotlin
// ✅ Pass functions as parameters
suspend fun <T> retry(
    times: Int,
    block: suspend () -> T
): T {
    repeat(times - 1) {
        try { return block() }
        catch (e: CancellationException) { throw e } // never swallow cancellation
        catch (e: Exception) { delay(1000) }
    }
    return block() // Last attempt
}

// Usage
val result = retry(3) { api.fetchData() }
```

### Sealed Classes

```kotlin
sealed interface UiState<out T> {
    data object Loading : UiState<Nothing>
    data class Success<T>(val data: T) : UiState<T>
    data class Error(val message: String) : UiState<Nothing>
}

// Exhaustive when
when (state) {
    is UiState.Loading -> LoadingIndicator()
    is UiState.Success -> Content(state.data)
    is UiState.Error -> ErrorMessage(state.message)
}
```

## Resource Management

### Context Extensions

```kotlin
// dp -> px. Round, don't truncate: the platform's own conversion
// (TypedValue.complexToDimensionPixelSize) rounds and never collapses a
// non-zero dimension to 0 px, which `(value * density).toInt()` does at low density.
// Needs kotlin.math.roundToInt.
fun Context.dpToPx(value: Int): Int =
    TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP,
        value.toFloat(),
        resources.displayMetrics,
    ).roundToInt()

fun Context.showToast(message: String) {
    Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
}
```

### String Resources

```xml
<!-- strings.xml -->
<string name="welcome_message">Welcome, %1$s!</string>
```

```kotlin
// Compose
stringResource(R.string.welcome_message, userName)
```
