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
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
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

// ✅ Batch delete
func deleteAllUsers() {
    let context = PersistenceController.shared.backgroundContext()

    context.perform {
        let fetchRequest: NSFetchRequest<NSFetchRequestResult> = User.fetchRequest()
        let batchDelete = NSBatchDeleteRequest(fetchRequest: fetchRequest)

        do {
            try context.execute(batchDelete)
            try context.save()
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
// ✅ #Predicate macro
@Query(filter: #Predicate<User> { user in
    user.name.contains("John") && user.createdAt > Date().addingTimeInterval(-86400)
})
var recentJohns: [User]

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
        _users = Query(filter: #Predicate<User> { $0.name.contains(searchText) })
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

    // migrateStore requires BOTH options params (from-store and to-store).
    try migrationManager.migrateStore(
        from: sourceURL,
        sourceType: NSSQLiteStoreType,
        options: nil,
        with: mappingModel,
        toDestinationURL: destinationURL,
        destinationType: NSSQLiteStoreType,
        destinationOptions: nil
    )
}
```

> For iOS 17+, prefer **staged lightweight migration** (`NSStagedMigrationManager` / `NSMigrationStage`) over the manual `NSMigrationManager` path above — it composes automatic + custom steps and is what Apple now recommends. For SwiftData persistence and its own `SchemaMigrationPlan`, see the dedicated **swiftdata** skill.

## Best Practices

```swift
// ✅ Use background context for writes
func batchInsert(items: [Item]) {
    let context = backgroundContext()

    context.perform {
        for item in items {
            let managedItem = Item(context: context)
            managedItem.name = item.name
        }

        try? context.save()
    }
}

// ✅ Batch fetch for large datasets
func fetchAllUsersEfficiently() -> [User] {
    let request = NSFetchRequest<User>(entityName: "User")
    request.returnsObjectsAsFaults = false
    request.fetchBatchSize = 100

    return try! viewContext.fetch(request)
}

// ❌ Don't block main thread
// ❌ Bad: Fetching on main thread with large data
let users = viewContext.fetch(largeRequest)  // Blocks UI

// ✅ Good: Background fetch
let context = backgroundContext()
context.perform {
    let users = try! context.fetch(largeRequest)
    DispatchQueue.main.async {
        // Update UI with results
    }
}
```
