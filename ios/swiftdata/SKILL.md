---
name: swiftdata
description: Apple SwiftData for iOS 17+ persistence - the @Model macro, ModelContainer and ModelContext, the @Query property wrapper with #Predicate and SortDescriptor, @Relationship with delete rules, @Attribute(.unique), the .modelContainer SwiftUI modifier, and insert/delete/save. Use when persisting data in a native iOS app with SwiftData, building local-first storage, or migrating from Core Data. For the older Core Data API use core-data; for shared KMP persistence used across Android and iOS use sqldelight-patterns; for SwiftUI state around models use swiftui-observation.
---

# SwiftData (iOS 17+)

## Overview

SwiftData is Apple's modern persistence framework (iOS 17+), built on Core Data but Swift-native. You declare models with the `@Model` macro; a `ModelContainer` holds the store, a `ModelContext` performs inserts/updates/deletes, and `@Query` drives SwiftUI views reactively.

## When to use

- Local persistence in a native iOS app (iOS 17+)
- SwiftUI-driven, reactive data display
- Migrating from Core Data to a Swift-native API
- NOT for code shared with Android → use `sqldelight-patterns`

## Model

```swift
import SwiftData

@Model
final class Plant {                          // must be a final class, not a struct
    @Attribute(.unique) var id: UUID
    var name: String
    var plantedOn: Date
    @Relationship(deleteRule: .cascade) var waterings: [Watering] = []

    init(name: String, plantedOn: Date = .now) {
        self.id = UUID(); self.name = name; self.plantedOn = plantedOn
    }
}
```

## Container (app entry)

```swift
@main
struct GardenApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .modelContainer(for: Plant.self)   // creates the ModelContainer + store
    }
}
```

## Query + mutate in a view

```swift
struct PlantList: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Plant.plantedOn, order: .reverse) private var plants: [Plant]

    var body: some View {
        List(plants) { Text($0.name) }
        Button("Add") { context.insert(Plant(name: "Fern")) }   // autosaved
    }
}

// Filtered query with a type-safe predicate
@Query(filter: #Predicate<Plant> { $0.name.contains("Fern") })
private var ferns: [Plant]
```

Explicit delete/save:

```swift
context.delete(plant)
try context.save()        // usually autosaved; call when you need it deterministic
```

## Common mistakes

| Mistake | Fix |
|---|---|
| Forgetting `.modelContainer(...)` | Without it `@Query` / `modelContext` have no store |
| Using `NSPredicate` | Use the type-safe `#Predicate<T> { … }` |
| Heavy writes on the main context | Use a separate `ModelContext` / `@ModelActor` off the main actor |
| `@Model` on a struct | `@Model` requires a `final class` |
| Targeting below iOS 17 | SwiftData is iOS 17+; fall back to `core-data` |

## See also

- Older Apple persistence API: `core-data`
- Shared KMP persistence (Android + iOS): `sqldelight-patterns`
- SwiftUI state around models: `swiftui-observation`
- Background work / actors: `swift-concurrency`
