# .swiftlint.yml — full key reference

All keys are optional; SwiftLint applies the nearest config found by walking up from
each linted file. Verify a rule's exact options with `swiftlint rules <rule_id>`.

## Rule-selection keys

| Key | Meaning |
|---|---|
| `disabled_rules` | Turn OFF rules that are on by default. |
| `opt_in_rules` | Turn ON rules that are off by default. `all` enables every opt-in rule except those in `disabled_rules`. |
| `only_rules` | Allow-list — ONLY these rules run. Mutually exclusive with `disabled_rules` and `opt_in_rules`. |
| `analyzer_rules` | Separate list run only by `swiftlint analyze`. All opt-in; no disabled/only counterpart. |

## Path keys

| Key | Meaning |
|---|---|
| `included` | If present, lint only these paths (still minus `excluded`). Case-sensitive, relative to the config file. |
| `excluded` | Skip these paths; takes precedence over `included`. Glob patterns (`**/Generated`) supported. |

- When SwiftLint is invoked with explicit file paths (build plugins do this), `excluded` is honored only if `--force-exclude` is passed. The SwiftLintPlugins build-tool plugin passes it automatically.

## Output / behavior keys

| Key | Default | Meaning |
|---|---|---|
| `reporter` | `xcode` | Output format. See the reporters table below. |
| `strict` | `false` | Warnings become errors (nonzero exit). |
| `lenient` | `false` | Errors become warnings (never fails). `strict` wins if both set on the CLI. |
| `baseline` | — | Path to a baseline file; filter out its recorded violations. |
| `write_baseline` | — | Path to write current violations to as a new baseline. |
| `allow_zero_lintable_files` | `false` | Don't error when no Swift files are found. |

## Config inheritance

| Key | Meaning |
|---|---|
| `parent_config` | Local path or `https://` URL to a lower-priority base config this one refines. |
| `child_config` | Local path or `https://` URL to a higher-priority config that refines this one. |
| `remote_timeout` | Seconds to wait for an `https` parent/child config (default 2). |
| `remote_timeout_if_cached` | Timeout when a cached copy exists (default 1). |

- CLI precedence: `swiftlint --config parent.yml --config child.yml` — first is parent, last is child (later wins).
- For reproducible CI, prefer a **vendored** copy of any shared config over a live `https://` fetch.

## Per-rule severity forms

```yaml
# 1. shorthand — just the severity
force_cast: warning

# 2. explicit severity
force_try:
  severity: warning

# 3. two thresholds, array form [warning, error]
type_body_length:
  - 300
  - 400

# 4. two thresholds, dictionary form
file_length:
  warning: 500
  error: 1200

# 5. rule-specific options + nested severity
identifier_name:
  min_length: 3
  max_length:
    warning: 50
    error: 60
  excluded: [id, x, y, uri, URL]
  allowed_symbols: ["_"]
```

## Reporters

| Reporter | Use |
|---|---|
| `xcode` (default) | `file:line:col: warning:` — Xcode gutter + terminal. |
| `github-actions-logging` | Inline PR annotations on GitHub Actions. |
| `sarif` | GitHub code-scanning / security dashboards; audit trail. |
| `json` | Custom tooling / dashboards. |
| `checkstyle` | Jenkins, GitLab Code Quality. |
| `junit` | JUnit-consuming CI reporting. |
| `markdown` | Human-readable reports, PR comments. |
| `html` | Standalone browsable report. |
| `codeclimate` / `sonarqube` / `gitlab` | Those platforms' native ingestion. |
| `csv`, `emoji`, `summary`, `relative-path` | Misc / local. |

```bash
swiftlint lint --reporter sarif --output swiftlint.sarif
swiftlint reporters        # list all available reporters and identifiers
```

## Useful CLI flags (lint / analyze)

| Flag | Effect |
|---|---|
| `--strict` | Warnings → errors (nonzero exit). |
| `--lenient` | Errors → warnings. |
| `--fix` (a.k.a. `--autocorrect`) | Rewrite files for correctable rules; linting skipped this pass. |
| `--baseline <path>` | Filter out violations recorded in the baseline. |
| `--write-baseline <path>` | Save current violations as a new baseline. |
| `--config <path>` | Explicit config (repeatable; parent → child). |
| `--reporter <name>` | Output format. |
| `--output` / `-o <path>` | Write output to a file (default stdout). |
| `--quiet` | Suppress "Linting…/Done linting" status lines. |
| `--force-exclude` | Apply `excluded` even for explicitly passed paths. |
| `--compiler-log-path <path>` | (analyze) compiler log to source type info from. |
| `--use-alternative-excluding` | Faster excluding for very large `excluded` lists. |

Subcommands: `lint` (default), `analyze`, `baseline`, `rules`, `reporters`, `docs`,
`generate-docs`, `version`. Run `swiftlint <subcommand> --help` for current options —
verify verb names (e.g. under `baseline`) against the installed version before scripting.
