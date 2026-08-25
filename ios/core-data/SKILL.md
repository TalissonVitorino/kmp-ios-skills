---
name: core-data
description: Core Data for iOS persistence. Data models, fetch requests, background contexts, and SwiftData migration.
---

# Core Data

iOS persistence with Core Data and SwiftData.

## Core Data Stack

### Basic Setup

```swift
// ✅ Core Data stack
class PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "DataModel")

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }

        container.loadPersistentStores { description, error in
            if let error = error {
                fatalError("Core Data store failed to load: \(error)")
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        // Use the NSMergePolicy class properties, not the legacy globals:
        // NSMergeByPropertyObjectTrumpMergePolicy & friends import as mutable
        // globals (`var ...: AnyObject`), which is an error under the Swift 6
        // language mode ("not concurrency-safe … shared mutable state").
        container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
    }

    var viewContext: NSManagedObjectContext {
        container.viewContext
    }

    func backgroundContext() -> NSManagedObjectContext {
        container.newBackgroundContext()
    }
}
```

### SwiftUI Integration

```swift
// ✅ @FetchRequest in SwiftUI
struct UserListView: View {
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \User.name, ascending: true)],
        animation: .default)
    private var users: FetchedResults<User>

    var body: some View {
        List {
            ForEach(users) { user in
                Text(user.name ?? "Unknown")
            }
            .onDelete(perform: deleteUsers)
        }
    }

    private func deleteUsers(offsets: IndexSet) {
        withAnimation {
            offsets.map { users[$0] }.forEach(viewContext.delete)

            do {
                try viewContext.save()
            } catch {
                print("Failed to save: \(error)")
            }
        }
    }
}
```

## Fetch Requests

### Basic Fetch

```swift
// ✅ Simple fetch
func fetchUsers() -> [User] {
    let request: NSFetchRequest<User> = User.fetchRequest()
    request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]

    do {
        return try viewContext.fetch(request)
    } catch {
        print("Fetch error: \(error)")
        return []
    }
}

// ✅ With predicate
func fetchUsers(named name: String) -> [User] {
    let request: NSFetchRequest<User> = User.fetchRequest()
    request.predicate = NSPredicate(format: "name == %@", name)
    request.fetchLimit = 1

    do {
        return try viewContext.fetch(request)
    } catch {
        return []
    }
}

// ✅ Complex predicate
func searchUsers(query: String) -> [User] {
    let request: NSFetchRequest<User> = User.fetchRequest()
    request.predicate = NSPredicate(
        format: "name CONTAINS[cd] %@ OR email CONTAINS[cd] %@",
        query, query
    )
    request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]

    do {
        return try viewContext.fetch(request)
    } catch {
        return []
    }
}
```

## Background Context

### Background Operations

```swift
// ✅ Perform background write
func saveUser(name: String, email: String) {
    let context = PersistenceController.shared.backgroundContext()

    context.perform {
        let user = User(context: context)
        user.name = name
        user.email = email
        user.createdAt = Date()

        do {
            try context.save()
        } catch {
            print("Failed to save: \(error)")
        }
    }
}

// ✅ Batch delete — runs at the SQL level (SQLite stores only); contexts do NOT
// see the deletions automatically, and there is nothing to save() afterwards.
// Return the deleted objectIDs and merge them into live contexts.
func deleteAllUsers() {
    let context = PersistenceController.shared.backgroundContext()

    context.perform {
        let fetchRequest: NSFetchRequest<NSFetchRequestResult> = User.fetchRequest()
        let batchDelete = NSBatchDeleteRequest(fetchRequest: fetchRequest)
        batchDelete.resultType = .resultTypeObjectIDs

        do {
            let result = try context.execute(batchDelete) as? NSBatchDeleteResult
            if let objectIDs = result?.result as? [NSManagedObjectID] {
                NSManagedObjectContext.mergeChanges(
                    fromRemoteContextSave: [NSDeletedObjectsKey: objectIDs],
                    into: [PersistenceController.shared.viewContext]
                )
            }
        } catch {
            print("Batch delete failed: \(error)")
        }
    }
}
```

## Relationships

### Modeling Relationships

```swift
// ✅ To-One relationship
extension User {
    @NSManaged var department: Department?
}

// ✅ To-Many relationship
extension Department {
    @NSManaged var employees: NSSet?

    var employeesArray: [User] {
        let set = employees as? Set<User> ?? []
        return set.sorted { $0.name ?? "" < $1.name ?? "" }
    }
}

// ✅ Fetch with relationship
func fetchUsers(in departmentName: String) -> [User] {
    let request: NSFetchRequest<User> = User.fetchRequest()
    request.predicate = NSPredicate(format: "department.name == %@", departmentName)

    do {
        return try viewContext.fetch(request)
    } catch {
        return []
    }
}
```

