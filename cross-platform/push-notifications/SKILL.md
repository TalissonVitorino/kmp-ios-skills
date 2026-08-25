---
name: push-notifications
description: Push notification patterns - FCM setup for Android, APNs for iOS, notification channels, payload handling, foreground/background behavior, and rich notifications.
---

# Push Notification Patterns

> **iOS-related routing:** for updating a **Live Activity / Dynamic Island** via an APNs push (`content-state`), use `activitykit`; for pushing **widget** timeline reloads, use `widgetkit`. This skill covers the FCM/APNs delivery + payload layer.

## Android / Firebase Cloud Messaging

### Firebase Setup

Add `google-services.json` to the `app/` directory and configure dependencies:

```kotlin
// build.gradle.kts (project)
plugins {
    id("com.google.gms.google-services") version "4.5.0" apply false
}

// build.gradle.kts (app)
plugins {
    id("com.google.gms.google-services")
}

dependencies {
    implementation(platform("com.google.firebase:firebase-bom:34.18.0"))
    implementation("com.google.firebase:firebase-messaging")
}
```

The `-ktx` modules were removed in BoM 34.0.0 — all Kotlin extensions (`Firebase.messaging`, etc.) now live in the main artifacts. Do not add `firebase-messaging-ktx`.

### Manifest Registration

Without the `MESSAGING_EVENT` intent filter the service is never invoked — this is the most common "onMessageReceived never fires" cause:

```xml
<service
    android:name=".MyFirebaseMessagingService"
    android:exported="false">
    <intent-filter>
        <action android:name="com.google.firebase.MESSAGING_EVENT" />
    </intent-filter>
</service>

<!-- Applies only to notification messages FCM renders itself (app backgrounded). -->
<meta-data android:name="com.google.firebase.messaging.default_notification_icon"
    android:resource="@drawable/ic_notification" />
<meta-data android:name="com.google.firebase.messaging.default_notification_color"
    android:resource="@color/notification_accent" />
<meta-data android:name="com.google.firebase.messaging.default_notification_channel_id"
    android:value="default" />
```

The channel named by `default_notification_channel_id` must already exist when the message arrives; otherwise FCM falls back to a generic SDK-created channel the user cannot meaningfully tune.

### FirebaseMessagingService Implementation

```kotlin
class MyFirebaseMessagingService : FirebaseMessagingService() {

    override fun onNewToken(token: String) {
        // Not a coroutine scope, and the process can be killed right after this
        // returns — hand the upload to WorkManager instead of launching here.
        TokenSyncWorker.enqueue(applicationContext, token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        // Data messages always arrive here
        val data = message.data
        val title = data["title"] ?: message.notification?.title ?: return
        val body = data["body"] ?: message.notification?.body ?: ""

        when (data["type"]) {
            "chat" -> showChatNotification(title, body, data)
            "promo" -> showPromoNotification(title, body, data)
            else -> showDefaultNotification(title, body)
        }
    }

    private fun showDefaultNotification(title: String, body: String) {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent, PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(this, CHANNEL_DEFAULT)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(body)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .build()

        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(System.currentTimeMillis().toInt(), notification)
    }

    companion object {
        const val CHANNEL_DEFAULT = "default"
        const val CHANNEL_CHAT = "chat_messages"
        const val CHANNEL_PROMO = "promotions"
    }
}
```

### Notification Channels (Android 8+)

```kotlin
object NotificationChannels {
    fun createAll(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager = context.getSystemService(NotificationManager::class.java)

        val defaultChannel = NotificationChannel(
            "default",
            "General",
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
            description = "General notifications"
        }

        val chatChannel = NotificationChannel(
            "chat_messages",
            "Chat Messages",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "New chat messages"
            enableVibration(true)
            enableLights(true)
        }

        val promoChannel = NotificationChannel(
            "promotions",
            "Promotions",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Promotional offers and deals"
        }

        manager.createNotificationChannels(listOf(defaultChannel, chatChannel, promoChannel))
    }
}
```

Call `NotificationChannels.createAll(this)` in `Application.onCreate()`.

### Data vs Notification Messages

