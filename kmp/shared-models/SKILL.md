---
name: shared-models
description: Shared data models for Kotlin Multiplatform using kotlinx.serialization. Cross-platform domain models with validation and serialization.
---

# Shared Models for KMP

Design and implement data models that work across all platforms in `shared/commonMain`.

## Core Dependencies

```kotlin
// build.gradle.kts (shared module)
kotlin {
    sourceSets {
        commonMain.dependencies {
            implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0")
            implementation("org.jetbrains.kotlinx:kotlinx-datetime:0.8.0")
            // As of kotlinx-datetime 0.7, Instant/Clock moved to kotlin.time
            // (import kotlin.time.Instant / kotlin.time.Clock); LocalDate/TimeZone stay in kotlinx.datetime.
            // 0.7.1+ keeps kotlinx.datetime.Instant/Clock as typealiases for migration.
            // kotlin.time.Instant/Clock are stable since Kotlin 2.3; on 2.1.20-2.2.x they still
            // require @OptIn(ExperimentalTime::class).
        }
    }
}
```

Enable serialization plugin:
```kotlin
plugins {
    kotlin("multiplatform") version "2.4.10"
    kotlin("plugin.serialization") version "2.4.10" // must match your Kotlin version
}
```

## Domain Models

### 1. Immutable Data Classes

```kotlin
// commonMain/kotlin/com/example/shared/model/User.kt
import kotlin.time.Instant

@Serializable
data class User(
    val id: String,
    val name: String,
    val email: String,
    val avatarUrl: String?,
    val createdAt: Instant,
    val lastActiveAt: Instant?
)
```

### 2. Sealed Hierarchies

```kotlin
// commonMain/kotlin/com/example/shared/model/UiState.kt
@Serializable
sealed class UiState<out T> {
    @Serializable
    data object Loading : UiState<Nothing>()

    @Serializable
    data class Success<T>(val data: T) : UiState<T>()

    @Serializable
    data class Error(val message: String, val code: String? = null) : UiState<Nothing>()
}

// Usage with type parameter
@Serializable
sealed class HomeState {
    @Serializable
    data object Loading : HomeState()

    @Serializable
    data class Loaded(val user: User, val items: List<Item>) : HomeState()

    @Serializable
    data class Error(val message: String) : HomeState()
}
```

A sealed hierarchy is encoded polymorphically with a `"type"` class discriminator holding the fully-qualified subclass name. If the JSON crosses a wire or is persisted, pin the wire names with `@SerialName("loaded")` on each subclass so package renames, refactors and R8 don't change the payload. Rename the discriminator key itself with `@OptIn(ExperimentalSerializationApi::class) @JsonClassDiscriminator("kind")` on the base, or drop `@Serializable` entirely on state that never leaves memory.

### 3. Result Wrapper

Declaring a type named `Result` shadows `kotlin.Result` for every file in the same package — prefer `ApiResult`/`Outcome` unless you accept fully qualifying the stdlib type. See `error-handling-result` for the wider error-modelling patterns.

```kotlin
// commonMain/kotlin/com/example/shared/model/Result.kt
@Serializable
sealed class Result<out T> {
    @Serializable
    data class Success<T>(val data: T) : Result<T>()

    @Serializable
    data class Error(val code: String, val message: String) : Result<Nothing>()
}

// Helper to convert from Kotlin Result
fun <T> Result<T>.toKotlinResult(): kotlin.Result<T> = when (this) {
    is Result.Success -> kotlin.Result.success(data)
    is Result.Error -> kotlin.Result.failure(RuntimeException("$code: $message"))
}
```

### 4. Paginated Response

```kotlin
// commonMain/kotlin/com/example/shared/model/Pagination.kt
@Serializable
data class PaginatedResponse<T>(
    val items: List<T>,
    val page: Int,
    val pageSize: Int,
    val totalPages: Int,
    val totalItems: Long
) {
    // Only properties with a backing field are serialized. A body property *with* a backing
    // field (`var stars: Int = 0`) becomes a field; getter-only and delegated ones do not.
    val hasMorePages: Boolean get() = page < totalPages
    val nextPage: Int? get() = if (hasMorePages) page + 1 else null
}

// For cursor-based pagination
@Serializable
data class CursorResponse<T>(
    val items: List<T>,
    val nextCursor: String?,
    val hasMore: Boolean
)
```

