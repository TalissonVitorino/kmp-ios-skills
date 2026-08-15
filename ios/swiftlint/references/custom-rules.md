# Custom regex rules — catalogue & mechanics

Custom rules are regex matchers defined under `custom_rules:`. They run with stock
SwiftLint (no plugin/build step) and are the fastest way to encode house rules. They
have **no AST awareness** — for anything structural, write or enable a real rule instead.

## Anatomy

```yaml
custom_rules:
  rule_identifier:                 # becomes the reported rule id; snake_case
    name: "Human name"             # optional; shown in output
    regex: '...'                   # required
    message: "Why this is flagged" # optional
    severity: warning              # warning (default) | error
    match_kinds:                   # optional; restrict to syntax token kinds
      - identifier
    capture_group: 0               # which regex group to flag (default whole match)
    included: ".*\\.swift"         # optional path regex to include
    excluded: ".*Tests?\\.swift"   # optional path regex to skip
```

### Regex flags

- Patterns run with `s` (dot matches newline) and `m` (multiline anchors) **enabled**.
- Prefix `(?-s)` to stop `.` from crossing line boundaries — usually what you want for single-line rules.
- YAML: single-quote regex strings to avoid escaping backslashes twice; `\\` only inside double quotes.

### `match_kinds`

Restrict matches to SourceKit token kinds so you don't flag text inside strings/comments.
Common kinds: `identifier`, `keyword`, `string`, `comment`, `typeidentifier`,
`number`, `attribute.builtin`, `attribute.id`, `argument`, `parameter`, `doccomment`.
Omitting `match_kinds` matches everywhere (all kinds).

## Fintech house-rule examples

```yaml
custom_rules:
  no_print:
    name: "print() in shipping code"
    regex: '(?-s)\bprint\s*\('
    match_kinds: [identifier]
    message: "Use the app logger, not print()."
    severity: error
    excluded: ".*Tests?\\.swift"

  no_double_money:
    name: "Floating-point money"
    regex: '(?-s)\b(Double|Float)\b[^\n]*(amount|price|balance|total|money|fee)'
    message: "Money must not be Double/Float — use Decimal or the Money value type."
    severity: error

  no_nslog:
    name: "NSLog"
    regex: '(?-s)\bNSLog\s*\('
    match_kinds: [identifier]
    message: "NSLog leaks to device logs — use the structured logger."
    severity: error

  no_hardcoded_secret:
    name: "Possible hardcoded secret"
    regex: '(?i)(api[_-]?key|secret|password|token)\s*=\s*"[^"]{8,}"'
    message: "Do not hardcode secrets — load from Keychain (see swift-security)."
    severity: error
    excluded: ".*Tests?\\.swift"

  no_force_unwrap_optional_try:
    name: "try! in production"
    regex: '(?-s)\btry!\s'
    match_kinds: [keyword]
    message: "Avoid try! outside tests — handle the error."
    severity: warning
    excluded: ".*Tests?\\.swift"
```

## Gotchas

- Using `custom_rules` under an `only_rules` config requires the literal `custom_rules`
  entry in `only_rules`, or none of them run.
- A too-greedy `regex` without `(?-s)` can span the whole file — always test on a fixture.
- Regex rules can't see types, so `no_double_money` above is heuristic (name-based); it
  will miss `let x: Double` used for money and may false-positive. Treat custom rules as a
  cheap tripwire, not a guarantee — back money-safety with the `kmp-money` value type and
  reviews.
- Suppress a specific custom rule inline by its identifier, same as any rule:
  `// swiftlint:disable:next no_print`.