| Aspect | Notification Message | Data Message |
|--------|---------------------|--------------|
| Foreground | `onMessageReceived` | `onMessageReceived` |
| Background | System tray (auto) | `onMessageReceived` |
| Customizable | Limited | Full control |
| Payload key | `"notification": {}` | `"data": {}` |

**Best practice:** Use data-only messages for full control over display behavior. Caveat: data messages default to normal priority and can be deferred by Doze/App Standby — set `"android": {"priority": "high"}` only for time-sensitive, user-visible content, or delivery may be throttled. Max payload is 4096 bytes for both types (1000 characters via the console composer); send IDs, not content, and fetch the rest on receipt.

### Token Registration and Server Sync

```kotlin
class TokenRepository(private val api: ApiService) {
    suspend fun syncTokenToServer(token: String) {
        val deviceInfo = DeviceInfo(
            token = token,
            platform = "android",
            appVersion = BuildConfig.VERSION_NAME,
            locale = Locale.getDefault().toLanguageTag()
        )
        api.registerPushToken(deviceInfo)
    }

    suspend fun getAndSyncToken() {
        val token = FirebaseMessaging.getInstance().token.await()
        syncTokenToServer(token)
    }
}
```

`Task.await()` requires `org.jetbrains.kotlinx:kotlinx-coroutines-play-services`. `TokenSyncWorker` (enqueued from `onNewToken`) just wraps `syncTokenToServer`, so an upload that fails while the process is dying is retried by WorkManager instead of lost — a dropped rotation silently stops all pushes to that install.

### Notification Permission (Android 13+)

Declare `<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />` in the manifest, then request at runtime:

```kotlin
// Must be registered during construction / onCreate — before the host reaches STARTED.
private val requestPermissionLauncher = registerForActivityResult(
    ActivityResultContracts.RequestPermission()
) { isGranted -> if (isGranted) viewModel.syncPushToken() }

private fun ensureNotificationPermission() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
    val granted = ContextCompat.checkSelfPermission(
        this, Manifest.permission.POST_NOTIFICATIONS
    ) == PackageManager.PERMISSION_GRANTED
    if (!granted) requestPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
}
```

Once the user has denied twice the launcher returns `false` immediately without showing a dialog; the only recovery is `Settings.ACTION_APP_NOTIFICATION_SETTINGS` with `Settings.EXTRA_APP_PACKAGE`. Swiping the dialog away leaves the state unchanged and does not count as a denial. Apps still targeting API 32 or lower get the dialog automatically on first channel creation, and a single "Don't allow" is permanent until reinstall — another reason to target 33+.

---

## iOS / APNs

### Push Notification Capability

Enable in Xcode: Target > Signing & Capabilities > + Push Notifications.
Enable Background Modes > Remote notifications only if you send silent pushes (`"content-available": 1`) — alert-bearing pushes do not need it.

### UNUserNotificationCenter Setup and Permissions

Assign `UNUserNotificationCenter.current().delegate` in `didFinishLaunchingWithOptions`, before the method returns — not inside the authorization request. A cold launch from a notification tap delivers `didReceive response:` immediately after launch, and a delegate set later misses it.

```swift
import UserNotifications

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(
                options: [.alert, .badge, .sound]
            )
            if granted {
                await MainActor.run {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
            return granted
        } catch {
            return false
        }
    }

    // Foreground notification display. `.list` is what keeps it in Notification
    // Center afterwards — `.banner` alone shows it once and drops it.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return [.banner, .list, .badge, .sound]
    }

    // Notification tap handling
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        handleNotificationPayload(userInfo)
    }

    private func handleNotificationPayload(_ userInfo: [AnyHashable: Any]) {
        guard let type = userInfo["type"] as? String else { return }
        switch type {
        case "chat":
            let chatId = userInfo["chat_id"] as? String ?? ""
            DeepLinkRouter.shared.destination = .chat(id: chatId)
        case "product":
            let productId = userInfo["product_id"] as? String ?? ""
            DeepLinkRouter.shared.destination = .product(id: productId)
        default:
            break
        }
    }
}
```

`UNUserNotificationCenterDelegate` callbacks are not main-actor isolated. Under Swift 6 language mode, mark the router `@MainActor` and hop explicitly (`await MainActor.run { ... }`) rather than touching UI state directly from the callback.

