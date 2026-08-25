---
name: mobile-checkpoint
description: Checkpoint workflow for mobile development safety. Save/restore Android project state at critical points.
---

# Mobile Checkpoint Skill

Git-based checkpoint workflow for Android/KMP development: save a known-good state before a risky operation, restore cleanly if it goes wrong. Checkpoints are ordinary git commits plus a `checkpoint/*` tag — no extra tooling.

## When to Use

**Before risky operations:**
- Large refactors (MVI migration, architecture changes)
- Gradle/AGP/Kotlin upgrades, dependency bumps in `gradle/libs.versions.toml`, `./gradlew wrapper --gradle-version <x>`
- Manifest changes (permissions, components)
- Navigation restructuring
- Experimental features

**After milestones:**
- Feature completion, all tests passing, successful release build

## Checkpoint Workflow

### 1. Save (before the operation)

```bash
# Verify the state is worth saving
git status
./gradlew check

# Commit everything, including untracked files
git add -A
git commit -m "checkpoint: before-<operation>"
git tag checkpoint/before-<operation>
```

For a quick save of uncommitted work without touching branch history:

```bash
git stash push -u -m "before-<operation>"   # -u includes untracked files
git stash apply                              # keep working with the same tree
```

### 2. Perform the operation

Make the changes, then verify: `./gradlew build` (or `check` for the fast lane).

### 3. After

**Success** — checkpoint the new state:

```bash
git add -A && git commit -m "checkpoint: after-<operation>"
```

**Failure** — restore:

```bash
# Optionally keep the failed attempt for later inspection.
# `git branch` alone captures only commits, so commit the WIP first:
git switch -c failed-<operation>
git add -A && git commit -m "failed: <operation>"
git switch -

# Back to the checkpoint (destructive to uncommitted changes)
git reset --hard checkpoint/before-<operation>

# reset --hard rewinds tracked files and deletes files added to the
# index since the checkpoint, but leaves UNTRACKED files in place.
# Preview leftovers, then remove them:
git clean -nd
git clean -fd
```

Avoid `git clean -x` in Android projects — it also deletes `local.properties` and build caches.

## What a Checkpoint Covers

Everything git tracks at commit time: `build.gradle.kts` files, `gradle/libs.versions.toml`, `gradle/wrapper/gradle-wrapper.properties`, manifests, source, and tests. Not covered (machine state, not project state): `local.properties`, `~/.gradle`, build outputs. Git snapshots test *code*, not test *results* — re-run `./gradlew test` after a restore to confirm the state.

## Restore Variants

| Situation | Command |
|-----------|---------|
| Discard everything since the checkpoint | `git reset --hard checkpoint/<name>` |
| See what changed since the checkpoint | `git diff checkpoint/<name>` |
| Restore only dependency/build files | `git restore --source=checkpoint/<name> -- gradle/libs.versions.toml app/build.gradle.kts` |
| Try the risky change in isolation instead | `git worktree add ../try-<operation>` |
| Recover a stash-based save | `git stash list`, then `git stash pop` |

`git worktree add <path>` with no commit-ish creates a branch named after the path's basename from HEAD. The new worktree has no `local.properties` (it is gitignored), so Gradle resolves the SDK from `ANDROID_HOME` — export it, or copy `local.properties` across, before building there.

`git stash pop` aborts if the current tree conflicts with the stash. Discard first (`git restore --staged --worktree .` plus `git clean -fd`), then pop.

After restoring build files, run `./gradlew build --refresh-dependencies` if resolution seems stale (the flag only refreshes dependencies the running tasks actually resolve, so pair it with a task).

## Naming Convention

| Pattern | Example |
|---------|---------|
| `checkpoint/before-<operation>` | `checkpoint/before-mvi-migration` |
| `checkpoint/after-<operation>` | `checkpoint/after-koin-refactor` |
| `checkpoint/<feature>-complete` | `checkpoint/auth-flow-complete` |

Avoid `checkpoint1`, `save`, `temp`. Release candidates use normal release tags (`v1.2.0-rc1`), not checkpoint tags.

## Managing Checkpoints

```bash
git tag -l 'checkpoint/*'                     # list
git tag -d checkpoint/before-mvi-migration    # delete
git bundle create ~/backups/repo.bundle --all # full offline backup, restorable with git clone
```

Checkpoint commits and tags are local scaffolding — do not push them. Before opening an MR, squash or drop `checkpoint:` commits with an interactive rebase (see the `curar-historico-de-commits` skill for the cleanup workflow).

## Best Practices

1. **Verify before saving**: a checkpoint of a broken build is worthless — run `./gradlew check` first.
2. **Confirm before hard reset**: `git log --oneline -1 checkpoint/<name>` must resolve, and anything you want to keep must be branched or stashed first. `git reflog` can recover the old branch tip afterwards, but uncommitted changes discarded by `--hard` are unrecoverable.
3. **Name by operation**, never by number or date alone.
4. **Clean up**: delete stale `checkpoint/*` tags and squash checkpoint commits before merge.
