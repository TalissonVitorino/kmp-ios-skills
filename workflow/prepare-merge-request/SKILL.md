---
name: prepare-merge-request
description: Use when about to open or update a pull/merge request, push a feature branch, run `git add`/`git commit` on finished work, or state that the test suite passes — in a Kotlin Multiplatform or Android Gradle project. Three gates in order - prove the suites actually ran by counting JUnit XML instead of trusting BUILD SUCCESSFUL, curate the branch history into logical commits, and push under the developer's own authorship with no AI attribution.
---

# Prepare a branch for review

Three gates, in this order. Each one is cheap to skip and expensive to skip.

1. **Evidence** — the suites actually ran, and what's green is what you're pushing.
2. **History** — the reviewer sees the final logical shape of the change, not the iteration diary.
3. **Authorship** — the commits and the MR are the developer's, with no tooling signature.

**Announce at the start:** "I'm using the prepare-merge-request skill before pushing."

**When NOT to use:** during development — run the single class you're working on and commit freely. This is the pre-push pass.

---

## Gate 1 — Evidence

**Core principle:** `BUILD SUCCESSFUL` is not evidence. Two things produce it with zero tests executed — the wrong Gradle task, and the build cache. Evidence is a count of executed tests, read from the JUnit XML result files.

Step 1 comes before the tests on purpose: a green suite on a dirty working tree proves nothing.

### 1.1 Is what you're pushing what you tested?

```bash
git status --short
```

Every `??` (untracked) or `M` file that belongs to the change has to make it into the commit. **A new untracked test does not exist for the reviewer** — the suite passes locally and the MR ships without it. Worse: new classes depending on an untracked helper won't even compile on CI. Check the support files too (fakes, test DI modules, helper packages).

### 1.2 No secrets on the way into `git add`

```bash
git status --short | grep -iE "secret|\.env|credential|keystore|\.properties|xcconfig"
```

Anything that shows up: confirm it is ignored **before** any `git add -A`. A comment inside the file saying "this file is gitignored" is not a guarantee — check with `git check-ignore -v <file>`.

### 1.3 Delete stale results

```bash
find . -path "*/build/*" -type d \( -iname "*test-results*" \) -exec rm -rf {} + 2>/dev/null
```

Without this, step 1.7 counts XML from an earlier run. You run **one** suite, the script sums all of them and reports `TOTAL=2104 failures=0` — a green light for suites you never executed. Same false confidence as `BUILD SUCCESSFUL`, only more convincing because it comes with numbers. Once deleted, every XML present necessarily belongs to this run.

### 1.4 Android/JVM unit suite

```bash
./gradlew testDebugUnitTest testAndroidHostTest --rerun-tasks
```

`--rerun-tasks` is mandatory: without it Gradle returns `BUILD SUCCESSFUL` in ~300ms with everything `UP-TO-DATE` and **zero tests executed**.

Confirm the task names for your repo — they differ per layout:

```bash
./gradlew tasks --all | grep -iE "test.*(unit|host)"
```

Avoid bare `./gradlew test`. In a typical KMP repo it schedules only the modules applying the Android plugin's JVM variant; shared modules, whose tasks are named after their targets (`testAndroidHostTest`, `jvmTest`, `desktopTest`), are silently left out.

### 1.5 Apple target suite

```bash
./gradlew iosSimulatorArm64Test
```

Easy to forget. It runs the same `commonTest` sources on the Apple target and catches broken `expect`/`actual` pairs, Kotlin/Native-only failures, and code that only compiles on the JVM. Use the target your project declares — check with `./gradlew tasks --all | grep -i "iosSimulator\|macos"`.

### 1.6 Instrumented UI tests

```bash
adb devices                                   # is a device connected?
emulator -avd <your-avd> -no-snapshot &       # if not
./gradlew :app:connectedDebugAndroidTest
```

When every instrumented test fails at once with something like `NoSuchMethodException: android.hardware.input.InputManager.getInstance`, that's an Espresso/AndroidX-test incompatibility with a newer platform image — drop to an older API level instead of debugging the tests. `connectedAndroidTest` does not cache; it re-executes on every call.

