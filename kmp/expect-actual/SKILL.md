---
name: expect-actual
description: Kotlin Multiplatform expect/actual quick patterns - declaring shared APIs with platform implementations. For deeper, source-backed KMP boundary design (expect/actual vs common interfaces, platform services like clipboard/share/haptics/permissions/biometrics, source-set hierarchies, CMP interop) prefer android-skills:kmp-boundaries.
---

# expect/actual Pattern for KMP

The `expect/actual` declaration is Kotlin's mechanism for writing platform-specific implementations while maintaining a shared API surface.

## Core Concept

```kotlin
// shared/commonMain/kotlin/Platform.kt
expect class Platform() {
    val name: String
}

// shared/androidMain/kotlin/Platform.android.kt
actual class Platform {
    actual val name: String = "Android ${Build.VERSION.SDK_INT}"
}

// shared/iosMain/kotlin/Platform.ios.kt
actual class Platform {
    actual val name: String = "iOS ${UIDevice.currentDevice.systemVersion}"
}
```

> **Beta note:** expect/actual *classes* (and objects/interfaces/enums/actual typealiases) are still Beta in Kotlin 2.x — the compiler warns unless you add `freeCompilerArgs.add("-Xexpect-actual-classes")`. Expect functions and properties are stable. For anything beyond a thin platform shim, prefer a common interface + `expect` factory function; see android-skills:kmp-boundaries for choosing the boundary shape.

## Common Patterns

### 1. Platform Information

```kotlin
// commonMain — a singleton, so `expect object`; named PlatformInfo because
// the `expect class Platform()` above already occupies that name in the package
expect object PlatformInfo {
    val name: String
    val version: String
    val isDebug: Boolean
}

// androidMain
actual object PlatformInfo {
    actual val name: String = "Android"
    actual val version: String = "${Build.VERSION.SDK_INT}"
    // BuildConfig needs buildFeatures.buildConfig = true (off by default in AGP 8+;
    // not generated at all by the AGP KMP library plugin)
    actual val isDebug: Boolean = BuildConfig.DEBUG
}

// iosMain
// kotlin.native.Platform is annotated @ExperimentalNativeApi (whole object)
@OptIn(kotlin.experimental.ExperimentalNativeApi::class)
actual object PlatformInfo {
    actual val name: String = "iOS"
    actual val version: String = UIDevice.currentDevice.systemVersion
    actual val isDebug: Boolean = kotlin.native.Platform.isDebugBinary
}
```

### 2. File System Paths

```kotlin
// commonMain
expect class FileSystem {
    fun getDocumentsPath(): String
    fun getCachePath(): String
    fun getTempPath(): String
}

// androidMain — actuals may add constructors the expect doesn't declare;
// construct per platform and inject (e.g. via Koin)
actual class FileSystem(private val context: Context) {
    actual fun getDocumentsPath(): String {
        return context.filesDir.absolutePath
    }
    actual fun getCachePath(): String {
        return context.cacheDir.absolutePath
    }
    actual fun getTempPath(): String {
        return context.cacheDir.absolutePath + "/tmp"
    }
}

// iosMain
actual class FileSystem {
    actual fun getDocumentsPath(): String {
        return NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory,
            NSUserDomainMask,
            true
        ).first() as String
    }
    actual fun getCachePath(): String {
        return NSSearchPathForDirectoriesInDomains(
            NSCachesDirectory,
            NSUserDomainMask,
            true
        ).first() as String
    }
    actual fun getTempPath(): String {
        return NSTemporaryDirectory()
    }
}
```

### 3. Date/Time Operations

Prefer kotlinx-datetime in commonMain (`kotlin.time.Instant`, `LocalDateTime.Format` — no expect/actual needed). Use expect/actual only for locale-aware platform formatting:

