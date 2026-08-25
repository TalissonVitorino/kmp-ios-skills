---
name: navigation
description: Navigation for Android and Kotlin Multiplatform/iOS apps - all three approaches in one place. (A) Jetpack Navigation Compose (androidx.navigation - NavController, NavHost, composable<Route>, type-safe @Serializable routes, nested graphs, bottom nav, deep links, results via SavedStateHandle). (B) Jetpack Navigation 3 / Nav3 (NavDisplay, NavKey, back-stack-as-state, scenes for dialog/bottom-sheet/list-detail/two-pane, multiple back stacks, conditional nav, Hilt/Koin) with a full recipe reference tree. (C) Multiplatform navigation (Voyager, Decompose, Compose Multiplatform Navigation, SwiftUI NavigationStack interop). Use for any navigation task - choosing an approach, NavHost setup, deep links, bottom tabs, passing arguments, or sharing navigation across Android and iOS.
metadata:
  last-updated: '2026-08-14'
---

# Mobile Navigation (Android + KMP/iOS)

This skill unifies the three navigation approaches. Pick one with the table, then jump to its section.

## Which approach?

| Approach | Use when | Section |
|---|---|---|
| **Jetpack Navigation Compose** (`androidx.navigation`) | Android-only app, mature & stable, `NavHost` + `composable<Route>` | A |
| **Jetpack Navigation 3 (Nav3)** | Android, want the new back-stack-as-state model, adaptive Scenes (list-detail/two-pane), multiple back stacks | B |
| **Multiplatform** (Voyager / Decompose / CMP nav / SwiftUI) | Shared navigation across Android + iOS from `commonMain` | C |

> KMP + iOS shops: use **C** for shared nav. Use **A/B** when the Android app drives navigation natively, or for the androidMain side.

---

# A. Jetpack Navigation Compose (androidx.navigation) — Android

## Dependencies

```kotlin
dependencies {
    implementation("androidx.navigation:navigation-compose:2.9.8")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0")
}
```

## Type-safe routes

```kotlin
@Serializable
sealed interface Route {
    @Serializable data object Home : Route
    @Serializable data object Settings : Route
    @Serializable data class UserProfile(val userId: String) : Route
    @Serializable data class PostDetail(val postId: Long, val showComments: Boolean = false) : Route
}
```

## NavHost

```kotlin
@Composable
fun AppNavHost(
    navController: NavHostController = rememberNavController(),
    modifier: Modifier = Modifier,
) {
    NavHost(navController = navController, startDestination = Route.Home, modifier = modifier) {
        composable<Route.Home> {
            HomeScreen(
                onNavigateToProfile = { userId -> navController.navigate(Route.UserProfile(userId)) },
                onNavigateToSettings = { navController.navigate(Route.Settings) },
            )
        }
        composable<Route.Settings> { SettingsScreen(onBack = { navController.popBackStack() }) }
        composable<Route.UserProfile> { entry ->
            UserProfileScreen(userId = entry.toRoute<Route.UserProfile>().userId)
        }
        composable<Route.PostDetail> { entry ->
            val r = entry.toRoute<Route.PostDetail>()
            PostDetailScreen(postId = r.postId, showComments = r.showComments)
        }
    }
}
```

## Returning results (SavedStateHandle)

```kotlin
// Caller listens
val result = navController.currentBackStackEntry
    ?.savedStateHandle?.getStateFlow<String?>("selected_item", null)?.collectAsState()
LaunchedEffect(result?.value) { result?.value?.let { /* handle */ } }

// Callee sets + pops
navController.previousBackStackEntry?.savedStateHandle?.set("selected_item", "chosen")
navController.popBackStack()
```

## Deep links

```kotlin
composable<Route.PostDetail>(
    deepLinks = listOf(
        navDeepLink { uriPattern = "https://example.com/posts/{postId}" },
        navDeepLink { uriPattern = "myapp://posts/{postId}" },
    )
) { entry -> PostDetailScreen(postId = entry.toRoute<Route.PostDetail>().postId) }
```

```xml
<intent-filter>
    <action android:name="android.intent.action.VIEW" />
    <category android:name="android.intent.category.DEFAULT" />
    <category android:name="android.intent.category.BROWSABLE" />
    <data android:scheme="https" android:host="example.com" />
    <data android:scheme="myapp" />
</intent-filter>
```

## Nested graphs

```kotlin
fun NavGraphBuilder.authNavGraph(navController: NavHostController) {
    navigation<AuthGraph>(startDestination = AuthGraph.Login) {
        composable<AuthGraph.Login> {
            LoginScreen(onLoginSuccess = {
                navController.navigate(Route.Home) { popUpTo(AuthGraph.Login) { inclusive = true } }
            })
        }
        composable<AuthGraph.Register> { RegisterScreen(onBack = { navController.popBackStack() }) }
    }
}
```

## Bottom navigation

