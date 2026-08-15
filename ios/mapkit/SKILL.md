---
name: mapkit
description: "MapKit + CoreLocation for iOS (iOS 17–26 era). SwiftUI Map with MapContentBuilder (Marker / Annotation / MapPolyline / MapPolygon / MapCircle / UserAnnotation), MapCameraPosition & MapCamera with onMapCameraChange, mapStyle / mapControls / selection, MapReader + MapProxy coordinate conversion, and Look Around (LookAroundPreview / MKLookAroundSceneRequest). CoreLocation authorization, the modern CLLocationUpdate.liveUpdates async stream, CLServiceSession / CLBackgroundActivitySession, and CLMonitor geofencing (iOS 17+). Place search with MKLocalSearch / MKLocalSearchCompleter, routing with MKDirections, and geocoding (CLGeocoder plus the iOS 26 MKGeocodingRequest / MKReverseGeocodingRequest). Use when adding maps, showing user location, geofencing, address autocomplete, directions, or reverse/forward geocoding. For @Observable view-model state see swiftui-observation; for consuming async sequences see swift-concurrency; for background delivery see background-processing; for exposing location to KMP commonMain see expect-actual; for Info.plist purpose strings and submission see app-store-review."
---

# MapKit & CoreLocation (iOS)

SwiftUI-first mapping, user location, geofencing, search, routing, and geocoding.
Grounded in Apple's MapKit and CoreLocation frameworks. SwiftUI `Map` content
builder, `MapCameraPosition`, `MapReader`, and Look Around are iOS 17+; the async
`CLLocationUpdate` / `CLMonitor` APIs are iOS 17+ (with iOS 18 service-session
changes); `MKGeocodingRequest` and cycling directions are iOS 26.

- **KMP boundary:** map UI is native iOS — put the `Map` inside a SwiftUI screen, not shared Compose. Expose only *data* (coordinates, a location stream) from `commonMain` via an `interface`, bound to a CoreLocation `actual` in `iosMain`; see `expect-actual` and `kmp-ios-integration`.
- **Privacy first (fintech):** location is sensitive. Request the *narrowest* authorization that works (`WhenInUse` over `Always`), support reduced accuracy, and never log or transmit coordinates without a clear user-facing reason. Purpose strings and privacy-manifest details: `app-store-review`.

## Contents

