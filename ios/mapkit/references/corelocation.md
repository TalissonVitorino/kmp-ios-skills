# CoreLocation depth — authorization, updates, background, geofencing

Companion to the `mapkit` skill. Covers the full `CLLocationManager` delegate,
`Always` escalation, reduced accuracy, background sessions, and `CLMonitor`
background wiring.

## Full CLLocationManager delegate (classic path)

Still fully supported; use for existing code or when you need heading, region
monitoring hooks, or fine-grained control the async API doesn't expose.

```swift
import CoreLocation

@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var status: CLAuthorizationStatus
    var last: CLLocation?

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 25                 // meters moved before a new callback
        manager.activityType = .otherNavigation
    }

    func start() { manager.startUpdatingLocation() }
    func stop()  { manager.stopUpdatingLocation() }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        status = m.authorizationStatus
        switch status {
        case .notDetermined:        m.requestWhenInUseAuthorization()
        case .authorizedWhenInUse,
             .authorizedAlways:     m.startUpdatingLocation()
        case .denied, .restricted:  stop()          // send user to Settings in UI
        @unknown default:           break
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        last = locations.last                        // most-recent is last in the array
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        // CLError.denied => authorization lost; .locationUnknown => transient, keep trying
    }
}
```

- `desiredAccuracy`: `kCLLocationAccuracyBest`, `...NearestTenMeters`, `...HundredMeters`, `...Kilometer`, `...ThreeKilometers`, `...BestForNavigation`, `...Reduced`. Looser = less battery.
- `distanceFilter` throttles callbacks by movement; `kCLDistanceFilterNone` for every fix.
- `activityType` hints the system (`.automotiveNavigation`, `.fitness`, `.otherNavigation`, `.airborne`).

## Escalating to Always

- Only request after `WhenInUse` is granted and a background feature needs it.
- Call `manager.requestAlwaysAuthorization()`. iOS shows a one-time prompt; the user can also grant it later from Settings. If denied, keep functioning in WhenInUse mode — never block the app.
- iOS may downgrade `Always` back to `WhenInUse` and re-prompt ("keep allowing?"). Re-check `authorizationStatus` in `locationManagerDidChangeAuthorization`, don't cache it.

## Reduced accuracy

```swift
if manager.accuracyAuthorization == .reducedAccuracy {
    try await manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "PreciseBranchLocation")
}
```

- The `withPurposeKey:` value must exist as a key under `NSLocationTemporaryUsageDescriptionDictionary` in Info.plist, with a user-facing explanation.
- The upgrade is temporary (session-scoped). Design core flows to work at reduced accuracy so a denial isn't fatal.

## Background updates with CLBackgroundActivitySession

```swift
final class BackgroundTracker {
    private var session: CLBackgroundActivitySession?

    func begin() { session = CLBackgroundActivitySession() }   // retain for the duration
    func end()   { session?.invalidate(); session = nil }

    func run() async throws {
        begin()
        defer { end() }
        for try await update in CLLocationUpdate.liveUpdates() {
            guard !update.authorizationDenied else { break }
            if let loc = update.location { handle(loc) }
        }
    }
}
```

- Requires the **Location updates** Background Mode (Signing & Capabilities).
- The session shows the system's background-location indicator; invalidate promptly when the feature ends to respect battery and trust.
- Overwriting `session` (or the update sequence) without invalidating the old one can leak and keep the indicator on — one owner, explicit lifecycle.

## CLServiceSession (explicit authorization goal)

Iterating `liveUpdates()` / `CLMonitor.events` implicitly holds a `.whenInUse`
service session. Create one explicitly when you want to hold the authorization
goal independent of a specific stream:

```swift
let session = CLServiceSession(authorization: .whenInUse)
// ... retain while the feature is active ...
session.invalidate()
```

## CLMonitor — background geofencing wiring

```swift
actor GeofenceManager {
    private var monitor: CLMonitor?                       // built lazily — CLMonitor(_:) is async
    private var session: CLBackgroundActivitySession?

    private func sharedMonitor() async -> CLMonitor {
        if let monitor { return monitor }
        let m = await CLMonitor("BranchGeofences")
        monitor = m
        return m
    }

    func configure(_ regions: [Branch]) async {
        let monitor = await sharedMonitor()
        // Enforce the 20-condition cap: keep the nearest N.
        for b in regions.prefix(20) {
            let c = CLMonitor.CircularGeographicCondition(center: b.coordinate, radius: 120)
            await monitor.add(c, identifier: b.id, assuming: .unsatisfied)
        }
    }

    func observe() async throws {
        let monitor = await sharedMonitor()
        session = CLBackgroundActivitySession()          // needed for background delivery
        for try await event in await monitor.events {
            switch event.state {
            case .satisfied:   await enter(event.identifier)
            case .unsatisfied: await exit(event.identifier)
            case .unknown, .unmonitored: break
            @unknown default: break
            }
        }
    }
}
```

- `CLMonitor.Event.State`: `.unknown` (initial), `.satisfied` (inside), `.unsatisfied` (outside), `.unmonitored` (over the 20-condition cap / not evaluated).
- Background firing requires `Always` authorization + a retained background session; with `WhenInUse` events arrive only while foregrounded.
- The monitor is **named and persistent** — re-creating `CLMonitor("BranchGeofences")` after relaunch restores its conditions. Reconcile against your current desired set on launch (add new, `remove` stale) rather than blindly re-adding.
- Inspect prior state with `await monitor.record(for: identifier)?.lastEvent`.
