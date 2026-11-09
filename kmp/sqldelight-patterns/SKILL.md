---
name: sqldelight-patterns
description: SQLDelight for Kotlin Multiplatform shared persistence - .sq files in commonMain, platform drivers (AndroidSqliteDriver on Android, NativeSqliteDriver on iOS), type adapters, migrations, and a shared database accessed from common code. Use for multiplatform or shared persistence. For Android-only Room use room-patterns.
---

# SQLDelight Patterns for KMP

## Gradle Plugin Configuration

```kotlin
// build.gradle.kts (shared module)
plugins {
    id("app.cash.sqldelight") version "2.4.1"
}

sqldelight {
    databases {
        create("AppDatabase") {
            packageName.set("com.example.db")
            schemaOutputDirectory.set(file("src/commonMain/sqldelight/databases"))
            verifyMigrations.set(true)
        }
    }
}

// Dependencies
kotlin {
    sourceSets {
        commonMain.dependencies {
            implementation("app.cash.sqldelight:coroutines-extensions:2.4.1")
            implementation("app.cash.sqldelight:primitive-adapters:2.4.1")
        }
        androidMain.dependencies {
            implementation("app.cash.sqldelight:android-driver:2.4.1")
        }
        iosMain.dependencies {
            implementation("app.cash.sqldelight:native-driver:2.4.1")
        }
    }
}
```

## .sq File Syntax

Place `.sq` files in `src/commonMain/sqldelight/com/example/db/`.

### Table Definitions

```sql
-- User.sq
import com.example.db.UserStatus;
import kotlin.time.Instant;

CREATE TABLE User (
    id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    display_name TEXT NOT NULL,
    email TEXT NOT NULL UNIQUE,
    avatar_url TEXT,
    status TEXT AS UserStatus NOT NULL DEFAULT 'active',
    created_at INTEGER AS Instant NOT NULL
);

CREATE INDEX idx_user_email ON User(email);
CREATE INDEX idx_user_created_at ON User(created_at);
```

### Named Queries

```sql
-- User.sq (continued)

selectAll:
SELECT * FROM User ORDER BY created_at DESC;

selectById:
SELECT * FROM User WHERE id = ?;

selectByEmail:
SELECT * FROM User WHERE email = ?;

selectByStatus:
SELECT * FROM User WHERE status = :status;

insert:
INSERT OR REPLACE INTO User(display_name, email, avatar_url, status, created_at)
VALUES (?, ?, ?, ?, ?);

updateDisplayName:
UPDATE User SET display_name = ? WHERE id = ?;

deleteById:
DELETE FROM User WHERE id = ?;

deleteAll:
DELETE FROM User;

countByStatus:
SELECT COUNT(*) FROM User WHERE status = ?;
```

### Parameterized Queries with Joins

```sql
-- Post.sq

CREATE TABLE Post (
    id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    author_id INTEGER NOT NULL REFERENCES User(id),
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    published_at INTEGER
);

selectWithAuthor:
SELECT Post.*, User.display_name AS author_name
FROM Post
INNER JOIN User ON Post.author_id = User.id
WHERE Post.id = ?;

selectByAuthorId:
SELECT * FROM Post WHERE author_id = ? ORDER BY published_at DESC;
```

## Platform Driver Setup

### Common Interface

```kotlin
// commonMain
expect class DriverFactory {
    fun createDriver(): SqlDriver
}

fun createDatabase(driverFactory: DriverFactory): AppDatabase {
    val driver = driverFactory.createDriver()
    return AppDatabase(
        driver = driver,
        UserAdapter = User.Adapter(
            statusAdapter = statusAdapter,
            created_atAdapter = instantAdapter
        )
    )
}
```

### Android Driver

```kotlin
// androidMain
actual class DriverFactory(private val context: Context) {
    actual fun createDriver(): SqlDriver {
        return AndroidSqliteDriver(
            schema = AppDatabase.Schema,
            context = context,
            name = "app.db"
        )
    }
}
```

### iOS Driver

```kotlin
// iosMain
actual class DriverFactory {
    actual fun createDriver(): SqlDriver {
        return NativeSqliteDriver(
            schema = AppDatabase.Schema,
            name = "app.db"
        )
    }
}
```

## Type Adapters