### 5. Request/Response Models

```kotlin
// commonMain/kotlin/com/example/shared/model/auth/AuthRequests.kt
@Serializable
data class LoginRequest(
    val email: String,
    val password: String
)

@Serializable
data class RegisterRequest(
    val name: String,
    val email: String,
    val password: String
)

// commonMain/kotlin/com/example/shared/model/auth/AuthResponses.kt
@Serializable
data class AuthResponse(
    val user: User,
    val accessToken: String,
    val refreshToken: String,
    val expiresAt: Instant
)

@Serializable
data class RefreshTokenRequest(
    val refreshToken: String
)
```

## Validation

### Inline Validation

Wrap single-field types in `@JvmInline value class`, not `data class`: a value class encodes as the bare underlying primitive (`"a@b.com"`), while a data class encodes as an object (`{"value":"a@b.com"}`) and allocates. Value classes may declare `init` blocks.

```kotlin
// commonMain/kotlin/com/example/shared/model/Validation.kt
import kotlin.jvm.JvmInline

@Serializable
@JvmInline
value class Email(val value: String) {
    init {
        require(EMAIL_REGEX.matches(value)) { "Invalid email format: $value" }
    }

    companion object {
        private val EMAIL_REGEX = Regex("""^[^@\s]+@[^@\s]+\.[^@\s]+$""")
        fun orNull(value: String?): Email? =
            value?.takeIf { EMAIL_REGEX.matches(it) }?.let(::Email)
    }
}

@Serializable
@JvmInline
value class PhoneNumber(val value: String) {
    init {
        require(value.matches(Regex("^\\+?[1-9]\\d{1,14}$"))) {
            "Invalid phone number format"
        }
    }
}
```

The plugin runs `init` blocks after decoding, so these checks also reject bad server payloads — but they throw `IllegalArgumentException`, not `SerializationException`. Catch both at the decode boundary, or keep `require` for internal invariants and validate untrusted input explicitly with the result type below.

### Validation Result

```kotlin
// commonMain/kotlin/com/example/shared/model/ValidationError.kt
@Serializable
data class ValidationError(
    val field: String,
    val message: String
)

// Derive validity instead of storing it — a stored flag can contradict the list
// and would be serialized as a redundant field.
@Serializable
data class ValidationResult(val errors: List<ValidationError> = emptyList()) {
    val isValid: Boolean get() = errors.isEmpty()

    companion object {
        val Valid = ValidationResult()
    }
}

// Usage in models
@Serializable
data class CreateUserRequest(
    val name: String,
    val email: String,
    val age: Int?
) {
    fun validate(): ValidationResult {
        val errors = buildList {
            if (name.isBlank()) {
                add(ValidationError("name", "Name is required"))
            }
            if (email.isBlank() || !email.contains("@")) {
                add(ValidationError("email", "Invalid email"))
            }
            if (age != null && age < 0) {
                add(ValidationError("age", "Age cannot be negative"))
            }
        }
        return if (errors.isEmpty()) ValidationResult.Valid else ValidationResult(errors)
    }
}
```

## Platform-Specific Fields

### Using Serial Names

```kotlin
// commonMain/kotlin/com/example/shared/model/PlatformData.kt
@Serializable
data class PlatformData(
    val platform: Platform,
    val deviceInfo: DeviceInfo
)

// Enums serialize without @Serializable; annotate only to apply @SerialName to entries.
@Serializable
enum class Platform {
    @SerialName("android") ANDROID,
    @SerialName("ios") IOS,
    @SerialName("desktop") DESKTOP,
    @SerialName("web") WEB
}

@Serializable
data class DeviceInfo(
    val model: String,
    val osVersion: String,
    val appVersion: String,
    // Platform-specific optional fields
    val pushToken: String? = null,
    val advertisingId: String? = null
)
```

### Custom Serializers

Since kotlinx-serialization 1.9.0, `kotlin.time.Instant` serializes out of the box as an ISO-8601 string, and `kotlinx.serialization.builtins.InstantComponentSerializer` encodes it as `{epochSeconds, nanosecondsOfSecond}`. Write your own only for a wire format neither covers (e.g. epoch millis):

