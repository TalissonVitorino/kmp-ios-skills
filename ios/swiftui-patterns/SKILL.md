---
name: swiftui-patterns
description: Quick SwiftUI UI patterns, state management, navigation, animations, and performance optimization. Light reference for building SwiftUI UI. For comprehensive review/refactor of SwiftUI code, deprecated-API migration, or Instruments .trace analysis, prefer swiftui-expert-skill; for @Observable state specifics use swiftui-observation.
---

# SwiftUI Patterns

Modern SwiftUI patterns. Baseline is iOS 17; APIs newer than that are marked inline.

## View Composition

### Small, Focused Views

```swift
// ✅ Good: Single responsibility
struct AvatarView: View {
    let imageURL: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: imageURL) { image in
            image.resizable()
        } placeholder: {
            Color.gray.opacity(0.2)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct UserRow: View {
    let user: User

    var body: some View {
        HStack {
            AvatarView(imageURL: user.avatarURL, size: 48)
            VStack(alignment: .leading) {
                Text(user.name).font(.headline)
                Text(user.email).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
```

`AsyncImage` only uses `URLCache` — it has no in-memory decoded-image cache and re-decodes
on every reappearance, so it thrashes in scrolling lists. Use a caching loader (Nuke,
Kingfisher, Coil 3 on KMP) for row/grid imagery; keep `AsyncImage` for one-off images.

## State Management

### @Observable (iOS 17+)

```swift
// @MainActor is required: Observation tracking and SwiftUI updates must happen on
// the main actor, and without it these mutations are data races under Swift 6.
// (Only redundant if the module opts into `-default-isolation MainActor`.)
@MainActor
@Observable
final class HomeViewModel {
    var items: [Item] = []
    var isLoading = false

    private let api: APIClient
    init(api: APIClient) { self.api = api }

    func loadItems() async {
        isLoading = true
        defer { isLoading = false }
        items = await api.fetchItems()
    }
}

struct HomeView: View {
    // @State owns the instance; the initial value is only used on first render.
    @State private var viewModel = HomeViewModel(api: .shared)

    var body: some View {
        List {
            if viewModel.isLoading {
                ProgressView()
            } else {
                ForEach(viewModel.items) { item in
                    Text(item.title)
                }
            }
        }
        .task {
            await viewModel.loadItems()
        }
    }
}
```

## Performance Patterns

### Lazy Containers

```swift
// ✅ LazyVStack for long lists
ScrollView {
    LazyVStack(spacing: 16) {
        ForEach(items) { item in
            ItemCard(item: item)
        }
    }
}

// ✅ LazyHStack for horizontal lists
ScrollView(.horizontal) {
    LazyHStack(spacing: 12) {
        ForEach(users) { user in
            UserAvatar(user: user)
        }
    }
}
```

`LazyVStack` only defers *creation* — once a row scrolls into view it stays alive for the
lifetime of the scroll view. `List` recycles rows, so for unbounded or very long data
prefer `List` (add `.listStyle(.plain)` / `.listRowSeparator(.hidden)` to strip chrome).
Reach for `ScrollView` + `LazyVStack` when you need layout `List` can't express.

`ForEach` needs stable identity — `id: \.self` on values that repeat or change collapses
rows and breaks animations. Use `Identifiable` with a real ID.

### Equatable Views

```swift
struct ItemRow: View, Equatable {
    let item: Item  // Item: Equatable

    var body: some View {
        HStack {
            Text(item.title)
            Text(item.price)
        }
    }
}

// Wrap in .equatable() to guarantee SwiftUI uses == to skip body:
ItemRow(item: item).equatable()
```

Compare all inputs that affect `body` — comparing only `id` skips updates when the item's content changes. A synthesized `==` over Equatable stored properties is usually correct; write a manual `==` only to exclude inputs that genuinely don't affect rendering.

## Navigation

### NavigationStack

```swift
// Routes are the pushed destinations only — the root is the stack's own content.
enum Route: Hashable {
    case detail(String)
    case profile(userId: String)
}

struct AppNavigation: View {
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            HomeView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .detail(let id):
                        DetailView(id: id)
                    case .profile(let userId):
                        ProfileView(userId: userId)
                    }
                }
        }
    }
}
```

`navigationDestination` must be declared *inside* the stack, and must not sit inside a
lazy container (`List` rows, `LazyVStack`) — off-screen rows never register it and the
push silently fails. Drive the stack by mutating `path`: `path.append(.detail(id))`,
`path.removeLast()`, `path.removeAll()` to pop to root.

### Sheet Presentation

