---
name: ktor-patterns
description: Ktor HTTP client for an Android-only app - OkHttp/Android engine setup, ContentNegotiation with kotlinx.serialization, plugins/interceptors, and error handling on a single platform. For shared/multiplatform networking (commonMain, Darwin engine on iOS) use kmp-networking. For deeper, source-backed Ktor coverage (HttpClient config, MockEngine testing, bearer-token refresh, error mapping) prefer android-skills:kmp-ktor.
---

# Ktor Client Patterns

Modern HTTP client for Kotlin.

## Dependencies

```kotlin
val ktor = "3.5.0"   // current 3.x — verify latest at ktor.io/docs/releases
dependencies {
    implementation("io.ktor:ktor-client-core:$ktor")
    implementation("io.ktor:ktor-client-okhttp:$ktor")
    implementation("io.ktor:ktor-client-content-negotiation:$ktor")
    implementation("io.ktor:ktor-serialization-kotlinx-json:$ktor")
    implementation("io.ktor:ktor-client-logging:$ktor")   // Logger.ANDROID + Logging plugin
    implementation("io.ktor:ktor-client-auth:$ktor")       // bearer-token Auth plugin
}
```

## Client Setup

```kotlin
val httpClient = HttpClient(OkHttp) {
    // JSON serialization
    install(ContentNegotiation) {
        json(Json {
            ignoreUnknownKeys = true
            isLenient = true
            prettyPrint = false
        })
    }
    
    // Timeouts
    install(HttpTimeout) {
        requestTimeoutMillis = 30_000
        connectTimeoutMillis = 10_000
        socketTimeoutMillis = 30_000
    }
    
    // Logging (debug only)
    install(Logging) {
        logger = Logger.ANDROID
        level = if (BuildConfig.DEBUG) LogLevel.BODY else LogLevel.NONE
    }
    
    // Default request config
    defaultRequest {
        url("https://api.example.com")
        contentType(ContentType.Application.Json)
    }
    
    // Auth
    install(Auth) {
        bearer {
            loadTokens {
                BearerTokens(tokenStorage.accessToken, tokenStorage.refreshToken)
            }
            refreshTokens {
                val tokens: TokenResponse = client.post("auth/refresh") {
                    markAsRefreshTokenRequest()                       // don't recurse into Auth
                    setBody(RefreshRequest(oldTokens?.refreshToken.orEmpty()))
                }.body()                                              // read the body exactly once
                tokenStorage.save(tokens)
                BearerTokens(tokens.accessToken, tokens.refreshToken)
            }
        }
    }
}
```

## API Definition

```kotlin
class UserApi(private val client: HttpClient) {
    
    suspend fun getUsers(): List<UserDto> {
        return client.get("users").body()
    }
    
    suspend fun getUser(id: String): UserDto {
        return client.get("users/$id").body()
    }
    
    suspend fun createUser(request: CreateUserRequest): UserDto {
        return client.post("users") {
            setBody(request)
        }.body()
    }
    
    suspend fun updateUser(id: String, request: UpdateUserRequest): UserDto {
        return client.put("users/$id") {
            setBody(request)
        }.body()
    }
    
    suspend fun deleteUser(id: String) {
        client.delete("users/$id")
    }
}
```

## Error Handling

```kotlin
class ApiException(
    val statusCode: Int,
    override val message: String
) : Exception(message)

suspend inline fun <reified T> HttpClient.safeRequest(
    block: HttpRequestBuilder.() -> Unit
): Result<T> = runCatching {
    val response = request(block)
    
    if (response.status.isSuccess()) {
        response.body<T>()
    } else {
        throw ApiException(
            statusCode = response.status.value,
            message = response.bodyAsText()
        )
    }
}

// Usage
class UserRepository(private val api: UserApi, private val client: HttpClient) {
    suspend fun getUser(id: String): Result<User> {
        return client.safeRequest<UserDto> {
            url("users/$id")
            method = HttpMethod.Get
        }.map { it.toDomain() }
    }
}
```

## DTOs and Mapping

```kotlin
import kotlin.time.Instant   // moved from kotlinx.datetime in datetime 0.7

@Serializable
data class UserDto(
    val id: String,
    val email: String,
    @SerialName("first_name")
    val firstName: String,
    @SerialName("created_at")
    val createdAt: String
)

fun UserDto.toDomain(): User = User(
    id = id,
    email = email,
    name = firstName,
    createdAt = Instant.parse(createdAt)
)
```

## Interceptors

```kotlin
val client = HttpClient(OkHttp) {
    // Request interceptor
    install(HttpSend) {
        intercept { request ->
            request.headers.append("X-Client-Version", BuildConfig.VERSION_NAME)
            execute(request)
        }
    }
}
```

## Certificate Pinning

```kotlin
val client = HttpClient(OkHttp) {
    engine {
        config {
            certificatePinner(
                CertificatePinner.Builder()
                    .add("api.example.com", "sha256/AAAA...")
                    .add("api.example.com", "sha256/BBBB...")  // Backup pin
                    .build()
            )
        }
    }
}
```
