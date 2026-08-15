---
name: swift-api-design-guidelines
description: "Name, label, and document Swift APIs per Apple's official API Design Guidelines (SE-0023 lineage) — argument-label rules (prepositional-phrase → labeled, grammatical-phrase → omit and fold into base name, first-label omission, value-preserving conversions like Int64(someUInt32)), defaulted parameters over method families, mutating/nonmutating pairs (sort/sorted, reverse/reversed -ed/-ing participle rule, formUnion/formIntersection form- prefix), side-effect naming (noun phrase for pure vs imperative verb for mutating), Boolean assertions (isEmpty, contains), protocol naming (-able/-ible/-ing for capability vs noun for what-it-is), make-prefixed factories, doc-comment summary fragments by declaration kind with a Complexity: O(1) note, role-based naming, casing/acronym and terminology conventions. Use when naming a method/parameter/type/protocol, writing a doc comment, designing a public Swift interface, or reviewing an API surface — especially the Swift API a KMP shared module exposes to iOS. Siblings: swift-patterns (language idioms), swiftlint (mechanical enforcement), swift-formatstyle (formatting APIs), kmp-ios-integration (how Kotlin names surface in Swift)."
---

# Swift API Design Guidelines

Naming and interface-design rules from Apple's official [API Design
Guidelines](https://www.swift.org/documentation/api-design-guidelines/). The
prime directive: **clarity at the point of use** is the goal, and **clarity is
more important than brevity**. A declaration is written once and read at every
call site — optimize the call site.

- **Enforcement:** most of this is judgment a linter can't check; `swiftlint` catches the mechanical subset (identifier casing, redundant names). See the `swiftlint` skill.
- **Language idioms** (optionals, generics, protocol design mechanics): `swift-patterns`.
- **KMP boundary:** the Swift signatures a shared Kotlin module exposes are named by Kotlin/SKIE, not by you — audit them against these rules and rename with `@ObjCName` / SKIE where the generated names read poorly. See `kmp-ios-integration`.

## Contents

- [Fundamentals: clarity, needed words, needless words](#fundamentals)
- [Argument labels](#argument-labels)
- [Defaulted parameters over method families](#defaults)
- [Side-effect naming (pure vs mutating)](#side-effects)
- [Mutating / nonmutating pairs](#mutating-pairs)
- [Boolean assertions](#booleans)
- [Protocol naming](#protocols)
- [Factories, conversions, and `make`](#factories)
- [Doc-comment structure](#doc-comments)
- [Casing, acronyms, terminology](#conventions)
- [Fintech naming examples](#fintech)
- [Checklist](#checklist)
- Depth: `references/naming-cookbook.md`

<a id="fundamentals"></a>
## Fundamentals: clarity, needed words, needless words

Name by **role**, not by type; write the whole call site out loud and make it a grammatical English phrase.

- **Include all the words needed to avoid ambiguity.** A word that removes ambiguity at the call site earns its place.
  ```swift
  employees.remove(at: x)   // clear: removes the element AT index x
  employees.remove(x)       // ambiguous: remove index x, or an element equal to x?
  ```
- **Omit needless words.** Drop words that merely repeat type information already carried by a parameter.
  ```swift
  allViews.remove(cancelButton)          // yes
  allViews.removeElement(cancelButton)   // "Element" adds nothing — cancelButton is obviously the element
  ```
- **Name variables, parameters, and associated types by role, not type.**
  ```swift
  func restock(from supplier: WidgetFactory)     // role
  func restock(from widgetFactory: WidgetFactory) // type as name — weaker
  var greeting = "Hello"      // not `var string = "Hello"`
  protocol ViewController { associatedtype ContentView : View }  // role, not `associatedtype ViewType`
  ```
- **Compensate for weak type information.** When a parameter type is `Any`, `NSObject`, a closure, or a loosely-typed collection, add a noun describing the role.
  ```swift
  func add(_ observer: NSObject, for keyPath: String)   // reads well
  grid.add(self, for: graphics)                          // ...but consider `addObserver(_:forKeyPath:)`
  ```

<a id="argument-labels"></a>
## Argument labels

Decide each label by how the first argument reads as part of the method name.

- **Prepositional phrase → keep the label, starting at the preposition.**
  ```swift
  x.removeBoxes(havingLength: 12)
  func move(from start: Point, to end: Point)   // repeated preposition ⇒ label BOTH
  ```
  When a preposition applies to multiple arguments, don't fold it into the base name — keep it as a label on each. Write `move(from:to:)`, not `moveFrom(_:to:)`.
- **Grammatical continuity → omit the first label and fold the words into the base name.**
  ```swift
  x.addSubview(y)          // "add subview y" — reads as a phrase
  view.dismiss(animated: false)   // "dismiss" is complete; `animated` is NOT part of the phrase ⇒ keep its label
  ```
- **Value-preserving type conversion → omit the first label.**
  ```swift
  Int64(someUInt32)                 // widening conversion, no label
  String(veryLargeNumber, radix: 16) // subsequent, non-obvious args stay labeled
  ```
  A *narrowing* / lossy conversion is not value-preserving — label it to flag the loss (`UInt32(truncatingIfNeeded:)`, `Int(exactly:)`).
- **Otherwise, label the first argument** when it does not form a grammatical phrase with the base name.
- **Label all arguments** whose role isn't obvious from the value; a bare `false`/`0`/`nil` at a call site is a smell.

<a id="defaults"></a>
## Defaulted parameters over method families

Prefer **one method with default arguments** to a family of overloads — fewer symbols, lower cognitive load, and the defaults document the common case.

```swift
// Prefer this:
func compare(_ other: String,
             options: CompareOptions = [],
             range: Range<Index>? = nil,
             locale: Locale? = nil) -> Ordering

// Over: compare(_:), compare(_:options:), compare(_:options:range:), compare(_:options:range:locale:)
```

- **Put defaulted parameters toward the end.** Parameters without defaults are more essential and give a stable leading call-site pattern.
- Defaults shrink the visible interface: methods with defaults appear as the short form in most call sites and in code completion.

<a id="side-effects"></a>
## Side-effect naming (pure vs mutating)

Name by what the call *does* to the world.

- **No side effects → noun phrase.**
  ```swift
  x.distance(to: y)
  i.successor()
  balance.converted(to: .eur, at: rate)
  ```
- **Side effects → imperative verb phrase.**
  ```swift
  print(x)
  x.sort()
  x.append(y)
  account.deposit(amount)
  ```

<a id="mutating-pairs"></a>
## Mutating / nonmutating pairs

When an operation has both an in-place and a return-a-copy form, name them as a pair so the relationship is obvious.

- **Verb-based, `-ed` participle** (default): mutating uses the imperative verb; nonmutating appends `ed`.
  | Mutating | Nonmutating |
  |---|---|
  | `x.sort()` | `let s = x.sorted()` |
  | `x.reverse()` | `let r = x.reversed()` |
  | `x.append(y)` | `let a = x.appending(y)` |
- **Verb with a direct object → `-ing` participle** (because `-ed` isn't grammatical):
  ```swift
  s.stripNewlines()                       // mutating
  let oneLine = t.strippingNewlines()     // nonmutating
  ```
- **Noun-based operation → noun is the nonmutating name; `form` prefixes the mutating one.**
  ```swift
  let u = y.union(z)     // nonmutating, noun
  y.formUnion(z)         // mutating counterpart

  let n = c.successor(after: i)  // nonmutating
  c.formSuccessor(&i)            // mutating counterpart
  ```
- Rule of thumb: does the base name read as a **verb** (`sort`, `strip`) or a **noun** (`union`, `successor`)? Verb ⇒ `-ed`/`-ing`; noun ⇒ `form`-prefix the mutator.

<a id="booleans"></a>
## Boolean assertions

Nonmutating Booleans should read as **assertions about the receiver**.

```swift
if account.isEmpty { … }
if line1.intersects(line2) { … }
if transaction.isSettled { … }
```

- Prefixes/verbs that read as assertions: `is`, `has`, `can`, `should`, or a third-person verb (`intersects`, `contains`).
- Don't name a Boolean after the true case only (`animated`) unless it's an argument label where the phrase carries the polarity (`dismiss(animated:)`).

<a id="protocols"></a>
## Protocol naming

- **Capability → `-able`, `-ible`, or `-ing` suffix.** `Equatable`, `Comparable`, `Codable`, `ProgressReporting`, `CustomStringConvertible`.
- **"What something is" → a noun.** `Collection`, `Sequence`, `Iterator`, `PaymentMethod`.
- A protocol that names a role a conformer *is* (not merely a thing it *can do*) is a noun; if it names an ability layered onto many unrelated types, suffix it.

<a id="factories"></a>
## Factories, conversions, and `make`

- **Begin factory methods with `make`:** `x.makeIterator()`, `factory.makeWidget()`. Don't give factories noun names that read like properties.
- **Initializers and factory methods form a phrase that does NOT include the first argument** — the type name plus `(` reads as the call. Label first args of initializers unless it's a value-preserving conversion:
  ```swift
  let c = Color(red: 0.2, green: 0.4, blue: 0.8)   // labeled — no value-preserving conversion
  let i = Int64(someUInt32)                          // conversion — unlabeled
  ```
- Don't use `get`/`fetch` prefixes for simple accessors; a noun property or a `make…()` factory reads better.

<a id="doc-comments"></a>
## Doc-comment structure

Write a doc comment (`///`) for **every** declaration you expose. Writing it often exposes a naming problem.

- **Open with a single-sentence *fragment*, no subject, ending with a period** — describe the entity, don't narrate ("Returns…" is fine as a fragment; a full "This method returns…" is not).
- The fragment's verb follows the **declaration kind**:
  - **Function / method — what it *does* and *returns*:** `/// Inserts `newHead` at the beginning of `self`.`
  - **Subscript — what it *accesses*:** `/// Accesses the `index`th element.`
  - **Initializer — what it *creates*:** `/// Creates an instance containing `n` repetitions of `x`.`
  - **Property / other — the *thing* it is:** `/// The number of elements in the collection.`
- Continue with parameter/return/throws detail in DocC callouts after a blank line.
- **Document complexity when it isn't O(1)** — required for computed properties and methods whose cost surprises. Use a `- Complexity:` callout.

```swift
/// Returns the element at `position`.
///
/// - Parameter position: A valid index of the collection.
/// - Returns: The element at `position`.
/// - Complexity: O(1).
subscript(position: Index) -> Element { … }

/// The sorted transactions, most recent first.
///
/// - Complexity: O(*n* log *n*), where *n* is the number of transactions.
var chronological: [Transaction] { … }
```

DocC symbol-syntax reference: <https://www.swift.org/documentation/docc/>.

<a id="conventions"></a>
## Casing, acronyms, terminology

- **Casing:** types and protocols are `UpperCamelCase`; **everything else** (methods, properties, parameters, cases, globals) is `lowerCamelCase`.
- **Acronyms** that are conventionally all-caps are cased **uniformly** — all up or all down — per their position:
  ```swift
  var utf8Bytes: [UTF8.CodeUnit]      // leading acronym, lowercased
  let isRepresentableAsASCII = true    // trailing acronym, uppercased
  var userSMTPServer: SecureSMTPServer // interior acronym, uppercased
  ```
  Acronyms *not* conventionally all-caps are treated as ordinary words (`var radarDetector`).
- **Terminology:**
  - Avoid obscure terms when a common word conveys the meaning (`Array`, not a novel coinage).
  - Use a **term of art** only with its established meaning, spelled the established way.
  - **Avoid abbreviations** unless the expansion is a one-web-search away; prefer full words.
  - **Embrace precedent:** match existing culture over beginner-friendliness (`sin(x)`, `Array`), don't invent `verticalPositionOnUnitCircle…`.
- **Overloading:** give the same base name to methods that share meaning; **don't** overload on return type alone, and don't reuse a base name for semantically different operations.

<a id="fintech"></a>
## Fintech naming examples

These rules applied to a payments/ledger surface:

```swift
// Pure vs mutating + labels
let fee = order.fee(for: .instant)               // noun phrase, pure, prepositional label
account.deposit(_ amount: Money)                  // imperative verb, grammatical phrase
let usd = balance.converted(to: .usd, at: rate)   // pure -ed variant

// Mutating / nonmutating pair
var ledger: [Entry]
ledger.sort(by: .postedDate)                      // in place
let recent = ledger.sorted(by: .postedDate)       // copy

// Booleans as assertions
if card.isExpired { … }
if transfer.exceeds(dailyLimit) { … }

// Factory + value-preserving conversion
let request = PaymentRequest.make(for: invoice)   // `make` factory
let cents = Int64(minorUnits)                      // conversion, unlabeled

// Protocol naming
protocol PaymentMethod { … }        // what-it-is → noun
protocol Refundable { … }           // capability → -able
```

For money *modeling* (never-Double, `Money` value type, allocation) see `kmp-money`; for locale-aware *formatting* APIs see `swift-formatstyle`.

<a id="checklist"></a>
## Correctness checklist

- [ ] Each call site reads as a grammatical English phrase spoken aloud.
- [ ] All words needed to disambiguate are present (`remove(at:)` not `remove`); no words that merely echo a parameter's type (`remove` not `removeElement`).
- [ ] Names denote **role**, not type — for parameters, variables, and associated types.
- [ ] First argument: labeled for a prepositional phrase (label starts at the preposition), folded into the base name for a grammatical phrase, omitted for a value-preserving conversion.
- [ ] A default argument (placed late) is used instead of a family of overloads where practical.
- [ ] Pure operations read as noun phrases; side-effecting ones as imperative verbs.
- [ ] Mutating/nonmutating pairs follow `-ed`/`-ing` (verb) or `form`-prefix (noun); the nonmutating form returns the new value.
- [ ] Nonmutating Booleans read as assertions (`is…`, `has…`, third-person verb).
- [ ] Protocols: `-able`/`-ible`/`-ing` for a capability, a noun for what a conformer *is*.
- [ ] Factory methods begin with `make`; no `get`/`fetch` prefixes on plain accessors.
- [ ] Every exposed declaration has a `///` summary — a subject-less fragment ending in a period, verb chosen by declaration kind.
- [ ] `- Complexity:` documented wherever cost isn't O(1).
- [ ] Types/protocols `UpperCamelCase`, everything else `lowerCamelCase`; acronyms uniformly cased by position.
- [ ] No overloading on return type alone; shared base names only for shared meaning.
- [ ] Generated KMP/SKIE Swift signatures reviewed against the above; poor names overridden (`@ObjCName`/SKIE).