```swift
struct RootView: View {
    @State private var presentedItem: Item?
    @State private var showingSettings = false

    var body: some View {
        List(items) { item in
            Button(item.title) { presentedItem = item }
        }
        .sheet(item: $presentedItem) { item in
            DetailSheet(item: item)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }
}
```

## Gestures

### Custom Gestures

```swift
struct SwipeToDismiss: ViewModifier {
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if value.translation.width < 0 {
                            offset = value.translation.width
                        }
                    }
                    .onEnded { value in
                        if value.translation.width < -100 {
                            // Dismiss action
                        }
                        // Without withAnimation the view snaps back instantly
                        withAnimation(.spring(duration: 0.25)) { offset = 0 }
                    }
            )
    }
}
```

## Animations

### Spring Animations

```swift
struct AnimatedButton: View {
    @State private var isPressed = false

    var body: some View {
        Circle()
            .fill(isPressed ? Color.blue : Color.gray)
            .frame(width: 80, height: 80)
            .scaleEffect(isPressed ? 0.9 : 1.0)
            // duration/bounce spring; bounce 0 = critically damped, 1 = undamped.
            // Back-deployed: `Animation.spring(duration:bounce:)` is annotated iOS 13+
            // (only the `Spring` struct itself needs iOS 17).
            .animation(.spring(duration: 0.3, bounce: 0.4), value: isPressed)
            .onTapGesture {
                isPressed.toggle()  // .animation(value:) drives it — no withAnimation needed
            }
    }
}
```

### Phase Animations (iOS 17+)

```swift
// Cycles through phases on trigger change; omit trigger: to loop forever
Image(systemName: "heart.fill")
    .phaseAnimator([false, true], trigger: likeCount) { content, phase in
        content
            .scaleEffect(phase ? 1.3 : 1.0)
            .foregroundStyle(phase ? .red : .primary)
    } animation: { phase in
        phase ? .spring(duration: 0.3, bounce: 0.7) : .default
    }
```

### Transitions

```swift
// Applies when the view is inserted/removed inside withAnimation
Text(item)
    .transition(.asymmetric(
        insertion: .scale.combined(with: .opacity),
        removal: .opacity
    ))
```

## Custom Modifiers

```swift
struct CardModifier: ViewModifier {
    var backgroundColor: Color = Color(uiColor: .systemBackground)  // adapts to dark mode
    var cornerRadius: CGFloat = 12
    var shadowRadius: CGFloat = 4

    func body(content: Content) -> some View {
        content
            .padding()
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(radius: shadowRadius)
    }
}

extension View {
    func cardStyle(
        backgroundColor: Color = Color(uiColor: .systemBackground),
        cornerRadius: CGFloat = 12,
        shadowRadius: CGFloat = 4
    ) -> some View {
        modifier(CardModifier(
            backgroundColor: backgroundColor,
            cornerRadius: cornerRadius,
            shadowRadius: shadowRadius
        ))
    }
}
```

## Shapes & Styles

### Custom Shapes

A `Shape` interpolates during an animation only if it is `Animatable`. Without it, the
parameter jumps to its final value and only implicit effects (opacity, position) animate.

```swift
// Xcode 26 SDK: @Animatable synthesizes the Animatable conformance and animatableData
// from the stored properties. Mark any property that must not interpolate
// with @AnimatableIgnored. It expands at compile time, so it back-deploys —
// both macros are annotated iOS 13+; only the toolchain has to be new.
@Animatable
struct SquircleCard: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)
    }
}
```

```swift
// Older toolchain (no macro): write animatableData by hand. For two or more animated parameters
// use AnimatablePair (or nest them) — a single CGFloat only covers one.
struct SquircleCard: Shape {
    var cornerRadius: CGFloat

    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)
    }
}
```

```swift
// Usage — cornerRadius interpolates when the value changes
SquircleCard(cornerRadius: isExpanded ? 8 : 50)
    .fill(Color.blue.gradient)
    .animation(.spring(duration: 0.3), value: isExpanded)
```

### Gradients

```swift
Circle()
    .fill(
        LinearGradient(
            colors: [.blue, .purple],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    )

// Angular gradient
Circle()
    .fill(AngularGradient(
        colors: [.red, .yellow, .green, .blue, .red],
        center: .center
    ))
```

## Grid Layouts

```swift
LazyVGrid(
    columns: [
        GridItem(.adaptive(minimum: 100), spacing: 16)
    ],
    spacing: 16
) {
    ForEach(items) { item in
        ItemCell(item: item)
    }
}
```