- [Info.plist / entitlements](#plist)
- [SwiftUI Map + content builder](#map)
- [Camera (position / MapCamera / changes)](#camera)
- [Style, controls, selection](#style)
- [MapReader + MapProxy](#reader)
- [CoreLocation authorization](#auth)
- [Live location updates (async)](#updates)
- [Geofencing with CLMonitor](#monitor)
- [Place search (MKLocalSearch / completer)](#search)
- [Directions (MKDirections)](#directions)
- [Geocoding (CLGeocoder / iOS 26 MapKit)](#geocoding)
- [Look Around](#lookaround)
- [Correctness checklist](#checklist)
- References: `references/corelocation.md`, `references/search-routing-geocoding.md`

<a id="plist"></a>
## Info.plist / entitlements

- `NSLocationWhenInUseUsageDescription` — **required** for any location access; app crashes on request without it.
- `NSLocationAlwaysAndWhenInUseUsageDescription` — only if you request `Always` (background/geofencing while backgrounded).
- `NSLocationTemporaryUsageDescriptionDictionary` — keyed purpose strings for one-off *full-accuracy* upgrades when the user granted reduced accuracy.
- Background delivery (geofencing/tracking while backgrounded): enable the **Location updates** Background Mode and hold a `CLBackgroundActivitySession`.
- MapKit rendering itself needs no entitlement; showing the blue user dot needs location authorization.

<a id="map"></a>
## SwiftUI Map + content builder

`Map` takes a `@MapContentBuilder` closure of types conforming to `MapContent`.

```swift
import SwiftUI
import MapKit

struct BranchMap: View {
    let branches: [Branch]                       // id, coordinate, name
    @State private var position: MapCameraPosition = .automatic
    @State private var selected: Branch.ID?

    var body: some View {
        Map(position: $position, selection: $selected) {
            // System-styled balloon pin.
            ForEach(branches) { b in
                Marker(b.name, systemImage: "building.columns", coordinate: b.coordinate)
                    .tint(.indigo)
                    .tag(b.id)                    // enables selection
            }

            // Custom SwiftUI content at a coordinate.
            Annotation("You spent here", coordinate: lastPurchase) {
                Image(systemName: "creditcard.fill")
                    .padding(6).background(.blue, in: .circle).foregroundStyle(.white)
            }
            .annotationTitles(.hidden)

            // Overlays.
            MapCircle(center: geofenceCenter, radius: 150)
                .foregroundStyle(.blue.opacity(0.15))
                .stroke(.blue, lineWidth: 2)
            MapPolyline(coordinates: routeCoords).stroke(.green, lineWidth: 4)
            MapPolygon(coordinates: districtCoords).foregroundStyle(.orange.opacity(0.2))

            UserAnnotation()                       // the user's location dot
        }
    }
}
```

- **`Marker`** — predefined balloon; `Marker(_:coordinate:)`, `Marker(_:systemImage:coordinate:)`, `Marker(_:monogram:coordinate:)`. Style with `.tint(_)`.
- **`Annotation(_:coordinate:) { view }`** — any SwiftUI view anchored to a coordinate; set `.annotationTitles(.hidden)` to suppress the label, `anchor:` to position the view over the point.
- **Overlays:** `MapPolyline(coordinates:)` / `MapPolyline(_ MKPolyline)`, `MapPolygon`, `MapCircle(center:radius:)` — style with `.stroke(_,lineWidth:)` and `.foregroundStyle(_)`.
- **`UserAnnotation()`** — the standard user-location indicator; requires location authorization.
- Wrap dynamic content in `ForEach`; give each item a `.tag(_)` to make it selectable via the `selection:` binding.

<a id="camera"></a>
## Camera (position / MapCamera / changes)

Drive the viewport with a `MapCameraPosition` binding; read changes with `onMapCameraChange`.

```swift
@State private var position: MapCameraPosition = .automatic

// Ways to frame the map:
position = .automatic                                   // frame all content
position = .region(MKCoordinateRegion(center: c, latitudinalMeters: 800, longitudinalMeters: 800))
position = .rect(MKMapRect(...))
position = .item(mapItem)                                // frame an MKMapItem
position = .userLocation(fallback: .automatic)          // follow the user
position = .userLocation(followsHeading: true, fallback: .region(defaultRegion))
position = .camera(MapCamera(centerCoordinate: c, distance: 1_200, heading: 90, pitch: 60))
```

```swift
Map(position: $position) { /* content */ }
    .onMapCameraChange(frequency: .onEnd) { context in
        // context.camera : MapCamera, context.region : MKCoordinateRegion,
        // context.rect : MKMapRect  — e.g. refetch POIs for the visible region
        visibleRegion = context.region
    }
```

- `MapCamera(centerCoordinate:distance:heading:pitch:)` — `distance` is meters from the target; `pitch` tilts (0 = top-down, up to ~60–80° with elevation).
- `frequency`: `.onEnd` (settled — use to trigger network fetches) or `.continuous` (every frame — avoid heavy work).
- Once you set `position` from a *binding the user can pan*, keep it a `@State` binding so user gestures update it back; don't fight the user by re-asserting a fixed region on every render.

<a id="style"></a>
## Style, controls, selection

```swift
Map(position: $position, selection: $selected) { /* ... */ }
    .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .including([.bank, .atm])))
    // .mapStyle(.imagery(elevation: .realistic))
    // .mapStyle(.hybrid(elevation: .flat, showsTraffic: true))
    .mapControls {
        MapUserLocationButton()
        MapCompass()
        MapPitchToggle()
        MapScaleView()
    }
```

- **`selection:`** binds to the `.tag(_)` value of the tapped `Marker`/`Annotation` (any `Hashable`). A `Binding<MKMapItem?>` selects system POIs when you filter them in.
- **`mapControls`** replaces the default control set; omit it to keep defaults. Controls also work standalone with a shared `Namespace` via `Map(scope:)` + `.mapScope(_)` when placed outside the map.
- **`pointsOfInterest`** filter: `.including([...])` / `.excluding([...])` of `MKPointOfInterestCategory` to declutter (e.g. show only `.bank`/`.atm` in a finance app).

<a id="reader"></a>
## MapReader + MapProxy

Wrap the map in `MapReader` to convert between screen points and coordinates.

```swift
MapReader { proxy in
    Map(position: $position) { /* ... */ }
        .onTapGesture { screenPoint in
            if let coord = proxy.convert(screenPoint, from: .local) {
                droppedPin = coord                       // place a pin where tapped
            }
        }
}
```

- `proxy.convert(_ point: CGPoint, from:) -> CLLocationCoordinate2D?` and the inverse `proxy.convert(_ coordinate:, to:) -> CGPoint?`.
- Use coordinate space `.local` for points relative to the map view. Returns `nil` if the point is off-globe or the map isn't laid out yet.

<a id="auth"></a>
## CoreLocation authorization

`CLLocationManager` owns authorization; read `authorizationStatus` (instance property, iOS 14+), never assume a status.

```swift
import CoreLocation

@Observable
final class LocationAuth: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var status: CLAuthorizationStatus
    var accuracy: CLAccuracyAuthorization

    override init() {
        status = manager.authorizationStatus
        accuracy = manager.accuracyAuthorization
        super.init()
        manager.delegate = self
    }

    func request() { manager.requestWhenInUseAuthorization() }

    // Ask for a one-off precise fix when the user granted reduced accuracy.
    func requestPrecise() async {
        try? await manager.requestTemporaryFullAccuracyAuthorization(
            withPurposeKey: "PreciseBranchLocation")   // key in NSLocationTemporaryUsageDescriptionDictionary
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        status = manager.authorizationStatus
        accuracy = manager.accuracyAuthorization
    }
}
```

- Statuses: `.notDetermined`, `.restricted`, `.denied`, `.authorizedWhenInUse`, `.authorizedAlways`. Request `WhenInUse` first; escalate to `Always` only when a background feature (geofencing while closed) truly needs it — iOS prompts once more.
- `accuracyAuthorization`: `.fullAccuracy` / `.reducedAccuracy`. Design for reduced accuracy; upgrade per-use with `requestTemporaryFullAccuracyAuthorization`.
- `.denied`/`.restricted` → surface a "enable in Settings" path (`UIApplication.openSettingsURLString`); never loop re-requesting.
- Full delegate, `Always` escalation, and reduced-accuracy handling in `references/corelocation.md`.

<a id="updates"></a>
## Live location updates (async)

Prefer the modern `CLLocationUpdate.liveUpdates()` async sequence over the delegate for new code — it implicitly holds a `CLServiceSession`, so iterating it is enough to start delivery on iOS 17+.

```swift
func track() async throws {
    for try await update in CLLocationUpdate.liveUpdates() {   // or .liveUpdates(.otherNavigation)
        if update.authorizationDenied || update.authorizationDeniedGlobally { break }
        if update.locationUnavailable { continue }
        if let location = update.location {
            // location.coordinate, .horizontalAccuracy, .speed, .timestamp
            await MainActor.run { self.current = location.coordinate }
        }
    }
}
```

- Configurations: `.default`, `.automotiveNavigation`, `.otherNavigation`, `.fitness`, `.airborne` — tune accuracy/battery for the activity.
- Update flags to branch on: `.authorizationDenied`, `.authorizationDeniedGlobally`, `.authorizationRestricted`, `.authorizationRequestInProgress` (iOS 18+), `.insufficientlyInUse`, `.locationUnavailable`, `.stationary`.
- **Background:** to keep updates while backgrounded, create and **retain** a `CLBackgroundActivitySession()` for the duration; iterating a live sequence in the background without one stops when suspended. `session.invalidate()` when done. Needs the Location Background Mode. See `background-processing`.
- **Do not overwrite** the `AsyncSequence` iterator/session references while iterating — dropping the reference mid-stream can leak or silently stop delivery. Keep one owner.
- The classic delegate (`startUpdatingLocation` / `didUpdateLocations`) still works and is fine for existing code; the async API is the recommended path forward. Delegate version in `references/corelocation.md`.

<a id="monitor"></a>
## Geofencing with CLMonitor

`CLMonitor` (iOS 17+) replaces the old `startMonitoring(for: CLRegion)` API with an async, condition-based model.

```swift
let monitor = await CLMonitor("BranchGeofences")            // named, persists across launches

// Add a circular geofence (radius in meters).
let condition = CLMonitor.CircularGeographicCondition(center: branch.coordinate, radius: 120)
await monitor.add(condition, identifier: branch.id, assuming: .unsatisfied)

for try await event in await monitor.events {
    switch event.state {
    case .satisfied:                                        // entered the region
        notifyNearbyBranch(id: event.identifier)
    case .unsatisfied:                                      // exited
        break
    case .unknown, .unmonitored:
        break
    @unknown default:
        break
    }
    // Prior state for this identifier: await monitor.record(for: event.identifier)?.lastEvent
}
```

- **Limit: 20 conditions** per monitor (system-wide geofence cap). Prioritize the nearest N; swap as the user moves. Exceeding it yields `.unmonitored`.
- `assuming:` seeds the initial state so you don't fire a spurious event at add time.
- Remove with `await monitor.remove(identifier)`.
- Geofences fire in the background only with `Always` authorization plus a retained `CLBackgroundActivitySession`; with `WhenInUse` they deliver only while the app is foreground/active. Full background wiring in `references/corelocation.md`.

<a id="search"></a>
## Place search (MKLocalSearch / completer)

**One-shot search** — `MKLocalSearch` (async `start()`):

```swift
let request = MKLocalSearch.Request()
request.naturalLanguageQuery = "ATM"
request.region = visibleRegion                             // bias to the map's area
request.resultTypes = [.pointOfInterest, .address]
let response = try await MKLocalSearch(request: request).start()
for item in response.mapItems {                            // [MKMapItem]
    print(item.name ?? "", item.placemark.coordinate)
}
```

**As-you-type autocomplete** — `MKLocalSearchCompleter` (delegate-driven):

```swift
@Observable
final class AddressSearch: NSObject, MKLocalSearchCompleterDelegate {
    private let completer = MKLocalSearchCompleter()
    var suggestions: [MKLocalSearchCompletion] = []

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address                   // .address / .pointOfInterest / .query
    }
    func update(_ fragment: String) { completer.queryFragment = fragment }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        suggestions = completer.results
    }
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        suggestions = []
    }
}
```

- Resolve a chosen completion to full coordinates: `MKLocalSearch(request: .init(completion: suggestion)).start()`.
- Bias results with `completer.region` / `request.region` and narrow with `pointOfInterestFilter`.
- Full completer + resolution flow in `references/search-routing-geocoding.md`.

<a id="directions"></a>
## Directions (MKDirections)

```swift
let request = MKDirections.Request()
request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
request.transportType = .automobile                        // .walking, .transit, .cycling (iOS 26)
request.requestsAlternateRoutes = true

let response = try await MKDirections(request: request).calculate()
if let route = response.routes.first {
    // route.distance (m), route.expectedTravelTime (s), route.steps, route.polyline
    self.routePolyline = route.polyline
}
```

Draw the result inside the map's content builder:

```swift
Map(position: $position) {
    if let routePolyline { MapPolyline(routePolyline).stroke(.blue, lineWidth: 5) }
}
```

- `calculate()` returns alternates in `response.routes`; each `MKRoute` has `polyline`, `distance`, `expectedTravelTime`, and turn-by-turn `steps`.
- For arrival estimates only, use `calculateETA()` (cheaper than a full route).
- MapKit rate-limits directions/search requests — debounce user input and cache responses. Details in `references/search-routing-geocoding.md`.

<a id="geocoding"></a>
## Geocoding (CLGeocoder / iOS 26 MapKit)

**iOS 26+ (preferred)** — MapKit's request objects return `MKMapItem`s and are async:

```swift
// Reverse: coordinate → address. Initializer is optional (rejects invalid coords).
if let req = MKReverseGeocodingRequest(location: CLLocation(latitude: lat, longitude: lon)) {
    let item = try await req.mapItems.first
    // item?.name, item?.address (MKAddress)
}
// Forward: address string → place.
if let req = MKGeocodingRequest(addressString: "1 Ferry Building, San Francisco") {
    let coordinate = try await req.mapItems.first?.location.coordinate   // .location is iOS 26+; .placemark is deprecated
}
```

**iOS 17–25 (still supported; `CLGeocoder` is deprecated on iOS 26):**

```swift
let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
let p = placemarks.first    // .thoroughfare, .subThoroughfare, .locality, .postalCode, .country
let forward = try await CLGeocoder().geocodeAddressString("1 Infinite Loop, Cupertino")
```

- `CLGeocoder` is **network-dependent, rate-limited, and processes one request at a time** — don't call it in a tight loop; reuse one instance and debounce.
- On iOS 26 migrate to `MKGeocodingRequest` / `MKReverseGeocodingRequest` (+ `MKAddress` / address representations). Migration notes in `references/search-routing-geocoding.md`.

<a id="lookaround"></a>
## Look Around

360° street-level imagery. Fetch a scene, then present it.

```swift
@State private var scene: MKLookAroundScene?

SomeView()
    .task(id: coordinate) {
        let request = MKLookAroundSceneRequest(coordinate: coordinate)   // or (mapItem:)
        scene = try? await request.scene                                  // nil where unavailable
    }

// Inline SwiftUI preview:
LookAroundPreview(initialScene: scene)
    .frame(height: 180)
```

- Not every coordinate has coverage — `request.scene` returns `nil`; hide the preview when absent.
- `LookAroundPreview(scene:)` (binding) / `LookAroundPreview(initialScene:)`; customize with `allowsNavigation`, `showsRoadLabels`, `pointsOfInterest`, `badgePosition`.
- For full-screen, wrap `MKLookAroundViewController(scene:)` (UIKit) — see `swiftui-uikit-interop`; snippet in `references/search-routing-geocoding.md`.

<a id="checklist"></a>
## Correctness checklist

- [ ] `NSLocationWhenInUseUsageDescription` present; `Always`/temporary-accuracy keys added only if actually requested.
- [ ] Request the narrowest authorization (`WhenInUse` before `Always`); read `authorizationStatus` (instance) rather than assuming.
- [ ] Handle `.reducedAccuracy` gracefully; escalate per-use with `requestTemporaryFullAccuracyAuthorization(withPurposeKey:)`.
- [ ] `.denied`/`.restricted` routes the user to Settings; no re-request loops.
- [ ] `CLLocationUpdate.liveUpdates()` iterator/session held by one owner; not overwritten mid-stream.
- [ ] Background location holds a retained `CLBackgroundActivitySession` + Location Background Mode; invalidated when done.
- [ ] `CLMonitor` stays within the 20-condition cap; `assuming:` seeds initial state; background geofencing uses `Always`.
- [ ] Map `position` is a `@State` binding that user gestures update — no re-asserting a fixed region every render.
- [ ] `onMapCameraChange(frequency: .onEnd)` for network-triggering work; `.continuous` only for cheap UI.
- [ ] `Marker`/`Annotation` given `.tag(_)` when `selection:` is used.
- [ ] Search/directions/geocoding debounced and cached; MapKit rate limits respected.
- [ ] Look Around preview hidden when `request.scene` is `nil`.
- [ ] On iOS 26, new work uses `MKGeocodingRequest`/`MKReverseGeocodingRequest`, not deprecated `CLGeocoder`.
- [ ] Coordinates never logged/transmitted without a user-facing reason (fintech privacy).
