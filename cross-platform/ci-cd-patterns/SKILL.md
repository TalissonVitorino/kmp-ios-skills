---
name: ci-cd-patterns
description: CI/CD patterns for mobile - GitHub Actions workflows for Android/iOS, Fastlane integration, code signing, artifact publishing, and automated release.
---

# CI/CD Patterns for Mobile

## GitHub Actions for Android

### Build, Test, and Lint Workflow

```yaml
# .github/workflows/android-ci.yml
name: Android CI

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

concurrency:
  group: android-ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 30

    steps:
      - uses: actions/checkout@v7

      - name: Set up JDK 17
        uses: actions/setup-java@v6
        with:
          java-version: '17'
          distribution: 'temurin'

      - name: Setup Gradle
        uses: gradle/actions/setup-gradle@v6
        with:
          cache-read-only: ${{ github.ref != 'refs/heads/main' }}

      - name: Run lint
        run: ./gradlew lintDebug

      - name: Run unit tests
        run: ./gradlew testDebugUnitTest

      - name: Generate coverage report
        # Project-defined Jacoco task - adjust to your setup
        run: ./gradlew jacocoTestDebugUnitTestReport

      - name: Upload coverage
        uses: codecov/codecov-action@v7
        with:
          # `files` takes explicit comma-separated paths, not globs.
          # Use `directory` to let the uploader search a tree.
          directory: app/build/reports/jacoco
          token: ${{ secrets.CODECOV_TOKEN }}

      - name: Build debug APK
        run: ./gradlew assembleDebug

      - name: Upload APK artifact
        uses: actions/upload-artifact@v7
        with:
          name: debug-apk
          path: app/build/outputs/apk/debug/app-debug.apk
          retention-days: 14
```

### Build Release AAB

```yaml
  release:
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main'
    needs: build

    steps:
      - uses: actions/checkout@v7

      - name: Set up JDK 17
        uses: actions/setup-java@v6
        with:
          java-version: '17'
          distribution: 'temurin'

      - name: Decode keystore
        run: echo "${{ secrets.KEYSTORE_BASE64 }}" | base64 -d > app/release.keystore

      - name: Build release AAB
        run: ./gradlew bundleRelease
        env:
          KEYSTORE_PASSWORD: ${{ secrets.KEYSTORE_PASSWORD }}
          KEY_ALIAS: ${{ secrets.KEY_ALIAS }}
          KEY_PASSWORD: ${{ secrets.KEY_PASSWORD }}

      - name: Upload AAB artifact
        uses: actions/upload-artifact@v7
        with:
          name: release-aab
          path: app/build/outputs/bundle/release/app-release.aab
```

---

## GitHub Actions for iOS

### Build and Test Workflow

```yaml
# .github/workflows/ios-ci.yml
name: iOS CI

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

concurrency:
  group: ios-ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build:
    runs-on: macos-26
    timeout-minutes: 45

    steps:
      - uses: actions/checkout@v7

      - name: Select Xcode version
        # Must match a version installed on the runner image (see actions/runner-images)
        run: sudo xcode-select -s /Applications/Xcode_26.6.app

      - name: Cache SPM packages
        uses: actions/cache@v6
        with:
          # Must live under the -derivedDataPath used below
          path: DerivedData/SourcePackages
          key: spm-${{ hashFiles('**/Package.resolved') }}
          restore-keys: spm-

      - name: Build
        run: |
          xcodebuild build-for-testing \
            -scheme MyApp \
            -destination 'platform=iOS Simulator,name=iPhone 17' \
            -derivedDataPath DerivedData \
            CODE_SIGNING_ALLOWED=NO

      - name: Run tests
        run: |
          xcodebuild test-without-building \
            -scheme MyApp \
            -destination 'platform=iOS Simulator,name=iPhone 17' \
            -derivedDataPath DerivedData \
            -resultBundlePath TestResults.xcresult

      - name: Upload test results
        if: always()
        uses: actions/upload-artifact@v7
        with:
          name: test-results
          path: TestResults.xcresult
```

### Code Signing and IPA Build

```yaml
  archive:
    runs-on: macos-26
    if: github.ref == 'refs/heads/main'
    needs: build

    steps:
      - uses: actions/checkout@v7

      - name: Install Apple certificate and provisioning profile
        env:
          CERTIFICATE_BASE64: ${{ secrets.APPLE_CERTIFICATE_BASE64 }}
          CERTIFICATE_PASSWORD: ${{ secrets.APPLE_CERTIFICATE_PASSWORD }}
          PROVISIONING_PROFILE_BASE64: ${{ secrets.PROVISIONING_PROFILE_BASE64 }}
        run: |
          CERTIFICATE_PATH=$RUNNER_TEMP/certificate.p12
          PP_PATH=$RUNNER_TEMP/profile.mobileprovision
          KEYCHAIN_PATH=$RUNNER_TEMP/app-signing.keychain-db

          echo -n "$CERTIFICATE_BASE64" | base64 --decode -o $CERTIFICATE_PATH
          echo -n "$PROVISIONING_PROFILE_BASE64" | base64 --decode -o $PP_PATH

          security create-keychain -p "" $KEYCHAIN_PATH
          security set-keychain-settings -lut 21600 $KEYCHAIN_PATH
          security unlock-keychain -p "" $KEYCHAIN_PATH
          security import $CERTIFICATE_PATH -P "$CERTIFICATE_PASSWORD" \
            -A -t cert -f pkcs12 -k $KEYCHAIN_PATH
          # Without this, codesign hangs on a keychain UI prompt
          security set-key-partition-list -S apple-tool:,apple: -k "" $KEYCHAIN_PATH
          security list-keychains -d user -s $KEYCHAIN_PATH login.keychain-db

          # Xcode 16+ reads profiles from UserData; older tooling still uses
          # the MobileDevice path. Install into both.
          mkdir -p ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles
          mkdir -p ~/Library/MobileDevice/Provisioning\ Profiles
          cp $PP_PATH ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/
          cp $PP_PATH ~/Library/MobileDevice/Provisioning\ Profiles/

      - name: Archive
        run: |
          xcodebuild archive \
            -scheme MyApp \
            -archivePath $RUNNER_TEMP/MyApp.xcarchive \
            -destination 'generic/platform=iOS'

      - name: Export IPA
        run: |
          xcodebuild -exportArchive \
            -archivePath $RUNNER_TEMP/MyApp.xcarchive \
            -exportPath $RUNNER_TEMP/export \
            -exportOptionsPlist ExportOptions.plist

      - name: Upload IPA
        uses: actions/upload-artifact@v7
        with:
          name: release-ipa
          path: ${{ runner.temp }}/export/*.ipa
```

