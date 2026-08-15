---
name: kmp-networking
description: Ktor HTTP client for Kotlin Multiplatform - shared API layer in commonMain with per-target engines (OkHttp/Android engine on Android, Darwin on iOS), kotlinx.serialization, and shared error handling. Use for multiplatform or shared networking. For an Android-only Ktor/OkHttp client use ktor-patterns. For deeper, source-backed Ktor in KMP (per-platform engines, MockEngine testing, bearer-token refresh, error mapping) prefer android-skills:kmp-ktor.
---

# KMP Networking with Ktor

Configure Ktor client for cross-platform networking with platform-optimized engines.

> **TLS/certificate pinning** (MITM hardening) is a separate concern applied per engine — see `kmp-tls-pinning` (OkHttp `CertificatePinner` on Android + Darwin `handleChallenge` on iOS via expect/actual).

## Dependencies

```kotlin
// build.gradle.kts (shared module)
plugins {
    kotlin("multiplatform")
    kotlin("plugin.serialization")
}

val ktor = "3.5.0"   // current 3.x — verify latest at ktor.io/docs/releases

kotlin {
    sourceSets {
        val commonMain by getting {
            dependencies {
                implementation("io.ktor:ktor-client-core:$ktor")
                implementation("io.ktor:ktor-client-content-negotiation:$ktor")
                implementation("io.ktor:ktor-serialization-kotlinx-json:$ktor")
                implementation("io.ktor:ktor-client-logging:$ktor")
                implementation("io.ktor:ktor-client-auth:$ktor")            // bearer-token Auth plugin
                implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0")
            }
        }
        val androidMain by getting {
            dependencies {
                implementation("io.ktor:ktor-client-okhttp:$ktor")
            }
        }
        val iosMain by getting {
            dependencies {
                implementation("io.ktor:ktor-client-darwin:$ktor")
            }
        }
    }
}
```

## HttpClient Factory

```kotlin
// commonMain/kotlin/network/HttpClientFactory.kt
object HttpClientFactory {
    fun create(
        platform: Platform,
        isDebug: Boolean = false
    ): HttpClient {
        return HttpClient(platformEngine()) {      // engine factory chosen per platform (expect/actual)
            install(HttpTimeout) {                 // cross-platform timeouts (no engine-specific config needed)
                requestTimeoutMillis = 30_000
                connectTimeoutMillis = 30_000
            }
            install(ContentNegotiation) {
                json(Json {
                    ignoreUnknownKeys = true
                    isLenient = true
                    encodeDefaults = false
                })
            }

            if (isDebug) {
                install(Logging) {
                    level = LogLevel.INFO
                    logger = object : Logger {
                        override fun log(message: String) {
                            println("Ktor: $message")
                        }
                    }
                }
            }

            install(Auth) {
                bearer {
                    loadTokens {
                        // Access Token from secure storage
                        BearerTokens(
                            accessTokenStorage.get() ?: "",
                            refreshTokenStorage.get() ?: ""
                        )
                    }
                    refreshTokens {
                        // Refresh token logic
                        val newTokens = authApi.refreshToken()
                        accessTokenStorage.save(newTokens.accessToken)
                        refreshTokenStorage.save(newTokens.refreshToken)
                        BearerTokens(newTokens.accessToken, newTokens.refreshToken)
                    }
                }
            }

            defaultRequest {
                url {
                    protocol = URLProtocol.HTTPS
                    host = "api.example.com"
                }
                header("X-API-Version", "1.0")
                header("X-Platform", platform.name)
            }

            expectSuccess = true
            HttpResponseValidator {
                handleResponseExceptionWithRequest { exception, request ->
                    when (exception) {
                        is ClientRequestException -> {
                            val statusCode = exception.response.status.value
                            when (statusCode) {
                                401 -> throw UnauthorizedException()
                                403 -> throw ForbiddenException()
                                404 -> throw NotFoundException()
                                in 500..599 -> throw ServerException()
                            }
                        }
                        is ServerResponseException -> throw ServerException()
                    }
                }
            }

            install(ResponseObserver) {
                onResponse { response ->
                    // Track response times, errors
                }
            }
        }
    }

}

// commonMain — the engine factory is provided per platform via expect/actual:
expect fun platformEngine(): HttpClientEngineFactory<*>
```

## Platform-Specific Engines

The engine factory objects are `OkHttp` (from `ktor-client-okhttp`) and `Darwin` (from `ktor-client-darwin`). Return them from the `platformEngine()` actuals:

### Android (OkHttp)

```kotlin
// androidMain/kotlin/network/PlatformEngine.android.kt
actual fun platformEngine(): HttpClientEngineFactory<*> = OkHttp

// Engine-specific tuning (interceptors, OkHttp cache) goes in an engine { } block
// when you build the client in platform code, e.g.:
// HttpClient(OkHttp) {
//     engine {
//         config { retryOnConnectionFailure(true) }
//         addInterceptor(userAgentInterceptor)
//     }
// }
```

### iOS (Darwin)

```kotlin
// iosMain/kotlin/network/PlatformEngine.ios.kt
actual fun platformEngine(): HttpClientEngineFactory<*> = Darwin

// Darwin (NSURLSession) tuning via engine { }:
// HttpClient(Darwin) {
//     engine {
//         configureRequest { setAllowsCellularAccess(true) }
//         configureSession { setHTTPMaximumConnectionsPerHost(5u) }
//     }
// }
```

## API Service Pattern