```kotlin
// commonMain — declare the () constructor: expect classes have no implicit
// constructor, and without one common code cannot instantiate the class
expect class DateTimeFormatter() {
    fun format(timestamp: Long): String
    fun parse(dateString: String): Long
    fun now(): Long
}

// androidMain
actual class DateTimeFormatter {
    // SimpleDateFormat is not thread-safe — keep the instance confined
    private val format = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.getDefault())

    actual fun format(timestamp: Long): String {
        return format.format(Date(timestamp))
    }

    actual fun parse(dateString: String): Long {
        // DateFormat.parse(String) throws ParseException on bad input (never returns null)
        return runCatching { format.parse(dateString)?.time }.getOrNull() ?: 0L
    }

    actual fun now(): Long = System.currentTimeMillis()
}

// iosMain
actual class DateTimeFormatter {
    private val formatter = NSDateFormatter().apply {
        dateFormat = "yyyy-MM-dd HH:mm:ss"
    }

    actual fun format(timestamp: Long): String {
        val date = NSDate(timeIntervalSince1970 = timestamp / 1000.0)
        return formatter.stringFromDate(date)
    }

    actual fun parse(dateString: String): Long {
        val date = formatter.dateFromString(dateString) ?: return 0L
        return (date.timeIntervalSince1970 * 1000).toLong()
    }

    actual fun now(): Long = (NSDate().timeIntervalSince1970 * 1000).toLong()
}
```

### 4. Database Paths

```kotlin
// commonMain
expect class DatabasePathProvider {
    fun getDatabasePath(name: String): String
}

// androidMain
actual class DatabasePathProvider(private val context: Context) {
    actual fun getDatabasePath(name: String): String {
        return context.getDatabasePath(name).absolutePath
    }
}

// iosMain
actual class DatabasePathProvider {
    actual fun getDatabasePath(name: String): String {
        val dir = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory,
            NSUserDomainMask,
            true
        ).first() as String
        return "$dir/databases/$name"
    }
}
```

### 5. Secure Storage

```kotlin
// commonMain
expect class SecureStorage {
    suspend fun save(key: String, value: String)
    suspend fun load(key: String): String?
    suspend fun delete(key: String)
}

// androidMain
// ⚠️ DEPRECATED: androidx.security:security-crypto was deprecated wholesale in
// 1.1.0-alpha07 (April 2025) — MasterKey, EncryptedSharedPreferences AND
// EncryptedFile. Prefer Android Keystore-backed encryption: generate an AES-GCM key
// via KeyGenParameterSpec (setUserAuthenticationRequired(true) to biometric-gate
// sensitive secrets) and store the ciphertext in plain DataStore, or encrypt with
// Tink. Snippet kept as a legacy reference only. See the mobile-security skill.
actual class SecureStorage(private val context: Context) {
    private val masterKey = MasterKey.Builder(context)
        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
        .build()

    private val prefs = EncryptedSharedPreferences.create(
        context,
        "secure",
        masterKey,
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
    )

    actual suspend fun save(key: String, value: String) {
        prefs.edit().putString(key, value).apply()
    }

    actual suspend fun load(key: String): String? = prefs.getString(key, null)

    actual suspend fun delete(key: String) {
        prefs.edit().remove(key).apply()
    }
}

// iosMain
actual class SecureStorage {
    // KeychainHelper = your wrapper over the Security framework
    // (SecItemAdd/SecItemCopyMatching with kSecClassGenericPassword)
    private val keychain = KeychainHelper()

    actual suspend fun save(key: String, value: String) {
        keychain.set(key, value)
    }

    actual suspend fun load(key: String): String? {
        return keychain.get(key)
    }

    actual suspend fun delete(key: String) {
        keychain.delete(key)
    }
}
```

### 6. Network Connectivity