---

## Fastlane

### Android Fastfile

```ruby
# android/fastlane/Fastfile
default_platform(:android)

platform :android do
  desc "Run unit tests"
  lane :test do
    gradle(task: "testDebugUnitTest")
  end

  desc "Build and deploy to internal testing"
  lane :beta do
    gradle(
      task: "bundleRelease",
      properties: {
        "android.injected.signing.store.file" => ENV["KEYSTORE_PATH"],
        "android.injected.signing.store.password" => ENV["KEYSTORE_PASSWORD"],
        "android.injected.signing.key.alias" => ENV["KEY_ALIAS"],
        "android.injected.signing.key.password" => ENV["KEY_PASSWORD"]
      }
    )
    upload_to_play_store(
      track: "internal",
      aab: lane_context[SharedValues::GRADLE_AAB_OUTPUT_PATH],
      skip_upload_metadata: true,
      skip_upload_changelogs: false,
      skip_upload_images: true,
      skip_upload_screenshots: true
    )
  end

  desc "Deploy to production"
  lane :release do
    beta
    upload_to_play_store(
      track: "internal",
      track_promote_to: "production",
      track_promote_release_status: "inProgress",  # required for fractional rollout
      skip_upload_aab: true,
      rollout: "0.1"  # 10% staged rollout
    )
  end
end
```

### iOS Fastfile

```ruby
# ios/fastlane/Fastfile
default_platform(:ios)

platform :ios do
  desc "Sync code signing"
  lane :sync_signing do
    match(
      type: "appstore",
      app_identifier: "com.myapp.ios",
      readonly: is_ci
    )
  end

  desc "Run tests"
  lane :test do
    run_tests(
      scheme: "MyApp",
      device: "iPhone 17",
      code_coverage: true
    )
  end

  desc "Build and deploy to TestFlight"
  lane :beta do
    # match, pilot, and deliver pick the key up from lane_context
    app_store_connect_api_key(
      key_id: ENV["ASC_KEY_ID"],
      issuer_id: ENV["ASC_ISSUER_ID"],
      key_content: ENV["ASC_KEY_P8"]
    )
    sync_signing
    increment_build_number(
      build_number: ENV["GITHUB_RUN_NUMBER"] || latest_testflight_build_number + 1
    )
    build_app(
      scheme: "MyApp",
      export_method: "app-store"
    )
    upload_to_testflight(
      skip_waiting_for_build_processing: true
    )
  end

  desc "Deploy to App Store"
  lane :release do
    app_store_connect_api_key(
      key_id: ENV["ASC_KEY_ID"],
      issuer_id: ENV["ASC_ISSUER_ID"],
      key_content: ENV["ASC_KEY_P8"]
    )
    sync_signing
    increment_build_number
    build_app(scheme: "MyApp", export_method: "app-store")
    deliver(
      submit_for_review: true,
      automatic_release: false,
      force: true,
      skip_metadata: false,
      skip_screenshots: true
    )
  end
end
```

### Fastlane match for Code Signing

```ruby
# ios/fastlane/Matchfile
git_url("https://github.com/myorg/certificates.git")
storage_mode("git")
type("appstore")
app_identifier("com.myapp.ios")
team_id("TEAM_ID")
```

---

## Automated Release

### Semantic Versioning

```ruby
# Fastlane version bump
lane :bump_version do |options|
  type = options[:type] || "patch"  # major, minor, patch
  increment_version_number(bump_type: type)
  commit_version_bump(message: "chore: bump version [skip ci]")
end
```

### Changelog Generation

```yaml
# .github/workflows/release.yml
- name: Generate changelog
  id: changelog
  uses: mikepenz/release-changelog-builder-action@v6
  with:
    configuration: ".github/changelog-config.json"
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

- name: Create GitHub Release
  uses: softprops/action-gh-release@v3
  with:
    tag_name: v${{ env.VERSION }}
    body: ${{ steps.changelog.outputs.changelog }}
    files: |
      app/build/outputs/bundle/release/app-release.aab
```

### Tag-Based Release Trigger

```yaml
on:
  push:
    tags:
      - 'v*'

jobs:
  release-android:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: Extract version from tag
        run: echo "VERSION=${GITHUB_REF#refs/tags/v}" >> $GITHUB_ENV
      - name: Build and publish
        run: bundle exec fastlane release
```
