# Search, routing, geocoding & Look Around depth

Companion to the `mapkit` skill.

## MKLocalSearchCompleter → resolve → map

Full as-you-type flow: feed fragments, show completions, resolve the chosen one
to coordinates with `MKLocalSearch`.

```swift
import MapKit

@Observable
final class PlaceSearch: NSObject, MKLocalSearchCompleterDelegate {
    private let completer = MKLocalSearchCompleter()
    var suggestions: [MKLocalSearchCompletion] = []
    var region: MKCoordinateRegion? { didSet { if let region { completer.region = region } } }

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        completer.pointOfInterestFilter = MKPointOfInterestFilter(including: [.bank, .atm])
    }

    func update(_ fragment: String) {
        completer.queryFragment = fragment          // debounce upstream; empty clears results
    }

    func completerDidUpdateResults(_ c: MKLocalSearchCompleter) { suggestions = c.results }
    func completer(_ c: MKLocalSearchCompleter, didFailWithError error: Error) { suggestions = [] }

    /// Turn a tapped suggestion into a concrete place with coordinates.
    func resolve(_ suggestion: MKLocalSearchCompletion) async throws -> MKMapItem? {
        let response = try await MKLocalSearch(request: .init(completion: suggestion)).start()
        return response.mapItems.first
    }
}
```

- `MKLocalSearchCompletion` gives `title` + `subtitle` for display and `titleHighlightRanges` for bolding the matched substring — it is **not** a coordinate. You must resolve it.
- Debounce `queryFragment` (e.g. 250–300 ms) in your view model; the completer already coalesces, but you avoid wasted work and rate-limit pressure.
- `resultTypes`: `.address`, `.pointOfInterest`, `.query`. Narrow with `pointOfInterestFilter` and bias with `region`.

## MKLocalSearch one-shot vs. region bias

```swift
let req = MKLocalSearch.Request()
req.naturalLanguageQuery = "coffee"
req.region = visibleRegion              // strongly biases toward this area
req.resultTypes = [.pointOfInterest]
let response = try await MKLocalSearch(request: req).start()
// response.mapItems : [MKMapItem]; response.boundingRegion frames them
```

- `MKMapItem`: `name`, `placemark` (`coordinate`, address components), `pointOfInterestCategory`, `phoneNumber`, `url`. `openInMaps(launchOptions:)` hands off to Maps.app.

## MKDirections — routes and overlay

```swift
let request = MKDirections.Request()
request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
request.destination = destinationMapItem
request.transportType = .automobile     // .walking, .transit, .cycling (iOS 26)
request.requestsAlternateRoutes = true
request.departureDate = .now            // transit/ETA planning

let directions = MKDirections(request: request)
let response = try await directions.calculate()          // full routes
// let eta = try await directions.calculateETA()         // arrival only, cheaper

for route in response.routes {
    // route.name, route.distance, route.expectedTravelTime, route.advisoryNotices
    for step in route.steps {
        // step.instructions, step.distance, step.polyline, step.notice
    }
}
```

Render the primary route:

```swift
Map(position: $position) {
    ForEach(response.routes, id: \.self) { route in
        MapPolyline(route.polyline)
            .stroke(route == response.routes.first ? .blue : .gray, lineWidth: route == response.routes.first ? 6 : 3)
    }
}
```

- A single `MKDirections` instance calculates once — create a fresh one per request; call `cancel()` to abort in-flight.
- Rate-limited: debounce recalculation on rapid origin/destination changes and cache by (source, destination, transportType).

## Geocoding — legacy and iOS 26

### CLGeocoder (iOS 17–25; deprecated on iOS 26)

```swift
let geocoder = CLGeocoder()                              // reuse one instance
let places = try await geocoder.reverseGeocodeLocation(location)   // [CLPlacemark]
if let p = places.first {
    // p.name, p.thoroughfare, p.subThoroughfare, p.locality, p.administrativeArea,
    // p.postalCode, p.country, p.isoCountryCode, p.location
}
let forward = try await geocoder.geocodeAddressString("1 Apple Park Way, Cupertino")
```

- **One request at a time, network-required, rate-limited.** Serialize calls; catch `CLError.network`/`.geocodeFoundNoResult`. Never call inside a `ForEach`/loop over many rows.

### MapKit geocoding (iOS 26+, preferred)

```swift
// Reverse — initializer is optional; rejects invalid coordinates.
if let req = MKReverseGeocodingRequest(location: CLLocation(latitude: lat, longitude: lon)) {
    let items = try await req.mapItems               // [MKMapItem]
    let address = items.first?.address               // MKAddress
}

// Forward.
if let req = MKGeocodingRequest(addressString: "1 Ferry Building, San Francisco") {
    let coordinate = try await req.mapItems.first?.location.coordinate   // .location is iOS 26+; .placemark is deprecated
}
```

- Returns `MKMapItem`s (unifying with search/directions) and `MKAddress` / address-representation types that pick the most appropriate address for a region.
- Migration: swap `CLPlacemark` field access for `MKMapItem.address`; the async request objects replace `CLGeocoder`'s completion/async methods.
- For richer place lookup without a MapKit place ID, `GeoToolbox`'s `PlaceDescriptor` carries identifying info a mapping service can resolve to phone/website/etc.

## Look Around full-screen (UIKit interop)

```swift
import MapKit
import SwiftUI

struct LookAroundScreen: UIViewControllerRepresentable {
    let scene: MKLookAroundScene
    func makeUIViewController(context: Context) -> MKLookAroundViewController {
        let vc = MKLookAroundViewController(scene: scene)
        vc.showsRoadLabels = true
        return vc
    }
    func updateUIViewController(_ vc: MKLookAroundViewController, context: Context) {
        vc.scene = scene
    }
}
```

- Fetch the scene first with `MKLookAroundSceneRequest(coordinate:)` or `(mapItem:)`; guard against `nil` (no coverage).
- See `swiftui-uikit-interop` for the representable lifecycle and coordinator patterns.
