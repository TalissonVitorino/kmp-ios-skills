---
name: mobile-security
description: Android security patterns for secure storage (Keystore-backed encryption; note EncryptedSharedPreferences is deprecated), network security config, input validation, biometrics, and certificate pinning. Android/KMP-side security baseline. For app/device integrity + root detection use `android-device-integrity`; for session auto-lock + screen-capture protection use `mobile-session-security`; for shared-Ktor TLS pinning use `kmp-tls-pinning`; the iOS counterpart is `swift-security`.
---

# Mobile Security Patterns

Security best practices for Android.

## Secure Storage

### EncryptedSharedPreferences is dead — use Keystore directly

> ⚠️ **Deprecated.** Jetpack Security Crypto (`androidx.security:security-crypto`) — `EncryptedSharedPreferences`, `EncryptedFile`, `MasterKey` — was deprecated in 1.1.0-alpha07 (April 2025) "in favour of existing platform APIs and direct use of Android Keystore"; 1.1.0 stable (July 30, 2025) ships with the deprecation in place and no successor artifact is planned. **Do not build new secure storage on it.** Current approach: encrypt with an Android Keystore key and persist only `IV || ciphertext` in plain `DataStore`/`SharedPreferences`. Google's Tink is the maintained library if you need envelope encryption, key rotation, or deterministic AEAD.

Exclude the ciphertext store from backup/transfer as well — a Keystore key never leaves the device, so a restored blob is undecryptable garbage, and a restored *plaintext* pref is a leak:

```xml
<!-- targetSdk 31+ uses dataExtractionRules; allowBackup still governs pre-31 cloud backup.
     Note: on some OEMs allowBackup="false" does not disable device-to-device transfer,
     so also add explicit <exclude> rules in the rules file. -->
<application
    android:allowBackup="false"
    android:dataExtractionRules="@xml/data_extraction_rules">
```

### Android Keystore

```kotlin
// Generate key in Keystore
fun generateSecretKey(alias: String) {
    val keyGenerator = KeyGenerator.getInstance(
        KeyProperties.KEY_ALGORITHM_AES,
        "AndroidKeyStore"
    )
    
    keyGenerator.init(
        KeyGenParameterSpec.Builder(alias,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)  // AndroidKeyStore's AES default is 128 - always state 256
            .setUserAuthenticationRequired(true)
            // API 30+. timeout = 0 -> auth-per-use: the key unlocks only through a
            // BiometricPrompt CryptoObject (see Biometric section below).
            // timeout > 0 -> key usable for N seconds after any auth; no CryptoObject needed.
            .setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
            .setUnlockedDeviceRequired(true)  // API 28+: unusable while the screen is locked
            // New biometric enrollments invalidate the key by default
            // (setInvalidatedByBiometricEnrollment(true)) - catch KeyPermanentlyInvalidatedException
            // on Cipher.init, delete the alias, and force a full re-login.
            .build()
    )
    
    keyGenerator.generateKey()
}
```

`setIsStrongBoxBacked(true)` (API 28+) moves the key into the secure element; gate it on
`PackageManager.FEATURE_STRONGBOX_KEYSTORE` and retry without it on `StrongBoxUnavailableException`.

Encrypt/decrypt round-trip. `setRandomizedEncryptionRequired` defaults to **true**, so the Keystore
generates the GCM IV — passing your own on encrypt throws. Persist it alongside the ciphertext.
These helpers assume a key generated *without* `setUserAuthenticationRequired`; with the auth-per-use
key above `Cipher.init` succeeds but `doFinal` throws `UserNotAuthenticatedException` — that `Cipher`
must be handed to `BiometricPrompt.CryptoObject` first (see Biometric section):

```kotlin
private fun secretKey(alias: String): SecretKey =
    (KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        .getEntry(alias, null) as KeyStore.SecretKeyEntry).secretKey

private const val IV_LEN = 12  // GCM standard nonce

fun encrypt(alias: String, plaintext: ByteArray): ByteArray =
    Cipher.getInstance("AES/GCM/NoPadding").run {
        init(Cipher.ENCRYPT_MODE, secretKey(alias))
        iv + doFinal(plaintext)  // IV || ciphertext+tag; Base64 this into DataStore
    }

fun decrypt(alias: String, blob: ByteArray): ByteArray =
    Cipher.getInstance("AES/GCM/NoPadding").run {
        init(Cipher.DECRYPT_MODE, secretKey(alias), GCMParameterSpec(128, blob, 0, IV_LEN))
        doFinal(blob, IV_LEN, blob.size - IV_LEN)
    }
```

## Network Security

### Network Security Config

```xml
<?xml version="1.0" encoding="utf-8"?>
<!-- res/xml/network_security_config.xml
     Manifest: <application android:networkSecurityConfig="@xml/network_security_config"> -->
<network-security-config>
    <base-config cleartextTrafficPermitted="false">
        <trust-anchors>
            <certificates src="system"/>
        </trust-anchors>
    </base-config>
    
    <!-- Applied only when android:debuggable="true", i.e. never in a release build -->
    <debug-overrides>
        <trust-anchors>
            <certificates src="user"/>
        </trust-anchors>
    </debug-overrides>
    
    <!-- Certificate pinning. After the expiration date pins are NOT enforced
         (fail-open) - rotate before then, and always ship a backup pin. -->
    <domain-config>
        <domain includeSubdomains="true">api.example.com</domain>
        <pin-set expiration="2027-06-30">
            <pin digest="SHA-256">AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=</pin>
            <pin digest="SHA-256">BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=</pin>
        </pin-set>
    </domain-config>
</network-security-config>
```