### 1.7 Count what actually ran

```bash
python3 - <<'PY'
import os, re, collections
tot = collections.Counter(); bad = 0
for root, _, files in os.walk('.'):
    if '/build/' not in root + '/' or 'test-results' not in root.lower(): continue
    for f in files:
        if not f.endswith('.xml'): continue
        data = open(os.path.join(root, f), encoding='utf-8', errors='ignore').read()
        m = re.search(r'<testsuite[^>]*tests="(\d+)"', data)
        if not m: continue
        bucket = ('instrumented' if 'androidtest-results' in root.lower()
                  else 'apple' if 'ios' in root.lower() or 'macos' in root.lower()
                  else 'unit')
        tot[bucket] += int(m.group(1))
        for attr in ('failures', 'errors'):
            v = re.search(attr + r'="(\d+)"', data)
            bad += int(v.group(1)) if v else 0
for bucket, n in sorted(tot.items()): print(f"  {bucket:16} {n:5d}")
print(f"\nTOTAL={sum(tot.values())}  failures+errors={bad}")
PY
```

```
  apple             1028
  instrumented         1
  unit              1065

TOTAL=2094  failures+errors=0
```

**Every suite your project has must appear as a line. A missing line means a skipped step.**

**The numbers themselves are not a gate.** Establish the repo's baseline once, then treat a lower-than-expected count as a *hypothesis*, not proof — the count grows with every new test, and any figure written down goes stale. Confirm before raising the alarm:

```bash
grep -rc "@Test" <test-source-dir> --include="*.kt" | grep -v ":0"
```

If it matches what's on disk, the suite ran complete and it's your baseline note that's out of date.

What is **never** negotiable is `failures+errors`. That has to be 0.

The `.lower()` matters: the directory is `androidTest-results`, with a capital T — a case-sensitive filter on `test-results` silently drops the instrumented results and you "verify" a subset without noticing.

| Suite | Task | Caches? |
|:---|:---|:---|
| Android/JVM unit | `testDebugUnitTest testAndroidHostTest` | yes → `--rerun-tasks` |
| Apple target | `iosSimulatorArm64Test` | yes |
| Instrumented UI | `:app:connectedDebugAndroidTest` | no |
| ❌ never rely on | bare `test` | — |

If the project uses environment/flavor properties (`-Penv=...`, `-Pflavor=...`), append them to every command so all suites run against the same configuration.

---

## Gate 2 — History

**Core principle:** the final content (the tree) must stay identical; only the *shape* of the commits changes. No code is ever lost on the way.

**Skip this gate when:** the branch is shared and someone else has based work on it (rewriting breaks their history), the history is already merged, or it's a single already-clean commit.

### Noise taxonomy

| Type | Example | Action |
|---|---|---|
| Process artifacts | `docs/specs/...`, plans, handoffs | Untrack (`git rm --cached`), **keep on disk** + back up |
| Add+remove churn | `feat: flag X` … later `refactor: drop flag X` | Collapse — neither belongs in the result |
| Iteration / WIP / fixup | `wip`, `fix import`, `fix typo` | Squash into the parent logical commit |
| Review fix applied later | `fix: rename field Y` | Squash into the commit that introduced the code |
| Self-cancelling revert | `A` … `revert A` | Drop both |

### 2.1 Inventory, then rebase onto the base

So the MR is born up to date. Resolve conflicts before reshaping.

```bash
git fetch origin <base>
BASE=origin/<base>                       # e.g. origin/develop
git log --oneline $BASE..HEAD
git diff --name-only $BASE..HEAD
git rebase $BASE
```

### 2.2 Back up what leaves git but stays on disk

Process artifacts leave git but **remain on the machine** as files. Back them up separately and rely on `reset --soft` to preserve the working tree.

```bash
git show HEAD:docs/path/file.md > ~/backup-docs/file.md
```

**Never** reshape with `git checkout -B branch base` or `git reset --hard`: both reset the working tree and delete those files from disk.

### 2.3 Reshape with `reset --soft`

