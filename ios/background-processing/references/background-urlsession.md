# Background URLSession — full wiring

Background sessions run transfers out-of-process; the system continues them while the
app is suspended and **relaunches the app** to deliver completion. Only `downloadTask`
and `uploadTask` are supported — no `dataTask`, no completion-handler variants.

## Session owner (singleton)

Keep one session per identifier alive for the app's lifetime and route delegate
callbacks through it.

```swift
import Foundation

final class BackgroundTransferManager: NSObject {
    static let shared = BackgroundTransferManager()
    static let sessionID = "com.example.fintech.bg-download"

    /// Set by the AppDelegate relaunch hook; called when the session drains its events.
    var backgroundCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.isDiscretionary = true               // system picks a power/network-optimal time
        config.sessionSendsLaunchEvents = true      // relaunch app on completion
        config.allowsCellularAccess = true          // false to restrict to Wi-Fi
        config.timeoutIntervalForResource = 24 * 60 * 60   // give the whole transfer up to a day
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func startDownload(from url: URL) {
        let task = session.downloadTask(with: url)
        task.earliestBeginDate = nil                // or a future Date to defer
        task.resume()
    }
}
```

- `isDiscretionary = true` yields best battery behavior but the system may delay for hours; set `false` (still background) for user-waited transfers.
- Recreating a session with the **same identifier** while one is already live throws — reuse the singleton. After the app is relaunched you must recreate it (same id) to reattach to in-flight tasks.

## Delegate: file handoff & completion

```swift
extension BackgroundTransferManager: URLSessionDownloadDelegate {
    // Called when bytes are on disk at a TEMP location — move synchronously, now.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let dest = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(downloadTask.originalRequest?.url?.lastPathComponent ?? "file")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: location, to: dest)   // temp file is deleted after return
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { /* inspect; use resume data for downloads (below) */ }
    }

    // All queued events for this session have been delivered — call the stored handler on main.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}
```

## App relaunch hook

UIKit:

```swift
func application(_ application: UIApplication,
                 handleEventsForBackgroundURLSession identifier: String,
                 completionHandler: @escaping () -> Void) {
    // Must match the session id; storing it recreates the lazy session and reattaches tasks.
    if identifier == BackgroundTransferManager.sessionID {
        BackgroundTransferManager.shared.backgroundCompletionHandler = completionHandler
    }
}
```

SwiftUI: `.backgroundTask(.urlSession("com.example.fintech.bg-download")) { /* await events */ }`
on the `Scene` — the closure runs when the session is relaunched; you still own the
session object and its delegate.

## Uploads & resumable downloads

- Upload from a **file** (`uploadTask(with:fromFile:)`), not in-memory `Data` — background sessions require a file body.
- On failure, recover resume data for downloads:

```swift
func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let data = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
        let resumed = s.downloadTask(withResumeData: data)   // persist `data` to retry across launches
        resumed.resume()
    }
}
```

- Report progress with `URLSessionDownloadDelegate`'s `didWriteData` (bytes written / expected) or observe `task.progress`.

## Pitfalls

- Doing async work in `didFinishDownloadingTo` before moving the temp file → the file is gone. Move it synchronously first.
- Forgetting to call the stored `backgroundCompletionHandler` → snapshot/relaunch stalls and iOS throttles future launches.
- Using a data task or a completion-handler API on a background config → runtime failure; only delegate-based download/upload tasks.
- Assuming discretionary transfers start promptly — they don't; surface a foreground path for anything the user is actively waiting on.
