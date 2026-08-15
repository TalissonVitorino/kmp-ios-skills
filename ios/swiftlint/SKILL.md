---
name: swiftlint
description: "Configure and roll out SwiftLint for an iOS/Swift (or KMP-iOS) fintech app — author .swiftlint.yml (disabled_rules / opt_in_rules / only_rules / analyzer_rules / included / excluded / custom_rules, per-rule severity thresholds, parent_config / child_config), wire it via the SwiftLintPlugins SPM build-tool plugin (SimplyDanny) or an Xcode run-script phase, run swiftlint lint / analyze / --fix, gate CI with --strict, and adopt legacy codebases incrementally with baselines (--baseline / --write-baseline). Also covers reporters (xcode / json / sarif / checkstyle / markdown), swiftlint:disable/enable inline suppressions, and strict-vs-lenient. Use when adding, tuning, or CI-gating SwiftLint, or when triaging lint noise on an existing project. Sibling skills: ci-cd-patterns (Fastlane / GitHub Actions), ios-simulator + ios-testing (other iOS tooling), swiftui-expert-skill (deprecated-API refactors), swift-concurrency-6-2 (concurrency-diagnostic migration). For Kotlin static analysis the counterpart is detekt/ktlint, not this skill."
---

# SwiftLint (iOS / Swift)

Static analysis and style enforcement for Swift. This skill covers **configuration
authoring**, **build integration**, and **rollout** — grounded in the `realm/SwiftLint`
and `SimplyDanny/SwiftLintPlugins` docs. For a fintech codebase the goal is a lint gate
that blocks *new* violations without a big-bang cleanup of the *existing* ones.

- SwiftLint has two rule engines: **lint rules** (syntactic, AST via SourceKit) run by `swiftlint lint` (default), and **analyzer rules** run by `swiftlint analyze` against a compiler log.
- Ships default-on rules plus a large opt-in set. `swiftlint rules` lists every rule and whether it's enabled; `swiftlint reporters` lists output formats.

## Contents