The most reliable technique for reformatting everything (agent harnesses generally can't drive `git rebase -i`). Save the old HEAD to verify afterwards.

```bash
OLD=$(git rev-parse HEAD)
git reset --soft $BASE
git restore --staged .
```

Re-stage by logical unit (per module/layer) and commit once per group:

```bash
git add <domain files>      && git commit -m "feat(domain): ..."
git add <app files>         && git commit -m "feat(app): ..."
```

Process artifacts are simply **never added** — don't create a "remove docs" commit; that's noise too.

### 2.4 Verify nothing was lost

```bash
git diff $OLD HEAD                          # should show ONLY the docs/noise removals
git diff $OLD HEAD -- . ':(exclude)docs'    # should be empty (code identical)
git status --short                          # docs/ should show up as ?? (untracked)
ls docs/...                                 # CONFIRM the untracked files still exist on disk
```

---

## Gate 3 — Authorship

The change is the developer's work. The history and the MR must say so — nothing in them should advertise the tooling that helped write it.

### 3.1 The commits are the developer's

```bash
git config user.name && git config user.email          # the developer's, not a bot's
git log $BASE..HEAD --format='%an <%ae>  %s'           # every line, same person
```

If a commit landed under the wrong identity, fix it during the reshape (Gate 2 rewrites the commits anyway) or, for the last one, `git commit --amend --author="Name <email>"`.

### 3.2 No tooling signature in messages or MR body

```bash
git log $BASE..HEAD --format='%B' | grep -inE "co-authored-by|generated with|🤖|assistant"
```

Anything that matches gets removed. Specifically, none of these belong in a commit message, a commit trailer, or the MR/PR description:

- `Co-Authored-By:` trailers naming an assistant or bot
- "Generated with / Created by / Written by \<tool\>" footers
- 🤖 badges, or any "AI-assisted" note in the MR body

Commit messages describe **what changed and why**, in the imperative, and stop there. The MR description covers context, scope, and how to test — same rule.

Because Gate 2 rewrites every commit message through `reset --soft`, the cleanest fix is simply not to reintroduce the trailers when re-committing. If the branch isn't being reshaped, amend the offending commits.

### 3.3 Make it stop happening

The trailers usually come from a default in the coding agent, not from the developer. Turn them off at the source once, instead of grepping them out every time — put a line in the repo's agent instructions file (`CLAUDE.md`, `AGENTS.md`, `.github/copilot-instructions.md`, whichever applies):

```markdown
Never add `Co-Authored-By` trailers, "Generated with" footers, or any mention of AI
tooling to commit messages or pull/merge request descriptions.
```

### 3.4 Present the plan, then push

Show the final `git log --oneline $BASE..HEAD` and **wait for approval** before:

```bash
git push --force-with-lease origin <branch>
```

`--force-with-lease`, never bare `--force`: the latter overwrites remote work with no check.

---

## Common errors

| Symptom | What's happening |
|:---|:---|
| `BUILD SUCCESSFUL in 300ms` | Cache. Nothing ran. Use `--rerun-tasks`. |
| `BUILD SUCCESSFUL` but few tests | Wrong task (bare `test` instead of the real ones). |
| All instrumented tests red | Emulator image too new for Espresso. Drop an API level. |
| Green locally, red on CI | An untracked file never pushed. Back to 1.1. |
| Count matches but you ran one suite | Stale XML on disk. You skipped 1.3. |
| A "remove docs" commit in the plan | Don't remove them in a commit — never add them at all. |
| Untracked docs vanished from disk | You reshaped with `reset --hard` or `checkout -B`. Restore from backup. |

## Red flags — stop

- You're about to give a verdict from `BUILD SUCCESSFUL` alone
- You ran the tests before checking `git status`
- You're about to `git add -A` without having checked for secrets
- The count didn't match and you were going to proceed anyway
- `git diff $OLD HEAD -- . ':(exclude)docs'` came back non-empty → you changed code by accident
- The branch is shared/public and you're about to rewrite it
- A commit or the MR body carries a tooling signature
- You're about to force-push without having shown the plan

**All of them mean the same thing: you don't have evidence yet.**