`cleartextTrafficPermitted="false"` is already the default at targetSdk 28+; state it anyway so the
posture is explicit. NSC is enforced by the platform trust manager, so it covers `HttpsURLConnection`,
OkHttp, and WebView — but **any client that installs its own `TrustManager`/`SSLSocketFactory` bypasses
it entirely**. Pin in the HTTP client too rather than relying on NSC alone.

### Certificate Pinning (Ktor)

Android-side pinning via the OkHttp engine. For pinning configured in shared KMP code (including the iOS/Darwin engine), use `kmp-tls-pinning`.

```kotlin
val client = HttpClient(OkHttp) {
    engine {
        config {
            certificatePinner(
                CertificatePinner.Builder()
                    .add("api.example.com", "sha256/AAAA...")
                    .add("api.example.com", "sha256/BBBB...")  // Backup
                    .build()
            )
        }
    }
}
```

## Safe Logging

Android-only, via Timber. For `commonMain` use Kermit and its redaction/severity setup — see `kmp-logging`.

```kotlin
// ❌ NEVER log sensitive data
Log.d("Auth", "Token: $token")

// ✅ Release-safe logging with Timber
class ReleaseTree : Timber.Tree() {
    override fun log(priority: Int, tag: String?, message: String, t: Throwable?) {
        if (priority >= Log.WARN) {
            val crashlytics = FirebaseCrashlytics.getInstance()
            crashlytics.log("${tag.orEmpty()}: $message")  // log(String) is the only overload
            t?.let(crashlytics::recordException)
        }
    }
}

// In Application
if (BuildConfig.DEBUG) {
    Timber.plant(Timber.DebugTree())
} else {
    Timber.plant(ReleaseTree())
}
```

## Input Validation

```kotlin
// Result.failure requires a Throwable, so the error type must extend Exception.
sealed class ValidationError(message: String) : Exception(message) {
    object Empty : ValidationError("empty")
    object TooLong : ValidationError("too long")
    object InvalidFormat : ValidationError("invalid format")
}

// Bound the length BEFORE running the regex - never feed unbounded input to a matcher.
// android.util.Patterns.EMAIL_ADDRESS is Android-only and deliberately permissive;
// in commonMain use your own conservative regex and treat the server as the authority.
fun validateEmail(email: String): Result<String> = when {
    email.isBlank() -> Result.failure(ValidationError.Empty)
    email.length > 254 -> Result.failure(ValidationError.TooLong)  // RFC 5321 max path
    !Patterns.EMAIL_ADDRESS.matcher(email).matches() ->
        Result.failure(ValidationError.InvalidFormat)
    else -> Result.success(email)
}

// SQL injection prevention - use parameterized queries
@Query("SELECT * FROM users WHERE id = :userId")
suspend fun getUser(userId: String): User?
```

## Biometric Authentication

Use `androidx.biometric:biometric`. Gate on `canAuthenticate` first — it distinguishes "no hardware"
from "nothing enrolled", and only the latter is worth an enrollment prompt:

```kotlin
val manager = BiometricManager.from(context)
when (manager.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)) {
    BiometricManager.BIOMETRIC_SUCCESS -> { /* proceed */ }
    BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> { /* send to Settings.ACTION_BIOMETRIC_ENROLL */ }
    else -> { /* fall back to PIN/password login */ }
}
```

```kotlin
val biometricPrompt = BiometricPrompt(
    activity,
    executor,
    object : BiometricPrompt.AuthenticationCallback() {
        override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
            // The key is unlocked only for THIS cipher. Do the crypto here, not before.
            val plaintext = result.cryptoObject!!.cipher!!.doFinal(ciphertext)
        }
        override fun onAuthenticationError(code: Int, msg: CharSequence) { /* user cancel, lockout */ }
    }
)

val promptInfo = BiometricPrompt.PromptInfo.Builder()
    .setTitle("Authenticate")
    // Required with BIOMETRIC_STRONG alone; calling it together with DEVICE_CREDENTIAL throws.
    .setNegativeButtonText("Cancel")
    // CryptoObject requires BIOMETRIC_STRONG (Class 3). Adding DEVICE_CREDENTIAL here means
    // you must call authenticate(promptInfo) without a CryptoObject.
    .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
    .build()

// Decrypting needs the stored IV, so DECRYPT_MODE + GCMParameterSpec - not ENCRYPT_MODE.
// Cipher.init throws KeyPermanentlyInvalidatedException if biometrics were re-enrolled.
val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
    init(Cipher.DECRYPT_MODE, secretKey(alias), GCMParameterSpec(128, iv))
}
biometricPrompt.authenticate(promptInfo, BiometricPrompt.CryptoObject(cipher))
```

## ProGuard/R8 Security

```proguard
# Retraceable crash reports. The second line is not optional: without it the real
# source file names ship in the APK, undoing part of the obfuscation.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# Flatten the package hierarchy
-repackageclasses 'a'
-allowaccessmodification

# Remove debug logging. Requires optimization to be on: -assumenosideeffects is
# ignored under -dontoptimize. AGP 9 dropped getDefaultProguardFile("proguard-android.txt")
# for exactly that reason - use "proguard-android-optimize.txt".
-assumenosideeffects class android.util.Log {
    public static *** d(...);
    public static *** v(...);
    public static *** i(...);
}
```

`-assumenosideeffects` strips the call, not the argument: `Log.d(TAG, "token=$token")` can still
leave the concatenated secret in the binary. Don't build the string at all — the `ReleaseTree` above
is the enforcement point, R8 is only cleanup. Upload `mapping.txt` (in
`build/outputs/mapping/<variant>/`, auto-bundled into the AAB) to your crash reporter.
