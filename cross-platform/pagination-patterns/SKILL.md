---
name: pagination-patterns
description: Pagination patterns for mobile - Paging 3 for Android (PagingSource, RemoteMediator, LazyPagingItems), cursor-based and offset-based strategies.
---

# Pagination Patterns for Mobile

## Dependencies (Android)

```kotlin
dependencies {
    val pagingVersion = "3.5.1"
    implementation("androidx.paging:paging-compose:$pagingVersion") // brings in paging-common
    implementation("androidx.paging:paging-runtime:$pagingVersion") // only for RecyclerView/PagingDataAdapter
    testImplementation("androidx.paging:paging-testing:$pagingVersion")
}
```

KMP note: `paging-common` and `paging-testing` went multiplatform in 3.3; `paging-compose` shipped only an Android artifact then and gained the non-Android targets (JVM/desktop, Apple, Linux, MinGW, JS, wasmJs) in 3.4.0. On 3.4+ both `Pager`/`PagingSource` and `collectAsLazyPagingItems()` can live in `commonMain`; `paging-runtime` (and the RxJava/Guava artifacts) stay Android-only.

```kotlin
// KMP: commonMain
implementation("androidx.paging:paging-common:3.5.1")
implementation("androidx.paging:paging-compose:3.5.1")
// androidMain, only if you also use RecyclerView/PagingDataAdapter
implementation("androidx.paging:paging-runtime:3.5.1")
```

Paging 3.5 added `append()`, `prepend()`, `refresh()`, `refresh(item)` and `retry()` as members on `Pager` itself, for driving loads without a UI presenter, plus the `Flow<PagingData<T>>.asItemSnapshotListFlow()` operator, which converts the stream into a `Flow<ItemSnapshotList<T>>` that can be combined with other sources, shared by multiple collectors without `cachedIn`, or exposed as part of UI state.

For deeper Android-specific coverage prefer `android-skills:paging`.

## PagingSource Implementation

```kotlin
class ArticlePagingSource(
    private val api: ArticleApi,
    private val query: String
) : PagingSource<Int, Article>() {

    override suspend fun load(params: LoadParams<Int>): LoadResult<Int, Article> {
        val page = params.key ?: STARTING_PAGE
        return try {
            val response = api.searchArticles(
                query = query,
                page = page,
                // REFRESH asks for initialLoadSize, APPEND/PREPEND for pageSize
                pageSize = params.loadSize
            )
            LoadResult.Page(
                data = response.articles,
                prevKey = if (page == STARTING_PAGE) null else page - 1,
                // Advance by the number of pages actually consumed. With
                // initialLoadSize > pageSize, a plain `page + 1` re-fetches rows
                // the first load already returned.
                nextKey = if (response.articles.isEmpty()) null
                          else page + (params.loadSize / PAGE_SIZE)
            )
        } catch (e: IOException) {
            LoadResult.Error(e)
        } catch (e: HttpException) { // Retrofit; with Ktor catch ResponseException instead
            LoadResult.Error(e)
        }
    }

    override fun getRefreshKey(state: PagingState<Int, Article>): Int? =
        state.anchorPosition?.let { anchor ->
            val closest = state.closestPageToPosition(anchor)
            closest?.prevKey?.plus(1) ?: closest?.nextKey?.minus(1)
        }

    private companion object {
        const val STARTING_PAGE = 1
        const val PAGE_SIZE = 20 // must equal PagingConfig.pageSize
    }
}
```

`load` runs in a cancellable coroutine: never wrap it in a blanket `catch (e: Exception)` without rethrowing `CancellationException` (see the cursor example below).

## Cursor-Based PagingSource

```kotlin
class CursorArticlePagingSource(
    private val api: ArticleApi
) : PagingSource<String, Article>() {

    override suspend fun load(params: LoadParams<String>): LoadResult<String, Article> {
        return try {
            val response = api.getArticles(
                cursor = params.key,
                limit = params.loadSize
            )
            LoadResult.Page(
                data = response.articles,
                prevKey = null, // cursor-based usually does not support backward
                nextKey = response.nextCursor
            )
        } catch (e: CancellationException) {
            throw e // never swallow cancellation
        } catch (e: Exception) {
            LoadResult.Error(e)
        }
    }

    override fun getRefreshKey(state: PagingState<String, Article>): String? = null
}
```

## Pager Configuration

```kotlin
class ArticleRepository(private val api: ArticleApi) {

    fun getArticlesPager(query: String): Flow<PagingData<Article>> {
        return Pager(
            config = PagingConfig(
                pageSize = 20,
                prefetchDistance = 5,
                enablePlaceholders = false,
                initialLoadSize = 40,  // default is 3 * pageSize; 2x is a common tighter choice
                maxSize = 200          // cap cached items; must be >= pageSize + 2 * prefetchDistance
                                       // (with enablePlaceholders = false, dropped pages can jump scroll)
            ),
            pagingSourceFactory = { ArticlePagingSource(api, query) }
        ).flow
    }
}
```