- [Install](#install)
- [.swiftlint.yml](#config)
- [Rule severity & thresholds](#severity)
- [Custom rules (regex)](#custom-rules)
- [Inline suppression](#inline)
- [Build integration (SPM plugin / run script)](#integration)
- [Analyzer rules](#analyzer)
- [Reporters](#reporters)
- [strict vs lenient](#strict)
- [Baselines (legacy rollout)](#baselines)
- [CI](#ci)
- [Rollout strategy](#rollout)
- [Checklist](#checklist)
- References: `references/config-reference.md`, `references/custom-rules.md`, `references/ci-recipes.md`

<a id="install"></a>
## Install

Pin the version so every machine and CI runner lints identically — a floating SwiftLint silently changes what fails.

```bash
brew install swiftlint          # local dev (unversioned; fine for editors)
mint install realm/SwiftLint    # Mintfile-pinned
```

- **Preferred for reproducibility:** the **SPM build-tool plugin** (below) — it vendors a pinned binary per package, so no separate install step and no version drift between developers and CI.
- Avoid the CocoaPods `SwiftLint` pod on new projects; the SPM plugin supersedes it.

<a id="config"></a>
## .swiftlint.yml

Place at the repo root (or a target/subdirectory root — SwiftLint walks up from each file and applies the nearest config). Keys:

```yaml
# --- rule selection ---
disabled_rules:            # turn OFF default-on rules
  - todo
  - trailing_whitespace

opt_in_rules:              # turn ON rules that are off by default
  - empty_count
  - first_where
  - force_unwrapping
  - explicit_init
  - all                    # special: enable EVERY opt-in rule (minus disabled_rules)

# only_rules:              # allow-list: ONLY these run. Mutually exclusive with
#   - force_cast           # disabled_rules AND opt_in_rules — do not combine.
#   - force_try

analyzer_rules:            # separate list, run only by `swiftlint analyze` (all opt-in)
  - unused_import
  - unused_declaration

# --- paths (case-sensitive, relative to the config file) ---
included:                  # if set, lint ONLY these (still minus `excluded`)
  - Sources
excluded:                  # skip these; wins over `included`
  - Tests
  - .build
  - Pods
  - "**/Generated"         # generated code (protobuf, Sourcery, R.swift) — never lint

# --- output ---
reporter: "xcode"          # default; see Reporters section

# --- global severity ---
strict: false              # true → warnings become errors (nonzero exit)
lenient: false             # true → errors become warnings (never fails)
```

- `opt_in_rules` vs `only_rules`: `opt_in_rules` **adds** to the default set; `only_rules` **replaces** it. Picking `only_rules` gives a fully explicit, reviewable rule set — good for a locked-down fintech config, at the cost of not inheriting new default rules on upgrade.
- With `only_rules`, if you use custom rules you must add the literal `custom_rules` to the list, otherwise they won't run.
- `excluded` is not applied when SwiftLint is handed explicit file paths (e.g. by the build plugin) unless you pass `--force-exclude`; the SPM plugin passes it for you.

### Sharing config across modules

```yaml
# child config: inherits a base and refines it (child keys win)
parent_config: Base/.swiftlint_base.yml           # local path OR https:// URL
# child_config: .swiftlint_refinement.yml         # opposite direction from a parent

remote_timeout: 2                                  # seconds, for https parent/child
remote_timeout_if_cached: 1
```

- On the CLI, `swiftlint --config a.yml --config b.yml` treats the **first as parent, last as child** (later overrides earlier).
- Remote (`https://`) parent configs let a fintech monorepo pull one org-wide baseline config; cache locally and pin — a fetch failure or an upstream edit shouldn't change what your CI enforces. Prefer a vendored copy for hard reproducibility.

<a id="severity"></a>
## Rule severity & thresholds

```yaml
force_cast: warning              # shorthand: set a rule's severity

force_try:
  severity: warning              # explicit form

# two-level rules — warning then error threshold
line_length:
  warning: 120
  error: 200
  ignores_urls: true
type_body_length:
  - 300                          # array form: [warning, error]
  - 400

identifier_name:
  min_length: 3                  # allow short names like `id`, `db`
  excluded: [id, x, y, uri]
  max_length:
    warning: 50
    error: 60
```

- Rule config keys are per-rule; run `swiftlint rules <rule_id>` to see a rule's options and its default severity.
- Default rule severities are mostly `warning`. Turning the whole build red is done globally with `strict` (CI), not by re-flagging every rule to `error`.

<a id="custom-rules"></a>
## Custom rules (regex)

Project-specific rules via regex — no plugin, works with stock SwiftLint. Ideal for fintech house rules (ban `print`, ban `Double` money math, force typed money constructors).

```yaml
custom_rules:
  no_print:
    name: "print() in shipping code"
    regex: '\bprint\('
    match_kinds: [identifier]          # only match code, not strings/comments
    message: "Use the logger, not print()."
    severity: error
  no_double_money:
    name: "Double for money"
    regex: '\b(Double|Float)\b.*(amount|price|balance|money)'
    message: "Money must not be a floating-point type — use Decimal / a Money value type."
    severity: error
    excluded: ".*Tests?\\.swift"
```

- `match_kinds` (syntax-token filter) prevents false hits inside string literals or comments; omit it to match everywhere. `capture_group` picks which regex group is flagged (default `0`).
- Regex runs with the `s` (dot matches newline) and `m` (multiline) flags **on**; prefix `(?-s)` to stop `.` from crossing lines.
- Custom rules are cheap but blunt (no AST) — for anything structural, prefer a real opt-in rule. Keep a catalogue in `references/custom-rules.md`.

<a id="inline"></a>
## Inline suppression

Disable rules in source only with a justification comment — never to sidestep a real fix.

```swift
// swiftlint:disable:next force_cast
let value = object as! Int                 // one line only

let legacy = thing as! Foo // swiftlint:disable:this force_cast

// swiftlint:disable force_unwrapping       // region: everything until re-enable
let a = maybe!
let b = other!
// swiftlint:enable force_unwrapping         // ALWAYS re-enable — unbounded disables rot

// swiftlint:disable:previous line_length   // applies to the line above
```

- Modifiers: `:next` / `:this` / `:previous` scope to a single line; a bare `disable` opens a region closed by `enable`.
- `all` disables/enables every rule — reserve for generated-file headers, not hand-written code.
- Prefer `:next`/`:this` over open regions; an unclosed `disable` silently suppresses far more than intended. Consider enabling the `blanket_disable_command` rule to flag region-disables that are never re-enabled.

<a id="integration"></a>
## Build integration

### SPM build-tool plugin (recommended)

`SimplyDanny/SwiftLintPlugins` vendors a pinned SwiftLint binary and runs it as a prebuild step. Works from `Package.swift` and from Xcode project targets.

```swift
// Package.swift  (swift-tools-version: 5.9+)
dependencies: [
    .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins",
             .upToNextMajor(from: "0.59.0")),   // pin; plugin versions mirror SwiftLint releases
],
targets: [
    .target(
        name: "MyFeature",
        plugins: [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")]
    ),
]
```

- Add the plugin to **every** target you want linted (it's per-target).
- **Xcode project (no Package.swift):** add the package, then in the target's **Build Phases → Run Build Tool Plug-ins** add `SwiftLintBuildToolPlugin`. It runs as a prebuild command and surfaces violations as Xcode warnings/errors.
- The plugin passes `--quiet --force-exclude` and hands SwiftLint the target's Swift files; your `.swiftlint.yml` `excluded:` still applies.
- **Command plugin** for one-off runs from the CLI (the `--fix` variant needs directory-write permission):

```bash
swift package plugin --allow-writing-to-package-directory swiftlint --fix
```

### Xcode run-script phase (when you need `--config` or one whole-project run)

Use this instead of the plugin when you lint all targets together, or pass `--config` explicitly. Add to **Build Phases → + New Run Script Phase**, after **Compile Sources**:

```bash
if [[ "$(uname -m)" == arm64 ]]; then export PATH="/opt/homebrew/bin:$PATH"; fi

if command -v swiftlint >/dev/null 2>&1; then
    swiftlint
else
    echo "warning: swiftlint not installed — https://github.com/realm/SwiftLint#installation"
fi
```

- The `arm64` PATH line is required so Apple-Silicon Homebrew (`/opt/homebrew/bin`) is found during a build.
- Uncheck **"Based on dependency analysis"** so it runs every build.
- Don't run both the plugin and a run-script that lint the same files — you'll double-report.

### Autocorrect

```bash
swiftlint --fix           # rewrites files in place for auto-correctable rules
swiftlint --fix && swiftlint   # fix, then lint the remainder
```

- **`--fix` overwrites files** — run only on a clean git tree so a bad rewrite is `git checkout`-able. Linting is skipped during a fix pass (offsets shift), so lint again afterward.
- Great for formatting rules (`trailing_comma`, `sorted_imports`); it never touches logic rules like `force_cast`.

<a id="analyzer"></a>
## Analyzer rules

Analyzer rules need type/usage info, so they run against a **compiler log**, not source alone:

```bash
xcodebuild -scheme App -destination 'generic/platform=iOS' \
    > xcodebuild.log                       # a full, clean build log
swiftlint analyze --compiler-log-path xcodebuild.log
```

- Only rules under `analyzer_rules:` run here (e.g. `unused_import`, `unused_declaration`). They are all opt-in — there is no disabled/only list for them.
- Slower and needs a fresh build log (incremental builds omit files) — run in CI or a nightly job, not on every keystroke.

<a id="reporters"></a>
## Reporters

```bash
swiftlint lint --reporter sarif --output swiftlint.sarif
```

- Formats: `xcode` (default), `json`, `sarif`, `checkstyle`, `markdown`, `junit`, `html`, `csv`, `emoji`, `summary`, `codeclimate`, `sonarqube`, `gitlab`, `github-actions-logging`, `relative-path`.
- Pick by consumer: **`xcode`** in the Xcode gutter; **`github-actions-logging`** for inline PR annotations; **`sarif`** for GitHub code-scanning / security dashboards (fintech audit trail); **`checkstyle`**/**`junit`** for Jenkins/GitLab; **`json`** for custom tooling.
- `--output` (`-o`) writes to a file; default is stdout. `reporter:` in the yaml sets the default without a flag.

<a id="strict"></a>
## strict vs lenient

- **`--strict`** (or `strict: true`): warnings become errors → **nonzero exit**. This is what makes CI actually block a PR. Use it on the CI lint step.
- **`--lenient`**: errors become warnings → never fails. Use temporarily while adopting a rule, or in a pre-baseline legacy repo so the build isn't blocked by pre-existing debt.
- Local dev: no flag (warnings stay warnings, don't block builds). CI: `--strict`.

<a id="baselines"></a>
## Baselines (adopting a legacy codebase)

A baseline records today's violations so future runs report **only new** ones — the key to turning on strict linting for a fintech app with thousands of existing warnings without a cleanup sprint.

```bash
# 1. Snapshot current violations once, commit the file:
swiftlint lint --write-baseline swiftlint-baseline.json

# 2. Everywhere after (dev + CI), filter against it:
swiftlint lint --baseline swiftlint-baseline.json --strict
```

Or in yaml:

```yaml
baseline: swiftlint-baseline.json         # filter against it
# write_baseline: swiftlint-baseline.json  # (re)generate it
```

- New code is held to the full rule set; legacy violations stay silent until touched.
- Commit the baseline. Regenerate it deliberately (a shrinking baseline = debt paydown you can track); never let CI auto-rewrite it, or regressions get absorbed.
- The `swiftlint baseline` subcommand offers operations on an existing baseline (e.g. reporting/comparing) — run `swiftlint baseline --help` for the current verbs before scripting them.

<a id="ci"></a>
## CI

- Run linting as its **own fast job**, separate from build/test, with the pinned plugin binary or a pinned Homebrew/Mint install.
- Gate with `--strict` and a `--baseline` so only new violations fail.
- Emit machine-readable output for annotations: `--reporter github-actions-logging` (or `sarif` for code-scanning).
- Fastlane wrapper (see `ci-cd-patterns` for full pipelines):

```ruby
swiftlint(
  mode: :lint,
  config_file: ".swiftlint.yml",
  reporter: "github-actions-logging",
  strict: true,
  raise_if_swiftlint_error: true
)
```

- Full GitHub Actions / GitLab / danger recipes in `references/ci-recipes.md`.

<a id="rollout"></a>
## Rollout strategy (legacy → enforced)

1. **Land config non-blocking.** Add `.swiftlint.yml` with a conservative rule set and integrate via the SPM plugin. Keep CI `--lenient` (or no gate) so nothing breaks day one.
2. **Autocorrect the mechanical debt.** `swiftlint --fix` on a clean tree, one PR, review the diff. Clears most formatting violations instantly.
3. **Baseline the rest.** `--write-baseline`, commit it. Flip CI to `--strict --baseline` so **new** code is fully enforced while legacy is grandfathered.
4. **Expand rules incrementally.** Add opt-in rules a few at a time; each addition is one PR (config change + its `--fix`/manual cleanup), never a mega-PR.
5. **Pay down the baseline.** Track its size; regenerate as modules get cleaned so it only shrinks.

<a id="checklist"></a>
## Correctness checklist

- [ ] SwiftLint version pinned (SPM plugin `.upToNextMajor` / Mintfile) — same version on every dev machine and CI.
- [ ] `.swiftlint.yml` at repo root; generated code (`Generated`, protobuf, R.swift) in `excluded:`.
- [ ] Not mixing `only_rules` with `disabled_rules`/`opt_in_rules` (mutually exclusive); if `only_rules` + custom rules, `custom_rules` is in the list.
- [ ] Integrated once per surface — SPM plugin **or** run-script, not both on the same files (double-reporting).
- [ ] Run-script phase includes the `arm64` `/opt/homebrew/bin` PATH line and is not gated on dependency analysis.
- [ ] `--fix` only ever run on a clean git tree; lint again after (fixing skips linting).
- [ ] CI lint job runs `--strict` so warnings block the PR; local dev stays non-blocking.
- [ ] Legacy repo adopted via `--write-baseline` → committed → `--strict --baseline`; baseline only shrinks.
- [ ] Analyzer rules (`unused_import`, etc.) run via `swiftlint analyze` with a fresh `--compiler-log-path`, not expected under `lint`.
- [ ] Reporter matches the consumer (`github-actions-logging` for PR annotations, `sarif` for code-scanning, `xcode` for the IDE).
- [ ] Inline `disable`s are `:next`/`:this` or an explicitly re-`enable`d region — no unbounded blanket disables, no `all` in hand-written code.