### AppDelegate Registration

```swift
func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
) {
    let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
    Task { await TokenService.shared.syncToken(token) }
}

func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
) {
    print("Push registration failed: \(error.localizedDescription)")
}
```

### Silent (Background) Pushes

A payload of `{"aps": {"content-available": 1}}` with no alert, sound, or badge does **not** reach the `UNUserNotificationCenterDelegate` — it wakes the app through `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`. APNs also requires the `apns-push-type: background` and `apns-priority: 5` headers (FCM: `"apns": {"headers": {"apns-push-type": "background", "apns-priority": "5"}}`); a background push sent at priority 10 is rejected.

Call the completion handler with an honest `UIBackgroundFetchResult` within ~30 s. Delivery is budgeted and coalesced by the system — silent pushes are a hint to sync, never a guaranteed transport, so the app must still reconcile on foreground.

### Notification Service Extension (Rich Notifications)

Create a new target: File > New > Target > Notification Service Extension. The extension runs only when the APNs payload carries **both** `"mutable-content": 1` and an `alert` dictionary inside `aps` (FCM: set `"apns": {"payload": {"aps": {"mutable-content": 1}}}` alongside the alert). Miss either one — notably on a silent `content-available` push — and the notification is delivered unmodified without the extension ever launching.

```swift
class NotificationService: UNNotificationServiceExtension {
    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        guard let content = bestAttemptContent,
              let imageURLString = content.userInfo["image_url"] as? String,
              let imageURL = URL(string: imageURLString) else {
            contentHandler(request.content)
            return
        }

        downloadImage(from: imageURL) { attachment in
            if let attachment = attachment {
                content.attachments = [attachment]
            }
            contentHandler(content)
        }
    }

    // UNNotificationAttachment requires a local file URL with a recognizable
    // extension; move the temp download before creating the attachment.
    private func downloadImage(
        from url: URL,
        completion: @escaping (UNNotificationAttachment?) -> Void
    ) {
        URLSession.shared.downloadTask(with: url) { tempURL, _, _ in
            guard let tempURL else { return completion(nil) }
            let localURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(url.pathExtension.isEmpty ? "jpg" : url.pathExtension)
            try? FileManager.default.moveItem(at: tempURL, to: localURL)
            completion(try? UNNotificationAttachment(identifier: "image", url: localURL))
        }.resume()
    }

    override func serviceExtensionTimeWillExpire() {
        if let content = bestAttemptContent {
            contentHandler?(content)
        }
    }
}
```

### Provisional Authorization (iOS 12+)

Including `.provisional` skips the permission dialog entirely: authorization is granted silently and notifications are delivered quietly to Notification Center only (no banner, sound, or badge). Never mix `.provisional` into a request where you expect the user to see a prompt.

```swift
let granted = try await center.requestAuthorization(options: [.alert, .sound, .provisional])
```

Users can then promote to prominent delivery or turn off from the notification itself. Check `await center.notificationSettings().authorizationStatus == .provisional` to detect this state (`notificationSettings()` is async).

---

## Testing

The Firebase CLI has no send command. Send test FCM messages via the console's Notifications composer, the Admin SDK, or the HTTP v1 API directly (the legacy server API was shut down in 2024):

```bash
# Android - FCM HTTP v1 API (needs cloud-platform or firebase.messaging OAuth scope)
curl -X POST "https://fcm.googleapis.com/v1/projects/PROJECT_ID/messages:send" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  -d '{"message": {"token": "DEVICE_TOKEN", "data": {"type": "chat", "title": "Test", "body": "Hello"}}}'

# iOS Simulator - inject an APNs payload (payload.apns = {"aps": {"alert": {"title": "Test"}}})
xcrun simctl push booted com.example.app payload.apns
```

For UI-only testing on device, schedule a local notification:

```swift
let content = UNMutableNotificationContent()
content.title = "Test Notification"
content.body = "This is a local test."
let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
let request = UNNotificationRequest(identifier: "test", content: content, trigger: trigger)
try await UNUserNotificationCenter.current().add(request)
```