## ViewModel Integration

```kotlin
@OptIn(FlowPreview::class, ExperimentalCoroutinesApi::class)
class ArticleListViewModel(
    private val repository: ArticleRepository
) : ViewModel() {

    private val _query = MutableStateFlow("")

    val articles: Flow<PagingData<Article>> = _query
        .debounce(300)
        .distinctUntilChanged()
        .flatMapLatest { query ->
            repository.getArticlesPager(query)
        }
        .cachedIn(viewModelScope)

    fun search(query: String) {
        _query.value = query
    }
}
```

## Collecting as LazyPagingItems in Compose

```kotlin
@Composable
fun ArticleListScreen(viewModel: ArticleListViewModel = koinViewModel()) {
    val articles = viewModel.articles.collectAsLazyPagingItems()

    LazyColumn {
        items(
            count = articles.itemCount,
            key = articles.itemKey { it.id },
            contentType = articles.itemContentType()
        ) { index ->
            val article = articles[index]
            if (article != null) {
                ArticleCard(article = article)
            } else {
                ArticlePlaceholder()
            }
        }

        // Append loading indicator
        when (articles.loadState.append) {
            is LoadState.Loading -> {
                item { LoadingIndicator() }
            }
            is LoadState.Error -> {
                item {
                    RetryButton(onClick = { articles.retry() })
                }
            }
            else -> {}
        }
    }
}
```

## Load State Handling

```kotlin
// PullToRefreshBox is stable since material3 1.4.0;
// on 1.3.x it still needs @OptIn(ExperimentalMaterial3Api::class).
@Composable
fun PaginatedList(articles: LazyPagingItems<Article>) {
    val refresh = articles.loadState.refresh
    when {
        // Full-screen states only when there is nothing cached to show
        refresh is LoadState.Loading && articles.itemCount == 0 -> {
            Box(Modifier.fillMaxSize()) {
                CircularProgressIndicator(Modifier.align(Alignment.Center))
            }
        }
        refresh is LoadState.Error && articles.itemCount == 0 -> {
            ErrorScreen(
                message = refresh.error.localizedMessage ?: "Unknown error",
                onRetry = { articles.retry() }
            )
        }
        refresh is LoadState.NotLoading && articles.itemCount == 0 -> {
            EmptyState(message = "No articles found")
        }
        // Content with pull-to-refresh (material3 PullToRefreshBox)
        else -> {
            PullToRefreshBox(
                isRefreshing = refresh is LoadState.Loading,
                onRefresh = { articles.refresh() }
            ) {
                ArticleLazyColumn(articles = articles)
            }
        }
    }
}
```

## RemoteMediator (Network + Database)

```kotlin
@OptIn(ExperimentalPagingApi::class)
class ArticleRemoteMediator(
    private val api: ArticleApi,
    private val database: AppDatabase
) : RemoteMediator<Int, ArticleEntity>() {

    private val articleDao = database.articleDao()
    private val remoteKeyDao = database.remoteKeyDao()

    // Default is LAUNCH_INITIAL_REFRESH; return SKIP_INITIAL_REFRESH while the
    // cached data is still fresh enough to show without hitting the network.
    override suspend fun initialize(): InitializeAction =
        InitializeAction.LAUNCH_INITIAL_REFRESH

    override suspend fun load(
        loadType: LoadType,
        state: PagingState<Int, ArticleEntity>
    ): MediatorResult {
        val page = when (loadType) {
            LoadType.REFRESH -> 1
            LoadType.PREPEND -> return MediatorResult.Success(endOfPaginationReached = true)
            LoadType.APPEND -> {
                val remoteKey = remoteKeyDao.getRemoteKey("articles")
                remoteKey?.nextPage ?: return MediatorResult.Success(
                    endOfPaginationReached = true
                )
            }
        }

        return try {
            val response = api.getArticles(page = page, pageSize = state.config.pageSize)

            database.withTransaction { // androidx.room.withTransaction, from room-ktx
                if (loadType == LoadType.REFRESH) {
                    articleDao.deleteAll()
                    remoteKeyDao.deleteByKey("articles")
                }
                articleDao.insertAll(response.articles.map { it.toEntity() })
                remoteKeyDao.insert(
                    RemoteKey(
                        key = "articles",
                        nextPage = if (response.articles.isEmpty()) null else page + 1
                    )
                )
            }

            MediatorResult.Success(endOfPaginationReached = response.articles.isEmpty())
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            MediatorResult.Error(e)
        }
    }
}

// Usage in repository
@OptIn(ExperimentalPagingApi::class)
fun getOfflineArticles(): Flow<PagingData<ArticleEntity>> {
    return Pager(
        config = PagingConfig(pageSize = 20),
        remoteMediator = ArticleRemoteMediator(api, database),
        pagingSourceFactory = { database.articleDao().pagingSource() }
    ).flow
}
```