```kotlin
@Serializable sealed interface BottomTab {
    @Serializable data object Feed : BottomTab
    @Serializable data object Search : BottomTab
    @Serializable data object Profile : BottomTab
}

@Composable
fun MainScreen() {
    val navController = rememberNavController()
    val entry by navController.currentBackStackEntryAsState()
    Scaffold(bottomBar = {
        NavigationBar {
            listOf(BottomTab.Feed, BottomTab.Search, BottomTab.Profile).forEach { tab ->
                NavigationBarItem(
                    selected = entry?.destination?.hasRoute(tab::class) == true,
                    onClick = {
                        navController.navigate(tab) {
                            popUpTo(navController.graph.findStartDestination().id) { saveState = true }
                            launchSingleTop = true
                            restoreState = true
                        }
                    },
                    icon = { /* … */ }, label = { /* … */ },
                )
            }
        }
    }) { padding ->
        NavHost(navController, startDestination = BottomTab.Feed, modifier = Modifier.padding(padding)) {
            composable<BottomTab.Feed> { FeedScreen() }
            composable<BottomTab.Search> { SearchScreen() }
            composable<BottomTab.Profile> { ProfileScreen() }
        }
    }
}
```

## Animated transitions & testing

```kotlin
composable<Route.PostDetail>(
    enterTransition = { slideIntoContainer(SlideDirection.Left, tween(300)) },
    popExitTransition = { slideOutOfContainer(SlideDirection.Right, tween(300)) },
) { /* … */ }
```

```kotlin
@Test fun navigateToProfile() {
    val navController = TestNavHostController(ApplicationProvider.getApplicationContext())
    composeTestRule.setContent {
        navController.navigatorProvider.addNavigator(ComposeNavigator())
        AppNavHost(navController = navController)
    }
    composeTestRule.onNodeWithText("View Profile").performClick()
    assertTrue(navController.currentBackStackEntry?.destination?.route?.contains("UserProfile") == true)
}
```

---

# B. Jetpack Navigation 3 (Nav3) — Android (newer)

Nav3 models the back stack as **observable state** you own (a `List<NavKey>`), rendered by `NavDisplay`. Now stable: `androidx.navigation3:navigation3-runtime` / `navigation3-ui` **1.1.6**, plus `androidx.lifecycle:lifecycle-viewmodel-navigation3` **2.11.0** for ViewModel scoping. This section is the official Google guide; the deep recipes live in `references/` (bundled with this skill).

## Migration & requirements

- **[Nav2 → Nav3 migration guide](references/android/guide/navigation/navigation-3/migration-guide.md)** — dependencies, route changes, state, UI replacements.
- **[Migrate to type-safe navigation (Nav2)](references/android/guide/navigation/type-safe-destinations.md)** — string routes → type-safe.

## Developer documentation

- **[Navigation 3 overview](references/android/guide/navigation/navigation-3/index.md)** — basics, saving/managing state, modularizing, custom layouts via Scenes, animations, destination wrappers.

## Recipes

**Basic API:** [Basic](references/android/guide/navigation/navigation-3/recipes/basic.md) · [Saveable back stack](references/android/guide/navigation/navigation-3/recipes/basicsaveable.md) · [Entry-provider DSL](references/android/guide/navigation/navigation-3/recipes/basicdsl.md)
**Common UI:** [bottom bar + multiple back stacks](references/android/guide/navigation/navigation-3/recipes/common-ui.md)
**Deep links:** [Static URI](references/android/guide/navigation/navigation-3/recipes/deeplinks-staticuri.md) · [URI with arguments](references/android/guide/navigation/navigation-3/recipes/deeplinks-uriarguments.md) · [Synthetic back stack](references/android/guide/navigation/navigation-3/recipes/deeplinks-syntheticbackstack.md) · [Custom matcher](references/android/guide/navigation/navigation-3/recipes/deeplinks-custommatcher.md)
**Scenes (built-in):** [Dialog](references/android/guide/navigation/navigation-3/recipes/dialog.md)
**Scenes (custom):** [BottomSheet](references/android/guide/navigation/navigation-3/recipes/bottomsheet.md) · [List-Detail](references/android/guide/navigation/navigation-3/recipes/scenes-listdetail.md) · [Two-pane](references/android/guide/navigation/navigation-3/recipes/scenes-twopane.md)
**Material Adaptive:** [List-Detail](references/android/guide/navigation/navigation-3/recipes/material-listdetail.md) · [Supporting Pane](references/android/guide/navigation/navigation-3/recipes/material-supportingpane.md)
**Animations:** [override default/per-destination](references/android/guide/navigation/navigation-3/recipes/animations.md) · [Conditional transitions](references/android/guide/navigation/navigation-3/recipes/conditional-transitions.md)
**Back stack behavior:** [Multiple back stacks](references/android/guide/navigation/navigation-3/recipes/multiple-backstacks.md) — per-tab state incl. tab-reselect scroll-to-top
**Conditional nav:** [auth / onboarding gating](references/android/guide/navigation/navigation-3/recipes/conditional.md)
**Lifecycle:** [observe Lifecycle per NavEntry](references/android/guide/navigation/navigation-3/recipes/lifecycle-owner.md)
**Architecture (modular):** [Hilt](references/android/guide/navigation/navigation-3/recipes/modular-hilt.md) · [Koin](references/android/guide/navigation/navigation-3/recipes/modular-koin.md)
**ViewModel:** [passing arguments](references/android/guide/navigation/navigation-3/recipes/passingarguments.md)
**Returning results:** [as events](references/android/guide/navigation/navigation-3/recipes/results-event.md) · [as state](references/android/guide/navigation/navigation-3/recipes/results-state.md) — `@Serializable` results (not `Parcelize`); pair `rememberSaveableStateHolderNavEntryDecorator()` with `rememberResultEventBusNavEntryDecorator()`

