---
name: android-di-koin
description: |
  Koin dependency injection setup for an Android app (or the androidMain side of a KMP project) - module definitions per layer, ViewModel injection, assembling modules in :app, and koinViewModel() in composables. Use this skill whenever setting up Koin, defining a DI module, providing a repository or ViewModel, injecting a dependency, or wiring modules in the Application class. Trigger on phrases like "set up Koin", "add a Koin module", "inject a dependency", "DI module", "koinViewModel", "provide a ViewModel", "startKoin", or "single/viewModel/factory". For shared/commonMain or iOS-facing DI use the kmp-di skill instead.
---

# Android / KMP Dependency Injection (Koin)

## Principles

- One Koin module per feature layer — create it only if there are dependencies to provide.
- Modules are assembled in `:app`, never in feature modules themselves.
- In Compose root composables, always inject ViewModels via `koinViewModel()`.

For DSL fundamentals (scopes, qualifiers, parameters, `get()`/`inject()`) see the `koin-patterns` skill; for shared/commonMain wiring see `kmp-di`.

---

## Dependencies

Use the BOM so every Koin artifact stays on one version (current stable: **4.2.2**):

```kotlin
// :app
implementation(platform("io.insert-koin:koin-bom:4.2.2"))
implementation("io.insert-koin:koin-android")          // startKoin, androidContext, ViewModel DSL
implementation("io.insert-koin:koin-androidx-compose") // koinViewModel/koinInject (pulls koin-compose-viewmodel)
testImplementation("io.insert-koin:koin-test")         // verify() / verifyAll()

// feature modules: platform-free DSL only
implementation(platform("io.insert-koin:koin-bom:4.2.2"))
implementation("io.insert-koin:koin-core")           // :data — module {}, singleOf, factoryOf
implementation("io.insert-koin:koin-core-viewmodel") // :presentation — viewModelOf
```

---

## Module Definitions

Prefer the constructor-reference overloads (`singleOf`, `viewModelOf`, `factoryOf`) — they are more concise and let Koin resolve parameters automatically. Only fall back to the lambda overloads (`single { ... }`, `viewModel { ... }`, `factory { ... }`) when constructor injection alone is not enough, e.g. when you need to call a factory method, pass a named/qualified dependency, or do post-construction setup.

Imports (Koin 4.x):

```kotlin
import org.koin.core.module.dsl.singleOf      // also factoryOf, viewModelOf, bind
import org.koin.compose.viewmodel.koinViewModel
import org.koin.compose.koinInject
```

Stale APIs the IDE still suggests — reject them:

