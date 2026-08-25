---
name: jetpack-compose
description: Jetpack Compose quick patterns for declarative UI, state management, theming, animations, and performance - Android-target focus. For deep, source-backed Compose and Compose Multiplatform coverage (CMP, ComposeUIViewController, recomposition internals, design-to-code) prefer android-skills:compose. For Material 3 Expressive components specifically use m3-expressive.
---

# Jetpack Compose Patterns

Modern declarative UI patterns for Android.

## State Management

### State Hoisting

```kotlin
// ✅ CORRECT: Stateless composable
@Composable
fun Counter(
    count: Int,
    onIncrement: () -> Unit,
    modifier: Modifier = Modifier
) {
    Row(modifier = modifier) {
        Text("Count: $count")
        Button(onClick = onIncrement) {
            Text("+")
        }
    }
}

// Parent owns state
@Composable
fun CounterScreen() {
    var count by rememberSaveable { mutableIntStateOf(0) }
    
    Counter(
        count = count,
        onIncrement = { count++ }
    )
}
```

### Remember Variants

```kotlin
// remember - Survives recomposition. Use mutableIntStateOf/mutableFloatStateOf/
// mutableLongStateOf/mutableDoubleStateOf for primitives (avoids autoboxing).
var alpha by remember { mutableFloatStateOf(1f) }

// rememberSaveable - Survives config change and process death (Bundle-storable
// values automatically; anything else needs a Saver)
var count by rememberSaveable { mutableIntStateOf(0) }

// remember with key - Resets on key change
val animation = remember(itemId) { Animatable(0f) }

// derivedStateOf - Recomposes readers only when the RESULT changes.
// Inputs must be snapshot State reads (here email/password are State-backed);
// plain parameters won't trigger recalculation - use remember(param) instead.
val isValid by remember {
    derivedStateOf { email.isNotBlank() && password.length >= 8 }
}
```

### Collecting Flows

```kotlin
// androidx.lifecycle:lifecycle-runtime-compose
// Stops collection when the UI is not visible (unlike collectAsState)
val uiState by viewModel.uiState.collectAsStateWithLifecycle()
```

## Composition Patterns

### Slot API

```kotlin
// M3 TopAppBar itself is stable (material3 1.4.0) - no opt-in needed.
// @OptIn(ExperimentalMaterial3Api::class) is still required if you pass a
// scrollBehavior: TopAppBarScrollBehavior is experimental in 1.4.0.
@Composable
fun AppBar(
    title: @Composable () -> Unit,
    navigationIcon: @Composable () -> Unit = {},
    actions: @Composable RowScope.() -> Unit = {}
) {
    TopAppBar(
        title = { title() },
        navigationIcon = { navigationIcon() },
        actions = actions
    )
}

// Usage
AppBar(
    title = { Text("Home") },
    navigationIcon = { IconButton(onClick = {}) { Icon(Icons.Default.Menu, null) } },
    actions = {
        IconButton(onClick = {}) { Icon(Icons.Default.Search, null) }
    }
)
```

### Modifier Pattern

```kotlin
@Composable
fun CustomButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,  // First optional parameter
    enabled: Boolean = true,
    content: @Composable RowScope.() -> Unit
) {
    Button(
        onClick = onClick,
        modifier = modifier,  // Apply modifier first
        enabled = enabled,
        content = content
    )
}
```

## Side Effects

### LaunchedEffect

```kotlin
@Composable
fun HomeScreen(viewModel: HomeViewModel) {
    // Runs once per entry into composition (again if the composable
    // leaves and re-enters). Prefer loading in the ViewModel when possible.
    LaunchedEffect(Unit) {
        viewModel.loadData()
    }
    
    // Cancels and relaunches when key changes
    LaunchedEffect(userId) {
        viewModel.loadUser(userId)
    }
}
```

### DisposableEffect

```kotlin
@Composable
fun LifecycleObserver(onResume: () -> Unit) {
    // Import from androidx.lifecycle.compose.LocalLifecycleOwner (lifecycle 2.8+).
    // androidx.compose.ui.platform.LocalLifecycleOwner is DEPRECATED.
    val lifecycleOwner = LocalLifecycleOwner.current
    
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) onResume()
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
        }
    }
}
```

## Theming

### Material 3

```kotlin
@Composable
fun AppTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit
) {
    val colorScheme = if (darkTheme) DarkColorScheme else LightColorScheme
    
    MaterialTheme(
        colorScheme = colorScheme,
        typography = AppTypography,
        content = content
    )
}

// Usage
val backgroundColor = MaterialTheme.colorScheme.surface
val textStyle = MaterialTheme.typography.bodyLarge
```

## Lists

### LazyColumn

```kotlin
LazyColumn {
    items(
        items = users,
        key = { it.id }  // Critical for performance
    ) { user ->
        UserItem(user = user)
    }
}
```

## Animations

### Animate Values

```kotlin
val alpha by animateFloatAsState(
    targetValue = if (visible) 1f else 0f,
    animationSpec = tween(durationMillis = 300)
)

val size by animateDpAsState(
    targetValue = if (expanded) 200.dp else 100.dp
)
```

### AnimatedContent

```kotlin
AnimatedContent(
    targetState = state,
    transitionSpec = {
        fadeIn() togetherWith fadeOut()
    }
) { targetState ->
    when (targetState) {
        is Loading -> LoadingContent()
        is Success -> SuccessContent(targetState.data)
        is Error -> ErrorContent()
    }
}
```
