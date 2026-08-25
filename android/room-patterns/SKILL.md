---
name: room-patterns
description: Room persistence for the Android target (androidx.room) - @Entity, @Dao, RoomDatabase, migrations, TypeConverters, and Flow-returning queries. Android-side database. For shared/multiplatform persistence in commonMain use sqldelight-patterns. For the broader Android data layer (Repository pattern, Room plus remote sources, offline-first sync) see android-skills:android-data-layer.
---

# Room Database Patterns

## Dependencies (build.gradle.kts)

```kotlin
plugins {
    id("com.google.devtools.ksp") version "2.3.10"
    id("androidx.room") version "2.8.4" // Room Gradle plugin: schema location + auto-migration wiring
}

room {
    schemaDirectory("$projectDir/schemas")
}

dependencies {
    val roomVersion = "2.8.4"
    implementation("androidx.room:room-runtime:$roomVersion")
    ksp("androidx.room:room-compiler:$roomVersion")
    testImplementation("androidx.room:room-testing:$roomVersion")
}
```

> **Artifacts.** `room-ktx` was merged into `room-runtime` in 2.7.0 — the artifact is now empty, remove it. `room-testing`, `room-paging`, `room-rxjava3`, `room-guava` remain separate.

### Room 2.x vs Room 3

Room 3.0 is stable (3.0.1, July 2026) under new coordinates: `androidx.room3:room3-runtime` / `room3-compiler`, Gradle plugin id `androidx.room3` with a `room3 { schemaDirectory(...) }` extension, package `androidx.room3`. `androidx.room` 2.8.x is in maintenance mode — bug-fix patches only, no new features. Stay on 2.8.x for an existing Android-only codebase; start new code, and anything heading to KMP, on `androidx.room3`.

Room 3 differences that break the snippets below:

- Kotlin-only codegen, KSP-only — no KAPT, no Java annotation processing.
- Coroutines-first: every non-reactive DAO function must be `suspend`; blocking DAO functions are rejected at compile time.
- SupportSQLite is gone in favor of the `androidx.sqlite` driver API. `Migration.migrate(db: SupportSQLiteDatabase)` becomes `abstract suspend fun migrate(connection: SQLiteConnection)`, and `openHelper.writableDatabase` becomes `roomDatabase.getSupportWrapper()` from the `room3-sqlite-wrapper` bridge artifact.
- Non-scalar DAO return types are opt-in: register the converter class with `@DaoReturnTypeConverters(...)` on the `@Dao` or `@Database` (`@DaoReturnTypeConverter` annotates the converter function itself). `PagingSource` needs `@DaoReturnTypeConverters(PagingSourceDaoReturnTypeConverter::class)` from `room3-paging`; `LiveData` needs `LiveDataDaoReturnTypeConverter` from `room3-livedata`. Without it KSP fails with "Not sure how to convert the query result to this function's return type".

Room 2.7+ already exposes the driver APIs (`setDriver(BundledSQLiteDriver())`, `setQueryCoroutineContext(...)`), so migrating to those first makes the 3.0 jump mechanical.

## Entity Definitions

```kotlin
@Entity(
    tableName = "users",
    indices = [
        Index(value = ["email"], unique = true),
        Index(value = ["created_at"])
    ]
)
data class UserEntity(
    @PrimaryKey(autoGenerate = true)
    val id: Long = 0,

    @ColumnInfo(name = "display_name")
    val displayName: String,

    @ColumnInfo(name = "email")
    val email: String,

    @ColumnInfo(name = "avatar_url")
    val avatarUrl: String? = null,

    @ColumnInfo(name = "created_at")
    val createdAt: Long = System.currentTimeMillis(),

    @Ignore
    val isOnline: Boolean = false
)
```

### Embedded Objects

```kotlin
data class Address(
    val street: String,
    val city: String,
    @ColumnInfo(name = "zip_code") val zipCode: String
)

@Entity(tableName = "profiles")
data class ProfileEntity(
    @PrimaryKey val userId: Long,
    @Embedded(prefix = "address_") val address: Address
)
```

### Relations

```kotlin
data class UserWithPosts(
    @Embedded val user: UserEntity,
    @Relation(
        parentColumn = "id",
        entityColumn = "author_id"
    )
    val posts: List<PostEntity>
)
```

## DAO Interfaces

```kotlin
@Dao
interface UserDao {

    @Query("SELECT * FROM users ORDER BY created_at DESC")
    fun observeAll(): Flow<List<UserEntity>>

    @Query("SELECT * FROM users WHERE id = :userId")
    fun observeById(userId: Long): Flow<UserEntity?>

    @Query("SELECT * FROM users WHERE email = :email LIMIT 1")
    suspend fun findByEmail(email: String): UserEntity?

    @Upsert
    suspend fun upsert(user: UserEntity): Long

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertIfNotExists(users: List<UserEntity>): List<Long>

    @Update
    suspend fun update(user: UserEntity)

    @Delete
    suspend fun delete(user: UserEntity)

    @Query("DELETE FROM users WHERE id = :userId")
    suspend fun deleteById(userId: Long)

    @Transaction
    @Query("SELECT * FROM users WHERE id = :userId")
    fun observeUserWithPosts(userId: Long): Flow<UserWithPosts?>

    @Transaction
    suspend fun replaceAll(users: List<UserEntity>) {
        deleteAll()
        insertIfNotExists(users)
    }

    @Query("DELETE FROM users")
    suspend fun deleteAll()
}
```

## TypeConverters

