---
name: swiftui-observation
description: Modern SwiftUI state with the Observation framework (iOS 17+) - the @Observable macro, @State for owned models, @Bindable for two-way bindings, @Environment injection of typed models, @ObservationIgnored, and fine-grained per-property re-rendering. Use when managing SwiftUI view state or view models, or migrating from ObservableObject, @Published, @StateObject, @ObservedObject, or @EnvironmentObject, or chasing unnecessary re-renders. For general SwiftUI layout, navigation, and animations use swiftui-patterns; for async work behind state use swift-concurrency; for legacy Combine ObservableObject use combine-framework.
---

# SwiftUI Observation (iOS 17+)

## Overview

The `@Observable` macro (Observation framework) replaces `ObservableObject`/`@Published`. Views automatically track only the properties they actually read, so re-rendering becomes fine-grained instead of invalidating on every `@Published` change.

## When to use

- New SwiftUI view models or app state on iOS 17+
- Migrating off `ObservableObject`, `@Published`, `@StateObject`, `@ObservedObject`, `@EnvironmentObject`
- Excess re-renders / performance from coarse `@Published` invalidation
- Two-way bindings to a reference-type model (`@Bindable`)

## Property-wrapper map (old → new)

| Old (Combine) | New (Observation) |
|---|---|
| `class VM: ObservableObject` + `@Published` | `@Observable final class VM` (no `@Published`) |
| `@StateObject var vm = VM()` | `@State private var vm = VM()` |
| `@ObservedObject var vm` | plain `var vm: VM` (or `@Bindable` for bindings) |
| `@EnvironmentObject var vm` | `@Environment(VM.self) private var vm` + `.environment(vm)` |
| `$vm.name` binding | `@Bindable var vm` then `$vm.name` |

## Example

```swift
@Observable final class ProfileModel {
    var name = ""
    var isSaving = false
    // No @Published — stored properties are observed automatically.
    @ObservationIgnored private var cache: [String: Data] = [:]   // not tracked
}

struct ProfileView: View {
    @State private var model = ProfileModel()    // this view OWNS the model

    var body: some View {
        @Bindable var model = model              // local bindable for $ bindings
        Form {
            TextField("Name", text: $model.name) // two-way binding
            if model.isSaving { ProgressView() } // only views reading isSaving re-render
        }
        .environment(model)                      // inject to descendants
    }
}

struct ChildView: View {
    @Environment(ProfileModel.self) private var model   // typed environment injection
    var body: some View { Text(model.name) }
}
```

## Common mistakes

| Mistake | Fix |
|---|---|
| Keeping `@Published` inside `@Observable` | Remove it — stored properties are tracked automatically |
| Using `@StateObject` with `@Observable` | Use `@State` to own an `@Observable` model |
| Can't form a `$binding` to the model | Add `@Bindable var model = model` (or a `@Bindable` parameter) |
| A heavy non-UI property triggers re-renders | Mark it `@ObservationIgnored` |
| Targeting below iOS 17 | `@Observable` needs iOS 17+; fall back to `ObservableObject` |

## See also

- General SwiftUI layout, navigation, animation: `swiftui-patterns`
- async work and `@MainActor` behind state: `swift-concurrency`
- Legacy `ObservableObject`/Combine state: `combine-framework`
