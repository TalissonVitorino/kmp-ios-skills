# SwiftLint CI recipes

Principles: pin the version, run linting as its own fast job, gate with `--strict`,
filter legacy debt with `--baseline`, emit machine-readable output for annotations.
For full pipeline scaffolding (signing, caching, matrix) see the `ci-cd-patterns` skill.

## GitHub Actions

```yaml
# .github/workflows/swiftlint.yml
name: SwiftLint
on:
  pull_request:
    paths: ['**/*.swift', '.swiftlint.yml', 'swiftlint-baseline.json']

jobs:
  swiftlint:
    runs-on: macos-15          # ships a recent Xcode toolchain
    steps:
      - uses: actions/checkout@v4
      - name: Install pinned SwiftLint
        run: brew install swiftlint            # or `mint bootstrap` against a Mintfile
      - name: Lint
        run: |
          swiftlint lint \
            --strict \
            --baseline swiftlint-baseline.json \
            --reporter github-actions-logging
```

- `github-actions-logging` turns violations into inline PR annotations.
- `--strict` makes any violation fail the job; `--baseline` grandfathers legacy debt.
- To pin exactly, install via Mint (`Mintfile`: `realm/SwiftLint@0.59.0`) or vendor the SPM plugin and run `swift package plugin swiftlint` instead of Homebrew.

### SARIF upload (code-scanning / audit trail)

```yaml
      - name: Lint (SARIF)
        run: swiftlint lint --reporter sarif --output swiftlint.sarif || true
      - uses: github/codeql-action/upload-sarif@v3
        with: { sarif_file: swiftlint.sarif }
```

`|| true` keeps the upload step reachable even when violations set a nonzero exit; the
gating decision lives in the separate `--strict` step above.

## GitLab CI

```yaml
swiftlint:
  stage: test
  tags: [macos]
  script:
    - swiftlint lint --strict --baseline swiftlint-baseline.json --reporter checkstyle --output swiftlint.xml
  artifacts:
    reports:
      codequality: swiftlint.xml
```

## Fastlane

```ruby
lane :lint do
  swiftlint(
    mode: :lint,
    config_file: ".swiftlint.yml",
    reporter: "github-actions-logging",
    strict: true,
    raise_if_swiftlint_error: true      # fail the lane on nonzero exit
  )
end
```

Autocorrect lane (run only where a commit-back is intended):

```ruby
lane :lint_fix do
  swiftlint(mode: :autocorrect, config_file: ".swiftlint.yml")
end
```

## Danger (PR-scoped comments)

`danger-swiftlint` runs SwiftLint only on the files changed in the PR and posts inline
comments — lighter than gating the whole tree, useful as a first adoption step.

```ruby
# Dangerfile
swiftlint.config_file = '.swiftlint.yml'
swiftlint.strict = true
swiftlint.lint_files inline_mode: true
```

## Nightly analyzer job

Analyzer rules need a compiler log, so run them on a schedule, not per-PR:

```bash
xcodebuild -scheme App -destination 'generic/platform=iOS' clean build > xcodebuild.log
swiftlint analyze --compiler-log-path xcodebuild.log --reporter json --output analyze.json
```

A `clean build` is required — incremental builds omit files from the log, so analyzer
rules silently skip them.

## Notes

- Cache nothing that affects lint results (config, baseline) but do cache the SwiftLint
  binary/install to speed the job.
- Keep the lint job independent of build/test so a lint failure gives a clear, fast signal.
- Regenerate the baseline in a deliberate, reviewed PR — never let CI overwrite it, or new
  regressions get absorbed into "grandfathered" debt.
