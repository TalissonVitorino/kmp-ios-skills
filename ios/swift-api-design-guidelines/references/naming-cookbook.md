# Naming cookbook (depth)

Extended cases beyond the SKILL body. Source: Apple's official
[API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).

## Deciding a label, step by step

1. Does the first argument + base name read as a **grammatical phrase** ("add subview y")?
   → fold the words into the base name, omit the label: `x.addSubview(y)`.
2. Is it a **prepositional phrase** ("from start", "having length 12")?
   → label starting at the preposition: `move(from:)`, `removeBoxes(havingLength:)`.
   → if one preposition governs several args, keep it as a label on each, not in the base name: `move(from:to:)`.
3. Is the initializer a **value-preserving conversion** (widening, or a faithful re-representation)?
   → omit the first label: `Int64(someUInt32)`, `String(someCharacter)`.
   → lossy/narrowing is NOT value-preserving → label it: `Int(exactly:)`, `UInt8(truncatingIfNeeded:)`.
4. Otherwise → label the first argument.

Weak-type compensation: when a parameter's type is `Any`/`AnyObject`/a closure/`[String: Any]`,
add a noun to the preceding label describing its role, e.g. `func add(_ observer:, for keyPath:)`.

## Grammar of the base name

- Prefer names that make **use sites** form grammatical phrases, even if that reads oddly in the declaration.
  - Good use site: `words.split(maxSplits: 12)`, `viewController.dismiss(animated: false)`.
- **Begin factory methods with `make`**: `x.makeIterator()`. Not `x.iterator()` (reads like a property) or `x.getIterator()`.
- **First argument of initializers and factory methods** should not form a phrase continuing the base name — unlike other methods, `Color(...)` already reads as the phrase. So label them (`Color(red:green:blue:)`) unless it's a conversion.

## Mutating / nonmutating — full decision

| Base name is a… | Nonmutating | Mutating |
|---|---|---|
| verb, no direct object | `sorted()`, `reversed()` (`-ed`) | `sort()`, `reverse()` |
| verb WITH a direct object | `strippingNewlines()` (`-ing`) | `stripNewlines()` |
| noun | `union(_:)`, `successor(after:)` | `formUnion(_:)`, `formSuccessor(&:)` |

- The nonmutating member **returns** the transformed value; document it with `- Returns:`.
- A lone mutating method with no natural nonmutating twin still takes the imperative verb (`append`, `insert`).
- `@discardableResult` is orthogonal — it doesn't change naming; a value-returning mutator (`removeFirst() -> Element`) is still an imperative verb.

## Overloading and polymorphism

- **Same base name ⇒ same semantics.** `contains` on `Array` and `Set` share meaning — good. Reusing a base name for an unrelated operation is not.
- **Never overload on return type alone** — the type checker can't always disambiguate and call sites become order-dependent.
- **Unconstrained polymorphism** (`Any`, `AnyObject`, unconstrained generics) can create surprising overload ambiguities; prefer distinct, descriptive names when a generic overload would collide with a more specific one (e.g. `append(_:)` vs `append(contentsOf:)`).

## Closure and tuple labels

- Label closure parameters and tuple members so they can be referenced and documented:
  ```swift
  func enumerated() -> [(offset: Int, element: Element)]
  ```
- Parameter names in function types are documentation only, but they help at call sites that spell out the closure.

## Doc-comment templates by kind

```swift
/// Returns a subsequence containing the elements until `predicate` returns false.
/// - Parameter predicate: A closure that takes an element as its argument…
/// - Returns: The prefix of the collection…
/// - Complexity: O(*n*), where *n* is the length of the collection.
func prefix(while predicate: (Element) -> Bool) -> SubSequence
```

- First line: subject-less fragment, period-terminated. Not "This function returns…".
- Function/method → what it does + returns. Subscript → what it accesses. Initializer → what it creates. Property → the thing it is.
- Additional DocC callouts: `- Parameters:` / `- Parameter x:`, `- Returns:`, `- Throws:`, `- Complexity:`, `- Precondition:`, `- Note:`, `- Warning:`.
- Symbol links in prose use double backticks (```` ``Type/member`` ````) in DocC; inline code uses single backticks.

## Casing edge cases

- Interior and trailing acronyms follow the "uniform up/down by convention" rule:
  `userSMTPServer`, `isRepresentableAsASCII`, `utf8Bytes` (utf8 leads, so lowercased).
- Enum cases are `lowerCamelCase` (`case httpOnly`, `case faceID`).
- Global constants and type properties are `lowerCamelCase`, not `SCREAMING_SNAKE` and not `kPrefixed`.

## Async naming (modern addendum)

- The API guidelines predate `async`; current convention keeps the noun/verb rules and simply drops completion-handler suffixes. An `async` method that returns a value reads as a noun phrase or verb per its side effects: `let data = try await session.data(for: request)`.
- Don't append `Async` to names; the `async` keyword already marks it. See the `swift-concurrency` skill.

## KMP / SKIE boundary notes

- Kotlin `getX()`/`setX()` accessors surface to Swift as properties via SKIE where possible; plain functions surface as methods — review the generated Swift for `get`-prefixed accessors and rename with SKIE/`@ObjCName`.
- Kotlin `suspend` functions become Swift `async` via SKIE; Kotlin `Flow` becomes an `AsyncSequence`. Name the Kotlin side so the *Swift* call site reads well — that's the surface iOS engineers use. See `kmp-ios-integration`.