```kotlin
// commonMain
expect class ConnectivityMonitor {
    val isOnline: StateFlow<Boolean>   // actuals expose StateFlow, so the expect must match
    fun startMonitoring()
    fun stopMonitoring()
}

// androidMain
actual class ConnectivityMonitor(private val context: Context) {
    private val _isOnline = MutableStateFlow(true)
    actual val isOnline: StateFlow<Boolean> = _isOnline.asStateFlow()

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            _isOnline.value = true
        }
        override fun onLost(network: Network) {
            _isOnline.value = false
        }
    }

    actual fun startMonitoring() {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        // Track the default network. registerNetworkCallback with an empty
        // NetworkRequest fires onLost per network — dropping Wi-Fi while
        // cellular is still up would falsely report offline.
        cm.registerDefaultNetworkCallback(callback)
    }

    actual fun stopMonitoring() {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        cm.unregisterNetworkCallback(callback)
    }
}

// iosMain — the Swift NWPathMonitor class is not exposed to Kotlin/Native;
// use the Network.framework C API from platform.Network + platform.darwin.
// Those are cinterop declarations, and the ExperimentalForeignApi opt-in is
// error-level — without it the file does not compile. (platform.Foundation
// and platform.UIKit, used above, are exempt.)
@OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)
actual class ConnectivityMonitor {
    private val _isOnline = MutableStateFlow(true)
    actual val isOnline: StateFlow<Boolean> = _isOnline.asStateFlow()

    private val monitor = nw_path_monitor_create()
    private val queue = dispatch_queue_create("network.monitor", null)

    actual fun startMonitoring() {
        nw_path_monitor_set_update_handler(monitor) { path ->
            _isOnline.value = nw_path_get_status(path) == nw_path_status_satisfied
        }
        nw_path_monitor_set_queue(monitor, queue)
        nw_path_monitor_start(monitor)
    }

    actual fun stopMonitoring() {
        nw_path_monitor_cancel(monitor)
    }
}
```

### 7. Logging

```kotlin
// commonMain
enum class LogLevel { DEBUG, INFO, WARN, ERROR }

expect class Logger() {
    fun log(level: LogLevel, tag: String, message: String, throwable: Throwable?)
}

// androidMain
actual class Logger {
    actual fun log(level: LogLevel, tag: String, message: String, throwable: Throwable?) {
        when (level) {
            LogLevel.DEBUG -> Log.d(tag, message, throwable)
            LogLevel.INFO -> Log.i(tag, message, throwable)
            LogLevel.WARN -> Log.w(tag, message, throwable)
            LogLevel.ERROR -> Log.e(tag, message, throwable)
        }
    }
}

// iosMain
actual class Logger {
    actual fun log(level: LogLevel, tag: String, message: String, throwable: Throwable?) {
        val fullMessage = if (throwable != null) "$message: $throwable" else message
        // NSLog is simple and available in Kotlin/Native.
        // For structured OSLog/Crashlytics, prefer Kermit (see kmp-logging).
        NSLog("[%@] [%@] %@", tag, level.name, fullMessage)
    }
}
```

## Best practices

**Do:** keep `expect` declarations simple (no bodies) · use factory functions for platform dependencies · group related functionality into one `expect` class · declare default parameter values on the `expect` side (actuals must not repeat them).

**Don't:** put complex logic in an `expect` declaration (won't compile) · use expect/actual for pure-Kotlin logic (put it in commonMain) · create many tiny `expect` classes (consolidate into one service).

## File Organization

```
shared/
├── commonMain/
│   └── kotlin/
│       └── com/example/platform/
│           ├── Platform.kt          (expect class Platform)
│           ├── FileSystem.kt        (expect class FileSystem)
│           └── DatabasePath.kt      (expect class DatabasePathProvider)
├── androidMain/
│   └── kotlin/
│       └── com/example/platform/
│           ├── Platform.android.kt  (actual class Platform)
│           ├── FileSystem.android.kt
│           └── DatabasePath.android.kt
├── iosMain/
│   └── kotlin/
│       └── com/example/platform/
│           ├── Platform.ios.kt      (actual class Platform)
│           ├── FileSystem.ios.kt
│           └── DatabasePath.ios.kt
└── desktopMain/
    └── kotlin/
        └── com/example/platform/
            ├── Platform.desktop.kt
            └── FileSystem.desktop.kt
```

## Testing with expect/actual

```kotlin
// commonTest — camelCase names: backticked names with spaces
// are not portable to all targets
class PlatformTest {
    @Test
    fun platformNameIsNotEmpty() {
        assertTrue(PlatformInfo.name.isNotEmpty())
    }
}

// Test runs on all platforms with actual implementations
```