## SwiftData (iOS 17+)

### Basic SwiftData

```swift
// ✅ SwiftData model
@Model
final class User {
    var name: String
    var email: String
    var createdAt: Date

    init(name: String, email: String) {
        self.name = name
        self.email = email
        self.createdAt = Date()
    }
}

// ✅ SwiftData setup
@main
struct MyApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([User.self])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}

// ✅ @Query in SwiftUI
struct UserListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \User.name, order: .forward) private var users: [User]

    var body: some View {
        List {
            ForEach(users) { user in
                Text(user.name)
            }
            .onDelete(perform: deleteUsers)
        }
    }

    private func deleteUsers(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(users[index])
            }
        }
    }
}
```

### SwiftData Predicates

```swift
// ✅ #Predicate macro — only literals and captured values are allowed inside the
// closure; expressions like Date() or Calendar calls do NOT compile in a predicate
// body. Compute them outside and capture the result.
// @Query is a property wrapper, so it must be declared inside a View —
// Swift rejects property wrappers on global/file-scope variables.
struct JohnsView: View {
    @Query(filter: #Predicate<User> { $0.name.contains("John") })
    private var johns: [User]

    var body: some View {
        List(johns) { Text($0.name) }
    }
}

// ✅ Dynamic predicate
struct UserListView: View {
    @State private var searchText = ""

    var body: some View {
        UserList(searchText: searchText)
    }
}

struct UserList: View {
    @Query private var users: [User]

    // A dynamic @Query must be initialized in init — it cannot be declared inside body.
    init(searchText: String) {
        let dayAgo = Date.now.addingTimeInterval(-86400)  // computed outside, captured
        _users = Query(filter: #Predicate<User> {
            $0.name.contains(searchText) && $0.createdAt > dayAgo
        })
    }

    var body: some View {
        List(users) { user in
            Text(user.name)
        }
    }
}
```

## Migration

### Lightweight Migration

```swift
let description = NSPersistentStoreDescription(url: storeURL)
description.shouldInferMappingModelAutomatically = true
description.shouldMigrateStoreAutomatically = true
```

Both flags default to `true`, so `NSPersistentContainer` performs lightweight migration automatically — set them explicitly only to document intent or re-enable after a custom setup turned them off.

### Migration Strategy

```swift
// ✅ Custom mapping model — NSMigrationManager is built from the MODELS, not the store URLs.
func migrateStore(at sourceURL: URL, to destinationURL: URL,
                  sourceModel: NSManagedObjectModel,
                  destinationModel: NSManagedObjectModel,
                  mappingModel: NSMappingModel) throws {
    let migrationManager = NSMigrationManager(
        sourceModel: sourceModel,
        destinationModel: destinationModel
    )

    // iOS 15+ typed overload; the older string-typed
    // migrateStore(from:sourceType:options:with:toDestinationURL:...) is deprecated.
    try migrationManager.migrateStore(
        from: sourceURL,
        type: .sqlite,
        mapping: mappingModel,
        to: destinationURL,
        type: .sqlite
    )
}
```

> For iOS 17+, prefer **staged lightweight migration** (`NSStagedMigrationManager` / `NSMigrationStage`) over the manual `NSMigrationManager` path above — it composes automatic + custom steps and is what Apple now recommends. For SwiftData persistence and its own `SchemaMigrationPlan`, see the dedicated **swiftdata** skill.

## Best Practices

```swift
// ✅ Use background context for writes (for very large imports prefer NSBatchInsertRequest)
// Pass value types into the perform block — not managed objects from another context.
struct ItemDTO { let name: String }

func batchInsert(items: [ItemDTO]) {
    let context = backgroundContext()

    context.perform {
        for item in items {
            let managedItem = Item(context: context)
            managedItem.name = item.name
        }

        try? context.save()
    }
}

// ✅ Batch fetch for large datasets — fetchBatchSize loads rows lazily in chunks.
// Don't combine with returnsObjectsAsFaults = false: that forces every object
// fully into memory and defeats the batching.
func fetchAllUsersEfficiently() -> [User] {
    let request = NSFetchRequest<User>(entityName: "User")
    request.fetchBatchSize = 100

    return (try? viewContext.fetch(request)) ?? []
}

// ❌ Bad: fetching large data on the main thread blocks the UI
let users = try viewContext.fetch(largeRequest)

// ✅ Good: fetch in background, hand objectIDs to the main thread.
// NSManagedObject is NOT thread-safe — never pass instances between contexts;
// pass NSManagedObjectID (or plain value types) instead.
let context = backgroundContext()
context.perform {
    let ids = ((try? context.fetch(largeRequest)) ?? []).map(\.objectID)
    DispatchQueue.main.async {
        let users = ids.compactMap { viewContext.object(with: $0) as? User }
        // Update UI with users
    }
}
```