SQLite stores only `INTEGER`, `REAL`, `TEXT`, `BLOB`. Any other Kotlin type declared with `AS` needs a `ColumnAdapter` passed to the generated `<Table>.Adapter`. Two exceptions worth knowing:

- Plain narrowing (`INTEGER AS Int`, `REAL AS Float`) is covered by `IntColumnAdapter` / `FloatColumnAdapter` in `primitive-adapters` — do not hand-write these.
- `INTEGER AS Boolean` is handled natively by the SQLite dialect with no adapter, but since 2.0 every primitive used in a `.sq`/`.sqm` file must be imported explicitly: `import kotlin.Boolean;`.

```kotlin
// Enum adapter
val statusAdapter = object : ColumnAdapter<UserStatus, String> {
    override fun decode(databaseValue: String): UserStatus =
        UserStatus.valueOf(databaseValue)

    override fun encode(value: UserStatus): String =
        value.name
}

// Instant adapter (import kotlin.time.Instant — moved out of kotlinx.datetime in datetime 0.7)
val instantAdapter = object : ColumnAdapter<Instant, Long> {
    override fun decode(databaseValue: Long): Instant =
        Instant.fromEpochMilliseconds(databaseValue)

    override fun encode(value: Instant): Long =
        value.toEpochMilliseconds()
}

// Usage in database creation
val database = AppDatabase(
    driver = driver,
    UserAdapter = User.Adapter(
        statusAdapter = statusAdapter,
        created_atAdapter = instantAdapter
    )
)
```

## Migration Strategy

Place `.sqm` files in `src/commonMain/sqldelight/migrations/` (a sibling of the package folders holding `.sq` files). Do not put them in `databases/` — that is the `schemaOutputDirectory`, which holds the generated `.db` schema snapshots used for verification.

A migration file is named `<version to upgrade from>.sqm`, and the first schema version is 1. The `.sq` files always describe the *current* schema and are what `Schema.create()` runs on a fresh install; `.sqm` files only describe upgrades, so a column that appears in a `.sqm` is expected to also be present in the `CREATE TABLE`.

```sql
-- 1.sqm (upgrades version 1 -> 2)
ALTER TABLE User ADD COLUMN avatar_url TEXT;

-- 2.sqm (upgrades version 2 -> 3)
CREATE INDEX idx_user_created_at ON User(created_at);
ALTER TABLE User ADD COLUMN status TEXT NOT NULL DEFAULT 'active';
```

Verification is two settings, both shown in the Gradle block above:

- `verifyMigrations` defaults to `false`; setting it to `true` fails the build on a broken migration, and also when no `.db` snapshot is found at all.
- `schemaOutputDirectory` is unset by default. It does **not** gate verification — `verify<SourceSet><Database>Migration` is registered whenever `deriveSchemaFromMigrations` is off (the default) and is wired into both `check` and the aggregate `verifySqlDelightMigration` task. What `schemaOutputDirectory` gates is `generate<SourceSet><Database>Schema`, the task that *writes* the snapshots; without snapshots the verify task runs but has nothing to compare against.

So generate a `.db` snapshot of each released schema version with `./gradlew generateCommonMainAppDatabaseSchema` before writing the next migration. The verify task then replays the `.sqm` files onto each snapshot and asserts the result matches the current `.sq` schema.

## Coroutines Flow Extension

```kotlin
import app.cash.sqldelight.coroutines.asFlow
import app.cash.sqldelight.coroutines.mapToList
import app.cash.sqldelight.coroutines.mapToOneOrNull

class UserRepository(private val database: AppDatabase) {

    fun observeAll(): Flow<List<User>> =
        database.userQueries.selectAll()
            .asFlow()
            .mapToList(Dispatchers.IO)

    fun observeById(id: Long): Flow<User?> =
        database.userQueries.selectById(id)
            .asFlow()
            .mapToOneOrNull(Dispatchers.IO)

    suspend fun insert(user: User) = withContext(Dispatchers.IO) {
        database.userQueries.insert(
            display_name = user.display_name,
            email = user.email,
            avatar_url = user.avatar_url,
            status = user.status,
            created_at = user.created_at
        )
    }

    suspend fun deleteById(id: Long) = withContext(Dispatchers.IO) {
        database.userQueries.deleteById(id)
    }

    suspend fun replaceAll(users: List<User>) = withContext(Dispatchers.IO) {
        database.transaction {
            database.userQueries.deleteAll()
            users.forEach { user ->
                database.userQueries.insert(
                    display_name = user.display_name,
                    email = user.email,
                    avatar_url = user.avatar_url,
                    status = user.status,
                    created_at = user.created_at
                )
            }
        }
    }
}
```