`CombinedLoadStates` exposes `source` and `mediator` separately. With a RemoteMediator the local `PagingSource` resolves almost instantly from the database, so drive the network spinner and retry affordances from `loadState.mediator?.refresh` / `?.append`, not from `loadState.source`.

## RemoteKey Entity

```kotlin
@Entity(tableName = "remote_keys")
data class RemoteKey(
    @PrimaryKey val key: String,
    val nextPage: Int?
)

@Dao
interface RemoteKeyDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(key: RemoteKey)

    @Query("SELECT * FROM remote_keys WHERE `key` = :key")
    suspend fun getRemoteKey(key: String): RemoteKey?

    @Query("DELETE FROM remote_keys WHERE `key` = :key")
    suspend fun deleteByKey(key: String)
}
```

## iOS Pagination Pattern

### AsyncSequence-Based Pagination

```swift
@MainActor
@Observable
final class ArticleListViewModel {
    private(set) var articles: [Article] = []
    private(set) var isLoading = false
    private(set) var hasMore = true
    private var currentPage = 1
    private let pageSize = 20
    private let api = ArticleAPI()

    func loadNextPage() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await api.getArticles(page: currentPage, pageSize: pageSize)
            articles.append(contentsOf: response.articles)
            // A short page means the server has nothing left; `!isEmpty` would cost
            // one extra round trip that returns zero rows.
            hasMore = response.articles.count == pageSize
            currentPage += 1
        } catch {
            // Surface the error; leave hasMore == true so the user can retry.
        }
    }
}
```

There is no Paging-3 equivalent on the Swift side. In a KMP project you can keep the `Pager` in `commonMain` and consume it from Compose Multiplatform, but `PagingData`/`Flow` do not bridge cleanly to SwiftUI - for a SwiftUI UI either wrap the flow in a Swift-friendly observable or paginate manually as above.

### SwiftUI List with Pagination Trigger

```swift
struct ArticleListView: View {
    @State private var viewModel = ArticleListViewModel()

    var body: some View {
        List(viewModel.articles) { article in
            ArticleRow(article: article)
                .onAppear {
                    if article.id == viewModel.articles.last?.id {
                        Task { await viewModel.loadNextPage() }
                    }
                }
        }
        .overlay {
            if viewModel.isLoading && viewModel.articles.isEmpty {
                ProgressView()
            }
        }
        .task {
            await viewModel.loadNextPage()
        }
    }
}
```

## API Patterns

### Cursor-Based Response

```json
{
    "data": [...],
    "pagination": {
        "next_cursor": "eyJpZCI6MTAwfQ==",
        "has_more": true
    }
}
```

### Offset-Based Response

```json
{
    "data": [...],
    "pagination": {
        "page": 2,
        "page_size": 20,
        "total_count": 156,
        "total_pages": 8
    }
}
```

### Kotlin API Models

```kotlin
@Serializable
data class PaginatedResponse<T>(
    val data: List<T>,
    val pagination: Pagination
)

@Serializable
data class Pagination(
    @SerialName("next_cursor") val nextCursor: String? = null,
    @SerialName("has_more") val hasMore: Boolean = false,
    val page: Int? = null,
    @SerialName("total_count") val totalCount: Int? = null
)
```

(Or configure `Json { namingStrategy = JsonNamingStrategy.SnakeCase }` instead of per-field `@SerialName`.)

## Best Practices

- Prefer cursor-based pagination for real-time feeds (no skipped/duplicate items on insert).
- Use offset-based pagination when total count or page jumping is required.
- Set `prefetchDistance` to 3-5 items so loading starts before the user reaches the end.
- Use `RemoteMediator` for offline-capable paginated lists backed by a local database.
- Handle `refresh` and `append`; only handle `prepend` when the source can actually load backwards (page-keyed feeds with `prevKey`, or a Room-backed list keyed to a mid-list anchor).
- Call `.cachedIn(viewModelScope)` exactly once, as the last operator on the flow - it is what makes the flow multicast and survive configuration changes. Operators applied after it run again on every collection.
- Show shimmer placeholders during initial load; show a footer spinner for append loads.
- Implement pull-to-refresh by calling `articles.refresh()` on `LazyPagingItems`.
- Test with `paging-testing`: `pager.flow.asSnapshot { scrollTo(index) }` returns the loaded `List<T>` without a UI, and `PagingSource.load()` can be called directly with a hand-built `LoadParams.Refresh`.
