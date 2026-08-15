---
name: gradle-patterns
description: Gradle build configuration quick patterns - Version Catalogs, convention plugins, multi-module setup. For deep build-logic design prefer android-skills:android-gradle-logic, and for diagnosing slow builds (build scans, configuration cache, kapt to KSP migration, CI) use android-skills:gradle-build-performance.
---

# Gradle Build Patterns

Modern Gradle configuration for Android.

## Version Catalog

```toml
# gradle/libs.versions.toml
[versions]
agp = "9.2.0"
kotlin = "2.4.0"
ksp = "2.3.10"              # KSP2 — decoupled from the Kotlin version number
compose-bom = "2026.06.00"
coroutines = "1.11.0"
koin = "4.1.1"             # Koin 4.x (major bump from 3.x)
ktor = "3.5.1"             # Ktor 3.x (major bump from 2.x)
# compose-compiler: removed. With Kotlin 2.0+ the Compose compiler ships as the
# org.jetbrains.kotlin.plugin.compose Gradle plugin (versioned with Kotlin) — see [plugins].
# A standalone compose-compiler catalog entry is obsolete.

[libraries]
# Compose BOM
compose-bom = { module = "androidx.compose:compose-bom", version.ref = "compose-bom" }
compose-ui = { module = "androidx.compose.ui:ui" }
compose-material3 = { module = "androidx.compose.material3:material3" }
compose-ui-tooling = { module = "androidx.compose.ui:ui-tooling" }

# Koin
koin-android = { module = "io.insert-koin:koin-android", version.ref = "koin" }
koin-compose = { module = "io.insert-koin:koin-androidx-compose", version.ref = "koin" }

# Ktor Client
ktor-client-core = { module = "io.ktor:ktor-client-core", version.ref = "ktor" }
ktor-client-okhttp = { module = "io.ktor:ktor-client-okhttp", version.ref = "ktor" }
ktor-client-content-negotiation = { module = "io.ktor:ktor-client-content-negotiation", version.ref = "ktor" }
ktor-serialization-json = { module = "io.ktor:ktor-serialization-kotlinx-json", version.ref = "ktor" }

# Testing
junit5 = { module = "org.junit.jupiter:junit-jupiter", version = "6.1.2" } # JUnit 6 / Jupiter 6 — requires Java 17+
mockk = { module = "io.mockk:mockk", version = "1.14.9" }
turbine = { module = "app.cash.turbine:turbine", version = "1.2.1" }
coroutines-test = { module = "org.jetbrains.kotlinx:kotlinx-coroutines-test", version.ref = "coroutines" }

[bundles]
compose = ["compose-ui", "compose-material3", "compose-ui-tooling"]
ktor = ["ktor-client-core", "ktor-client-okhttp", "ktor-client-content-negotiation", "ktor-serialization-json"]
testing = ["junit5", "mockk", "turbine", "coroutines-test"]

[plugins]
android-application = { id = "com.android.application", version.ref = "agp" }
android-library = { id = "com.android.library", version.ref = "agp" }
kotlin-android = { id = "org.jetbrains.kotlin.android", version.ref = "kotlin" }
# Kotlin 2.0+ Compose compiler plugin — replaces the old standalone compose-compiler version
compose-compiler = { id = "org.jetbrains.kotlin.plugin.compose", version.ref = "kotlin" }
```

## Convention Plugins

```kotlin
// build-logic/convention/build.gradle.kts
plugins {
    `kotlin-dsl`
}

dependencies {
    compileOnly(libs.android.gradlePlugin)
    compileOnly(libs.kotlin.gradlePlugin)
}

// AndroidLibraryConventionPlugin.kt
class AndroidLibraryConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) = with(target) {
        with(pluginManager) {
            apply("com.android.library")
            apply("org.jetbrains.kotlin.android")
        }
        
        extensions.configure<LibraryExtension> {
            compileSdk = 36
            defaultConfig.minSdk = 24
            
            compileOptions {
                sourceCompatibility = JavaVersion.VERSION_17
                targetCompatibility = JavaVersion.VERSION_17
            }
        }
    }
}
```

## Build Optimization

```properties
# gradle.properties
org.gradle.parallel=true
org.gradle.caching=true
org.gradle.configuration-cache=true
org.gradle.jvmargs=-Xmx4g -XX:+UseParallelGC

# Kotlin
kotlin.incremental=true
kotlin.caching.enabled=true

# Android
android.useAndroidX=true
android.nonTransitiveRClass=true
android.nonFinalResIds=true
```

## Multi-Module Setup

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

include(":app")
include(":core:common")
include(":core:ui")
include(":core:network")
include(":feature:home")
include(":feature:detail")
```

## Dependency Declarations

```kotlin
// Feature module build.gradle.kts
plugins {
    id("convention.android.library")
    id("convention.android.compose")
}

dependencies {
    implementation(project(":core:common"))
    implementation(project(":core:ui"))
    
    implementation(libs.bundles.compose)
    implementation(libs.koin.compose)
    
    testImplementation(libs.bundles.testing)
}
```

## Build Commands

```bash
# Full build with timing
./gradlew build --profile

# Specific module
./gradlew :feature:home:assembleDebug

# Dependency tree
./gradlew :app:dependencies --configuration releaseRuntimeClasspath

# Clear caches
./gradlew cleanBuildCache
rm -rf ~/.gradle/caches

# Build scan
./gradlew build --scan
```