> Keywords: NavDisplay, NavKey, NavEntry, entryProvider, Scenes, multiple back stacks, list-detail, two-pane, supporting pane, DeepLinkRequest, UriDeepLinkMatcher. (Official Google content, Apache 2.0, synced 2026-08-14.)

---

# C. Multiplatform navigation (KMP / iOS)

Shared navigation from `commonMain` across Android + iOS.

## Voyager (simple, Compose Multiplatform)

```kotlin
// deps: cafe.adriel.voyager:voyager-navigator, voyager-screenmodel
object HomeScreen : Screen {
    @Composable override fun Content() {
        val navigator = LocalNavigator.currentOrThrow
        Button(onClick = { navigator.push(DetailScreen("123")) }) { Text("Go to Detail") }
    }
}

data class DetailScreen(val id: String) : Screen {
    @Composable override fun Content() {
        val navigator = LocalNavigator.currentOrThrow
        val model = rememberScreenModel { DetailScreenModel(id, repo) }  // repo from DI (or voyager-koin's koinScreenModel)
        val user by model.state.collectAsState()
        // … render user; navigator.pop() to go back
    }
}

@Composable fun App() { Navigator(HomeScreen) }   // renders current screen + back stack
```

```kotlin
class DetailScreenModel(private val id: String, private val repo: UserRepository) : ScreenModel {
    private val _state = MutableStateFlow<User?>(null)
    val state = _state.asStateFlow()
    init { screenModelScope.launch { _state.value = repo.getUser(id) } }   // screenModelScope, not viewModelScope
}
```

## Decompose (lifecycle-aware, fine control)

```kotlin
// deps: com.arkivanov.decompose:decompose, extensions-compose
class RootComponent(ctx: ComponentContext) : ComponentContext by ctx {
    @Serializable sealed interface Config {
        @Serializable data object Home : Config
        @Serializable data class Detail(val id: String) : Config
    }

    private val nav = StackNavigation<Config>()
    val stack = childStack(
        source = nav,
        serializer = Config.serializer(),
        initialConfiguration = Config.Home,
        handleBackButton = true,
    ) { config, childCtx -> createChild(config, childCtx) }

    fun openDetail(id: String) = nav.pushNew(Config.Detail(id))
    fun back() = nav.pop()
}

@Composable
fun RootContent(component: RootComponent) {
    Children(stack = component.stack) { child ->
        when (val instance = child.instance) { /* render each child component */ }
    }
}
```

## Type-safe arguments (shared)

```kotlin
@Serializable
sealed interface Screen {
    @Serializable data object Home : Screen
    @Serializable data class UserDetail(val userId: String, val section: String? = null) : Screen
    @Serializable data class EditItem(val itemId: String, val mode: EditMode = EditMode.View) : Screen
}
@Serializable enum class EditMode { View, Edit, Create }
```

## iOS / SwiftUI interop

Two options for the iOS app:

1. **Shared Compose UI** — render the whole Compose Multiplatform navigation in a `ComposeUIViewController` (see `kmp-ios-integration`). Voyager/Decompose run as-is.
2. **Native SwiftUI** — keep navigation native: expose the shared destination/stack as a `StateFlow` from `commonMain` and drive a SwiftUI `NavigationStack` from it (bridge the Flow to Swift `async`/`AsyncSequence` via SKIE — see `kmp-ios-integration` and `swift-concurrency`).

```kotlin
// commonMain — a shared, observable stack the iOS app can drive a NavigationStack from
interface AppNavigator {
    val stack: StateFlow<List<Screen>>
    fun push(screen: Screen)
    fun pop()
}
```

---

## Best practices (all approaches)

- Prefer **type-safe routes** (`@Serializable`) over raw strings.
- Keep navigation out of screen composables — pass `onNavigateTo*` lambdas.
- After login, `popUpTo(start) { inclusive = true }` to clear the auth stack.
- Bottom tabs: `launchSingleTop = true` + `saveState`/`restoreState`.
- Scope ViewModels/ScreenModels to the nav entry (`hiltViewModel()`, `koinViewModel()`, `koinInject()`, Voyager `rememberScreenModel`).
- For shared (KMP) nav consumed from iOS, expose state as `StateFlow` and bridge with SKIE.

## See also

- Deep links (App Links / Universal Links / URI handling): `deep-linking`
- Adaptive multi-pane layouts (list-detail, supporting pane): `compose-adaptive`
- DI for navigation graphs: `kmp-di` / `android-di-koin`
- iOS bridge for shared nav state: `kmp-ios-integration`