```kotlin
// commonMain/kotlin/com/example/shared/model/InstantSerializer.kt
import kotlin.time.Instant   // moved from kotlinx.datetime in datetime 0.7

object InstantSerializer : KSerializer<Instant> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("Instant", PrimitiveKind.LONG)

    override fun serialize(encoder: Encoder, value: Instant) {
        encoder.encodeLong(value.toEpochMilliseconds())
    }

    override fun deserialize(decoder: Decoder): Instant {
        return Instant.fromEpochMilliseconds(decoder.decodeLong())
    }
}

@Serializable
data class Event(
    val id: String,
    @Serializable(with = InstantSerializer::class)
    val timestamp: Instant
)
```

## JSON Configuration

```kotlin
// commonMain/kotlin/com/example/shared/serialization/JsonFactory.kt
object JsonFactory {
    val Default = Json {
        ignoreUnknownKeys = true   // survive new server fields; default false
        encodeDefaults = false     // omit properties equal to their default (already the default)
        coerceInputValues = true   // null/unknown-enum -> the property's default, which it must have
        explicitNulls = false      // omit nulls on encode; absent keys decode to null/default
    }

    // Pretty printing for debug/logs
    val Pretty = Json(Default) { prettyPrint = true; prettyPrintIndent = "  " }
}
```

Notes:
- `Json { }` with no options is already strict (`ignoreUnknownKeys`, `isLenient`, `coerceInputValues`, `encodeDefaults` all `false`), so a "Strict" instance built by setting them to `false` is just `Json.Default` — use `Json` directly.
- Avoid `isLenient = true` on a real API client: it accepts unquoted keys and strings and hides malformed payloads. Turn it on only for hand-written fixtures.
- `coerceInputValues` only coerces when the property has a default value; without one the decode still fails.
- `prettyPrintIndent`, `allowTrailingComma`, `allowComments` and `decodeEnumsCaseInsensitive` became stable in kotlinx-serialization 1.10.0 — no `@OptIn` needed.
- Reuse one `Json` instance (it caches serializers); constructing `Json { }` per call is a measurable cost.

## File Organization

```
shared/src/commonMain/kotlin/com/example/shared/
├── model/
│   ├── User.kt
│   ├── Item.kt
│   ├── Pagination.kt
│   ├── UiState.kt
│   └── Result.kt
├── model/auth/
│   ├── AuthRequests.kt
│   ├── AuthResponses.kt
│   └── UserProfile.kt
├── serialization/
│   ├── JsonFactory.kt
│   └── InstantSerializer.kt
└── validation/
    ├── ValidationResult.kt
    └── Validators.kt
```

## Best practices

**Do:** immutable `data class`es (`val`) · `sealed` classes for fixed type sets · default values for optional fields · `@JvmInline value class` for typed IDs · group related models in packages.

**Don't:** use platform-specific types (use `Instant`/`LocalDateTime`, not `Date`/`NSDate`) · use `Double`/`Float` for monetary amounts (see `kmp-money`) · embed heavy business logic in models · make everything nullable · use `var` in data classes.

**Swift consumers:** nested subclasses flatten in the generated Obj-C header (`UiState.Success` → `UiStateSuccess`), and `sealed` gives Swift no exhaustive `switch` — the compiler still demands a `default` branch. Keep hierarchies shallow, or expose a mapped enum at the boundary; see `kmp-ios-integration`.

## Testing

```kotlin
// commonTest/kotlin/ModelTest.kt
// Note: backtick names with spaces only compile on JVM/Android;
// use camelCase in commonTest so iOS/JS targets build.
import kotlin.time.Clock

class ModelTest {
    @Test
    fun serializeAndDeserializeUser() {
        val user = User(
            id = "123",
            name = "John Doe",
            email = "john@example.com",
            avatarUrl = null,
            createdAt = Clock.System.now(),
            lastActiveAt = null
        )

        val json = JsonFactory.Default.encodeToString(user)
        val restored = JsonFactory.Default.decodeFromString<User>(json)

        assertEquals(user, restored)
    }

    @Test
    fun validationCatchesInvalidEmail() {
        val result = CreateUserRequest(
            name = "John",
            email = "not-an-email",
            age = null
        ).validate()

        assertFalse(result.isValid)
        assertTrue(result.errors.any { it.field == "email" })
    }
}
```