```kotlin
class Converters {

    @TypeConverter
    fun fromDate(date: Date?): Long? = date?.time

    @TypeConverter
    fun toDate(timestamp: Long?): Date? = timestamp?.let { Date(it) }

    @TypeConverter
    fun fromStatus(status: UserStatus): String = status.name

    @TypeConverter
    fun toStatus(value: String): UserStatus = UserStatus.valueOf(value)

    @TypeConverter
    fun fromStringList(list: List<String>): String =
        Json.encodeToString(list)

    @TypeConverter
    fun toStringList(value: String): List<String> =
        Json.decodeFromString(value)
}
```

## Database Class

```kotlin
@Database(
    entities = [
        UserEntity::class,
        PostEntity::class,
        ProfileEntity::class
    ],
    version = 2,
    exportSchema = true
)
@TypeConverters(Converters::class)
abstract class AppDatabase : RoomDatabase() {
    abstract fun userDao(): UserDao
    abstract fun postDao(): PostDao
}
```

## Migration Strategy

```kotlin
val MIGRATION_1_2 = object : Migration(1, 2) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("ALTER TABLE users ADD COLUMN avatar_url TEXT")
        db.execSQL(
            "CREATE INDEX IF NOT EXISTS index_users_created_at ON users(created_at)"
        )
    }
}

// Destructive fallback for development
// (the no-arg overload is deprecated since 2.7)
val database = Room.databaseBuilder(context, AppDatabase::class.java, "app.db")
    .addMigrations(MIGRATION_1_2)
    .fallbackToDestructiveMigration(dropAllTables = true) // only in debug builds
    .build()
```

### Auto-migrations

Room derives the SQL by diffing the exported schema JSONs, so the plugin's `schemaDirectory` is a hard prerequisite. Purely additive changes (new table, new nullable column, new NOT NULL column carrying `@ColumnInfo(defaultValue = ...)`) need no code:

```kotlin
@Database(
    entities = [...],
    version = 3,
    autoMigrations = [AutoMigration(from = 2, to = 3)]
)
```

Changes Room cannot infer — dropped or renamed columns and tables — need a spec:

```kotlin
@RenameColumn(tableName = "users", fromColumnName = "avatar_url", toColumnName = "photo_url")
class RenamePhotoUrl : AutoMigrationSpec

// AutoMigration(from = 3, to = 4, spec = RenamePhotoUrl::class)
```

Auto- and manual migrations coexist across different version pairs; if both are declared for the *same* pair, Room runs the manual `Migration`.

## Room + Koin Injection

```kotlin
val databaseModule = module {
    single {
        Room.databaseBuilder(
            androidContext(),
            AppDatabase::class.java,
            "app.db"
        )
        .addMigrations(MIGRATION_1_2)
        .build()
    }
    single { get<AppDatabase>().userDao() }
    single { get<AppDatabase>().postDao() }
}
```

## Room + Kotlin Flow Integration

```kotlin
class UserRepository(private val userDao: UserDao) {

    val allUsers: Flow<List<UserEntity>> = userDao.observeAll()

    fun observeUser(id: Long): Flow<UserEntity?> = userDao.observeById(id)

    suspend fun addUser(user: UserEntity): Long = userDao.upsert(user)

    suspend fun removeUser(userId: Long) = userDao.deleteById(userId)
}

// In ViewModel
class UserListViewModel(
    private val repository: UserRepository
) : ViewModel() {

    val users: StateFlow<List<UserEntity>> = repository.allUsers
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
}
```

## Testing with In-Memory Database

```kotlin
@RunWith(AndroidJUnit4::class)
class UserDaoTest {

    private lateinit var database: AppDatabase
    private lateinit var userDao: UserDao

    @Before
    fun setup() {
        database = Room.inMemoryDatabaseBuilder(
            ApplicationProvider.getApplicationContext(),
            AppDatabase::class.java
        )
        .allowMainThreadQueries()
        .build()
        userDao = database.userDao()
    }

    @After
    fun tearDown() {
        database.close()
    }

    @Test
    fun insertAndRetrieveUser() = runTest {
        val user = UserEntity(displayName = "Alice", email = "alice@test.com")
        val id = userDao.upsert(user)

        val result = userDao.findByEmail("alice@test.com")
        assertNotNull(result)
        assertEquals("Alice", result?.displayName)
    }

    @Test
    fun observeUsersEmitsCurrentRows() = runTest {
        userDao.upsert(UserEntity(displayName = "Bob", email = "bob@test.com"))

        val users = userDao.observeAll().first()
        assertEquals("Bob", users.single().displayName)
    }
}
```

> Do not assert on *subsequent* emissions with `advanceUntilIdle()`. Room's `InvalidationTracker` delivers on its own real background executor, which the `runTest` virtual clock does not drive, so the assertion races the refresh. To make invalidation deterministic, build the database with `.setQueryCoroutineContext(StandardTestDispatcher(testScheduler))` (Room 2.7+) — but note that a single-threaded dispatcher deadlocks on `@Transaction` DAO functions, which need a thread to themselves. Otherwise collect with Turbine and let it wait in real time.

## Best Practices

- Always use `Flow` return types for reactive queries; use `suspend` for one-shot operations.
- Prefer `@Upsert` (Room 2.5+) over `@Insert(onConflict = REPLACE)`: REPLACE deletes then re-inserts, which fires `ON DELETE` cascades and deletes FK children; `@Upsert` does insert-or-update. Use `IGNORE` for insert-if-absent.
- Export schemas (`exportSchema = true`, default) and set `schemaDirectory` via the Room Gradle plugin; commit the JSON files — they drive `MigrationTestHelper` and `@AutoMigration`.
- Use `@Transaction` for queries returning relations or when performing multi-step writes.
- Keep entity classes as pure data holders; map to domain models in the repository layer.
- Use KSP instead of KAPT for Room annotation processing (faster build times).
- Test migrations with `MigrationTestHelper` from `room-testing`.