Two things this example depends on:

- Generated row classes keep the column names verbatim (`display_name`, not `displayName`). Either use the snake_case names, or map the generated row to a domain model at the repository boundary so snake_case does not leak upward.
- `Dispatchers.IO` lives in the JVM + Native source sets of kotlinx-coroutines, so it resolves from `commonMain` only while every target of that source set is Android/JVM or Native. Add a JS or wasm target and it disappears — switch to an `expect val ioDispatcher: CoroutineDispatcher` (or `Dispatchers.Default`) then.

## KMP Module Structure

```
shared/
  src/
    commonMain/
      kotlin/com/example/db/
        DriverFactory.kt          (expect class)
        DatabaseModule.kt         (Koin module)
        UserRepository.kt
      sqldelight/com/example/db/
        User.sq
        Post.sq
      sqldelight/migrations/
        1.sqm
      sqldelight/databases/
        1.db                      (generated schema snapshot)
    androidMain/
      kotlin/com/example/db/
        DriverFactory.android.kt  (actual class)
    iosMain/
      kotlin/com/example/db/
        DriverFactory.ios.kt      (actual class)
```

## Testing with In-Memory Driver

`JdbcSqliteDriver` is JVM-only (`app.cash.sqldelight:sqlite-driver:2.4.1`) — put these tests in `jvmTest` or `androidUnitTest`, not `commonTest`.

```kotlin
class UserRepositoryTest {

    private lateinit var database: AppDatabase
    private lateinit var repository: UserRepository

    @BeforeTest
    fun setup() {
        val driver = JdbcSqliteDriver(JdbcSqliteDriver.IN_MEMORY)
        AppDatabase.Schema.create(driver)
        database = AppDatabase(
            driver = driver,
            UserAdapter = User.Adapter(
                statusAdapter = statusAdapter,
                created_atAdapter = instantAdapter
            )
        )
        repository = UserRepository(database)
    }

    @Test
    fun insertAndRetrieve() = runTest {
        repository.insert(testUser)
        val users = repository.observeAll().first()
        assertEquals(1, users.size)
        assertEquals("alice@test.com", users.first().email)
    }
}
```

## Dialect Selection

The dialect defaults to SQLite 3.18; in a module that applies an Android Gradle plugin, SQLDelight instead picks the newest dialect supported by `minSdk`. Set it explicitly inside the database block when you need newer syntax:

```kotlin
create("AppDatabase") {
    packageName.set("com.example.db")
    dialect("app.cash.sqldelight:sqlite-3-38-dialect:2.4.1")
}
```

Published dialects: `sqlite-3-18` (default), `-3-24`, `-3-25`, `-3-30`, `-3-33`, `-3-35`, `-3-38`. Upsert (`ON CONFLICT DO UPDATE`) needs 3.24, window functions 3.25, `RETURNING` 3.35. The dialect only controls what the *compiler* accepts — the SQLite shipped with the OS still has to support it at runtime, and on Android that version tracks the API level, so a low `minSdk` is the real constraint. To use newer syntax on old Android devices, ship your own SQLite: `io.requery:sqlite-android` exposes a `SupportSQLiteOpenHelper.Factory` you pass as the `factory` argument of `AndroidSqliteDriver`.

## Best Practices

- Let SQLDelight generate type-safe Kotlin code from `.sq` files; do not write manual SQL wrappers.
- Use `database.transaction { }` for multi-statement atomic operations.
- Place type adapters in `commonMain` so they are shared across platforms.
- Use `.asFlow().mapToList()` for reactive UI; use direct query calls for one-shot reads.
- Keep `.sq` files organized by table name, one file per table.
- Enable `verifyMigrations` to catch schema drift at build time.
- For upserts, know that `INSERT OR REPLACE` deletes the conflicting row and re-inserts it (new autoincrement id, `ON DELETE` cascades fire). Prefer `INSERT ... ON CONFLICT(...) DO UPDATE` — see Dialect Selection above.