```kotlin
// commonMain/kotlin/network/api/UserApi.kt
class UserApi(
    private val client: HttpClient
) {
    suspend fun getUsers(page: Int = 1): PaginatedResponse<User> {
        return client.get("/users") {
            parameter("page", page)
            parameter("limit", 20)
        }.body()
    }

    suspend fun getUser(id: String): User {
        return client.get("/users/$id").body()
    }

    suspend fun createUser(request: CreateUserRequest): User {
        return client.post("/users") {
            setBody(request)
            contentType(ContentType.Application.Json)
        }.body()
    }

    suspend fun updateUser(id: String, request: UpdateUserRequest): User {
        return client.put("/users/$id") {
            setBody(request)
            contentType(ContentType.Application.Json)
        }.body()
    }

    suspend fun deleteUser(id: String) {
        client.delete("/users/$id")
    }

    suspend fun uploadAvatar(userId: String, file: ByteArray): String {
        return client.submitFormWithBinaryData(
            url = "https://api.example.com/users/$userId/avatar",
            formData = formData {
                append("avatar", file, Headers.build {
                    append(HttpHeaders.ContentDisposition, "filename=avatar.jpg")
                })
            }
        ).body()
    }
}
```

## Network Exceptions

```kotlin
// commonMain/kotlin/network/NetworkExceptions.kt
sealed class NetworkException(message: String? = null) : Exception(message)

class UnauthorizedException : NetworkException("User not authenticated")
class ForbiddenException : NetworkException("Access forbidden")
class NotFoundException : NetworkException("Resource not found")
class ServerException : NetworkException("Server error occurred")
class NetworkUnavailableException : NetworkException("Network unavailable")
class TimeoutException : NetworkException("Request timeout")

// Wrap Ktor exceptions
fun Throwable.toNetworkException(): NetworkException {
    return when (this) {
        is NetworkException -> this
        is ClientRequestException -> when (response.status.value) {
            401 -> UnauthorizedException()
            403 -> ForbiddenException()
            404 -> NotFoundException()
            else -> NetworkException(message)
        }
        is ServerResponseException -> ServerException()
        is HttpRequestTimeoutException -> TimeoutException()
        is ConnectTimeoutException,
        is SocketTimeoutException -> NetworkUnavailableException()
        else -> NetworkException(message ?: "Unknown network error")
    }
}
```

## Result Wrapper

```kotlin
// commonMain/kotlin/network/ApiResult.kt
sealed class ApiResult<out T> {
    data class Success<T>(val data: T) : ApiResult<T>()
    data class Error(val error: NetworkException) : ApiResult<Nothing>()

    suspend fun <R> map(transform: (T) -> R): ApiResult<R> = when (this) {
        is Success -> Success(transform(data))
        is Error -> this
    }

    suspend fun <R> flatMap(transform: (T) -> ApiResult<R>): ApiResult<R> = when (this) {
        is Success -> transform(data)
        is Error -> this
    }

    fun getOrNull(): T? = when (this) {
        is Success -> data
        is Error -> null
    }

    fun getOrElse(defaultValue: T): T = when (this) {
        is Success -> data
        is Error -> defaultValue
    }
}

suspend fun <T> apiCall(block: suspend () -> T): ApiResult<T> = try {
    ApiResult.Success(block())
} catch (e: Exception) {
    ApiResult.Error(e.toNetworkException())
}

// Usage
val result: ApiResult<User> = apiCall { userApi.getUser("123") }
when (result) {
    is ApiResult.Success -> showUser(result.data)
    is ApiResult.Error -> showError(result.error)
}
```

## Retry Logic

```kotlin
// commonMain/kotlin/network/Retry.kt
suspend fun <T> retryApiCall(
    maxRetries: Int = 3,
    delayMs: Long = 1000,
    block: suspend () -> T
): T {
    var lastException: Exception? = null
    repeat(maxRetries) { attempt ->
        try {
            return block()
        } catch (e: Exception) {
            lastException = e
            if (e is NetworkUnavailableException || e is TimeoutException) {
                if (attempt < maxRetries - 1) {
                    delay(delayMs * (attempt + 1))
                }
            } else {
                throw e
            }
        }
    }
    throw lastException ?: RuntimeException("Max retries exceeded")
}
```

## Offline Support

```kotlin
// commonMain/kotlin/network/OfflineCapableApi.kt
import kotlin.time.Clock   // moved from kotlinx.datetime.Clock in datetime 0.7

class CachingApi(private val cache: DatabaseCache) {

    suspend fun <R> withCache(
        key: String,
        ttl: Duration,
        block: suspend () -> R
    ): R = withContext(Dispatchers.IO) {
        // Serve fresh cache while within TTL (Instant + Duration = Instant)
        cache.get<R>(key)?.let { cached ->
            if (Clock.System.now() < cached.timestamp + ttl) {
                return@withContext cached.data
            }
        }

        // Otherwise fetch, refresh the cache, and fall back to stale data on failure
        try {
            val result = block()
            cache.put(key, CachedData(result, Clock.System.now()))
            result
        } catch (e: NetworkException) {
            cache.get<R>(key)?.data ?: throw e
        }
    }
}
```

## Dependency Injection Setup

```kotlin
// commonMain/kotlin/di/NetworkModule.kt
val networkModule = module {
    single { HttpClientFactory.create(get(), get()) }
    single { UserApi(get()) }
    single { AuthApi(get()) }
    factory { ConnectivityMonitor(get()) }
}
```

## Best practices

**Do:** typed API services per resource · wrap calls in a result type (`ApiResult`) · set timeouts via the `HttpTimeout` plugin · install `Logging` only on debug builds · catch `NetworkException` at boundaries.

**Don't:** create multiple `HttpClient` instances (use one via DI) · `runBlocking` on suspend calls · swallow exceptions with an empty catch · hardcode URLs (set the base URL in `defaultRequest`).