- `org.koin.androidx.viewmodel.dsl.viewModelOf` / `.viewModel` are `@Deprecated` ("Moved ViewModel DSL package") → use `org.koin.core.module.dsl.*`.
- `stateViewModel()` / `getStateViewModel()` were **removed** in Koin 4.x — they no longer resolve. Use the plain `viewModel` DSL; `SavedStateHandle` is autowired into any `viewModelOf(::X)` definition (Koin builds it from the owner's `CreationExtras`).

`org.koin.androidx.compose.koinViewModel` still exists as a non-deprecated Android-only twin, but `org.koin.compose.viewmodel.koinViewModel` is the identical multiplatform one and survives a move to commonMain — use it. For a ViewModel shared with the host Activity use `org.koin.compose.viewmodel.koinActivityViewModel()` (androidMain of `koin-compose-viewmodel`, pulled in by `koin-androidx-compose`).

### Data layer module

```kotlin
// feature:notes:data
val notesDataModule = module {
    singleOf(::RoomNoteRepository) { bind<NoteRepository>() }
}
```

### Presentation layer module

```kotlin
// feature:notes:presentation
val notesPresentationModule = module {
    viewModelOf(::NoteListViewModel)
    viewModelOf(::NoteDetailViewModel)
}
```

### Core data module (example)

```kotlin
// core:data
val coreDataModule = module {
    // singleOf works when the class has a single injectable constructor
    singleOf(::SessionPreferences)

    // Lambda overload needed here — calling a factory method, not a constructor
    single { HttpClientFactory.create(get()) }
    single { createDataStore(get()) }
}
```

---

## Assembly in `:app`

Register all modules in the `Application` class:

```kotlin
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        startKoin {
            androidLogger(if (BuildConfig.DEBUG) Level.ERROR else Level.NONE)
            androidContext(this@App)
            modules(
                // core
                coreDataModule,
                // features
                notesDataModule,
                notesPresentationModule,
                authDataModule,
                authPresentationModule,
                // ...
            )
        }
    }
}
```

- `androidContext()` registers `Context` and `Application` — never declare them yourself.
- `androidLogger()` defaults to `Level.INFO`, which is noisy in release builds; `Level` is `org.koin.core.logger.Level`.
- Call `startKoin` exactly once. A second call throws `org.koin.core.error.KoinApplicationAlreadyStartedException`; in tests use `stopKoin()` / `KoinTestRule` instead.

---

## Injecting in Composables

Always use `koinViewModel()` in Root composables; use `koinInject()` for non-ViewModel dependencies:

```kotlin
@Composable
fun NoteListRoot(
    onNavigateToDetail: (String) -> Unit,
    viewModel: NoteListViewModel = koinViewModel()
) { ... }
```

Pass runtime arguments (e.g. a nav argument) through `parametersOf`, and key the ViewModel by that argument so each value gets its own instance:

```kotlin
@Composable
fun NoteDetailRoot(
    noteId: String,
    viewModel: NoteDetailViewModel = koinViewModel(key = noteId) { parametersOf(noteId) }
) { ... }
```

The matching definition destructures the parameter — `viewModelOf` cannot autowire a runtime value:

```kotlin
viewModel { (noteId: String) -> NoteDetailViewModel(noteId, get()) }
```

`parameters` is a `ParametersDefinition` (`() -> ParametersHolder`), not a `ParametersHolder`: `koinViewModel(parameters = parametersOf(noteId))` does not compile. Written as a named argument it must stay a lambda — `koinViewModel(parameters = { parametersOf(noteId) })`.

Never pass ViewModels down the composable tree — inject at the Root level only. Keeping `koinViewModel()` as a *default parameter value* also lets previews and tests pass a fake instead.

---

## Verifying the Graph

Missing bindings are runtime failures in Koin, so guard them with a JVM test (`koin-test`):

```kotlin
import org.koin.test.verify.verifyAll

class ModuleVerificationTest {
    @Test
    fun `all modules resolve`() {
        appModules.verifyAll()
    }
}
```

`Module.verify()` / `List<Module>.verifyAll()` (`org.koin.test.verify.*`) are reflection-based and JVM-only — they never start a container, so no mocks are needed. Types Koin does not declare itself (`Context`, `Application`, `SavedStateHandle`, `WorkerParameters`) go in `extraTypes`; runtime `parametersOf` values go in `injections`:

```kotlin
@OptIn(KoinExperimentalAPI::class) // injectedParameters/definition are experimental
@Test
fun `all modules resolve`() {
    appModules.verifyAll(
        extraTypes = listOf(Context::class, SavedStateHandle::class),
        injections = injectedParameters(definition<NoteDetailViewModel>(String::class)),
    )
}
```

The older `checkModules()` / `checkKoinModules()` API is `@Deprecated` since Koin 4.0 (`ReplaceWith("modules.verifyAll()")`) — do not reach for it.

---

## Scoping Rules

| Scope | Preferred form | Fallback form | When to use |
|---|---|---|---|
| Singleton | `singleOf(::Impl) { bind<Interface>() }` | `single { ... }` | One instance for the app lifetime (repositories, HttpClient, DB) |
| ViewModel | `viewModelOf(::MyViewModel)` | `viewModel { ... }` | ViewModel instances scoped to their lifecycle |
| Factory | `factoryOf(::Impl)` | `factory { ... }` | New instance on every injection (rare — prefer singleton or ViewModel) |

Use the `*Of` constructor-reference form by default. Only use the lambda form when you cannot express the binding with a constructor reference (factory methods, named qualifiers, manual setup).

---

## Naming Convention

Name every module `<feature><Layer>Module` — `notesDataModule`, `notesPresentationModule`.

---

## Checklist: Adding DI for a New Feature

- [ ] Define `val <feature>DataModule = module { ... }` in `feature:data`
- [ ] Define `val <feature>PresentationModule = module { ... }` in `feature:presentation`
- [ ] Register both modules in `:app`'s `startKoin { modules(...) }`
- [ ] Use `koinViewModel()` in all Root composables
- [ ] Cover the new modules with `verifyAll()`
