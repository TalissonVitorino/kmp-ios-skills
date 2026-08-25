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
agp = "9.3.2"              # AGP 9.x has built-in Kotlin — see [plugins] note; AGP 9.3 needs Gradle 9.5+
kotlin = "2.4.10"          # still versions KGP-family plugins (Compose compiler); kotlin-android itself is gone
ksp = "2.3.11"              # KSP2 — decoupled from the Kotlin version number
compose-bom = "2026.08.00"
coroutines = "1.11.0"
koin = "4.2.2"             # Koin 4.x (major bump from 3.x)
ktor = "3.5.2"             # Ktor 3.x (major bump from 2.x)
# compose-compiler: removed. With Kotlin 2.0+ the Compose compiler ships as the
# org.jetbrains.kotlin.plugin.compose Gradle plugin (versioned with Kotlin) — see [plugins].
# A standalone compose-compiler catalog entry is obsolete.

[libraries]
# Compose BOM
compose-bom = { module = "androidx.compose:compose-bom", version.ref = "compose-bom" }
compose-ui = { module = "androidx.compose.ui:ui" }
compose-material3 = { module = "androidx.compose.material3:material3" }
compose-ui-tooling-preview = { module = "androidx.compose.ui:ui-tooling-preview" }
compose-ui-tooling = { module = "androidx.compose.ui:ui-tooling" } # debugImplementation only — never ships in release

# Koin
koin-android = { module = "io.insert-koin:koin-android", version.ref = "koin" }
koin-compose = { module = "io.insert-koin:koin-androidx-compose", version.ref = "koin" }

# Ktor Client
ktor-client-core = { module = "io.ktor:ktor-client-core", version.ref = "ktor" }
ktor-client-okhttp = { module = "io.ktor:ktor-client-okhttp", version.ref = "ktor" }
ktor-client-content-negotiation = { module = "io.ktor:ktor-client-content-negotiation", version.ref = "ktor" }
ktor-serialization-json = { module = "io.ktor:ktor-serialization-kotlinx-json", version.ref = "ktor" }

# Build-logic classpath (convention plugins)
android-gradlePlugin = { module = "com.android.tools.build:gradle", version.ref = "agp" }
kotlin-gradlePlugin = { module = "org.jetbrains.kotlin:kotlin-gradle-plugin", version.ref = "kotlin" }

# Testing
junit5 = { module = "org.junit.jupiter:junit-jupiter", version = "6.1.3" } # JUnit 6 / Jupiter 6 — requires Java 17+
mockk = { module = "io.mockk:mockk", version = "1.14.11" }
turbine = { module = "app.cash.turbine:turbine", version = "1.2.1" }
coroutines-test = { module = "org.jetbrains.kotlinx:kotlinx-coroutines-test", version.ref = "coroutines" }

[bundles]
compose = ["compose-ui", "compose-material3", "compose-ui-tooling-preview"]
ktor = ["ktor-client-core", "ktor-client-okhttp", "ktor-client-content-negotiation", "ktor-serialization-json"]
testing = ["junit5", "mockk", "turbine", "coroutines-test"]

[plugins]
android-application = { id = "com.android.application", version.ref = "agp" }
android-library = { id = "com.android.library", version.ref = "agp" }
ksp = { id = "com.google.devtools.ksp", version.ref = "ksp" }
# AGP 9 ships built-in Kotlin, enabled by default: do NOT apply org.jetbrains.kotlin.android —
# it fails with "Cannot add extension with name 'kotlin'". Temporary opt-out (removed in AGP 10):
# android.builtInKotlin=false + android.newDsl=false in gradle.properties.
# Kotlin 2.0+ Compose compiler plugin — still applied separately, versioned with Kotlin
compose-compiler = { id = "org.jetbrains.kotlin.plugin.compose", version.ref = "kotlin" }
```

## Convention Plugins

```kotlin
// build-logic/settings.gradle.kts — expose the main catalog to build-logic:
// dependencyResolutionManagement.versionCatalogs { create("libs") { from(files("../gradle/libs.versions.toml")) } }

// build-logic/convention/build.gradle.kts
plugins {
    `kotlin-dsl`
}

dependencies {
    compileOnly(libs.android.gradlePlugin)
    compileOnly(libs.kotlin.gradlePlugin)
}

gradlePlugin {
    plugins {
        register("androidLibrary") {
            id = "convention.android.library"
            implementationClass = "AndroidLibraryConventionPlugin"
        }
    }
}

// AndroidLibraryConventionPlugin.kt
// A .kt file gets no implicit kotlin-dsl imports — declare them all:
import com.android.build.api.dsl.LibraryExtension // new DSL interface; com.android.build.gradle.* types are deprecated in AGP 9
import org.gradle.api.JavaVersion
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.tasks.testing.Test
import org.gradle.kotlin.dsl.configure
import org.gradle.kotlin.dsl.withType

class AndroidLibraryConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) = with(target) {
        // AGP 9 built-in Kotlin: the Android plugin alone compiles Kotlin —
        // do not apply "org.jetbrains.kotlin.android"
        pluginManager.apply("com.android.library")

        extensions.configure<LibraryExtension> {
            compileSdk = 36
            defaultConfig.minSdk = 24

            compileOptions {
                sourceCompatibility = JavaVersion.VERSION_17
                // built-in Kotlin: jvmTarget defaults to targetCompatibility
                targetCompatibility = JavaVersion.VERSION_17
            }
        }

        // junit-jupiter runs only on the JUnit Platform — without this, tests are silently skipped
        tasks.withType<Test>().configureEach { useJUnitPlatform() }
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

# Already default on AGP 9 / Kotlin 2.x — delete if present:
# android.useAndroidX, android.nonTransitiveRClass, android.nonFinalResIds,
# kotlin.incremental. (kotlin.caching.enabled is obsolete.)
```

## Multi-Module Setup

```kotlin
// settings.gradle.kts
pluginManagement {
    includeBuild("build-logic") // makes convention.* plugin ids resolvable
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

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

    // The BOM is what versions the versionless compose-* catalog entries
    implementation(platform(libs.compose.bom))
    implementation(libs.bundles.compose)
    implementation(libs.koin.compose)
    debugImplementation(libs.compose.ui.tooling)

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

# Bypass caches for one run (cleanBuildCache was removed in AGP 7.0)
./gradlew build --rerun-tasks

# Nuke Gradle caches — last resort
rm -rf ~/.gradle/caches

# Build scan
./gradlew build --scan
```
