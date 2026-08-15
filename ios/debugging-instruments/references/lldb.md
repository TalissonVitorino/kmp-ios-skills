# LLDB — deep reference

Companion to `debugging-instruments`. Short forms in parentheses. `help <cmd>`, `apropos <term>`.

## Command grammar

LLDB commands are `<noun> <verb> [options] [args]`. Most have a terse alias:

| Full | Alias | Does |
|---|---|---|
| `breakpoint set` | `b` / `br s` | create breakpoint |
| `breakpoint list` | `br l` | list |
| `frame variable` | `v` / `fr v` | read locals **without running code** |
| `expression` | `e` / `p` / `po` | evaluate an expression (runs code) |
| `thread backtrace` | `bt` | backtrace |
| `thread step-over` | `n` / `next` | step over |
| `thread step-in` | `s` / `step` | step into |
| `thread step-out` | `finish` | run to caller |
| `process continue` | `c` / `continue` | resume |
| `image lookup` | `im loo` | resolve symbols/addresses |

## Breakpoints — advanced

```lldb
# By name / file / regex / selector
breakpoint set -n "Ledger.settle(_:)"
breakpoint set -f Ledger.swift -l 42
breakpoint set --func-regex 'authorize|capture'
breakpoint set -E swift                       # stop on any Swift throw
breakpoint set -E swift -O InsufficientFunds  # only this error type

# Condition + hit count
breakpoint set -n charge -c 'amount > 10_000'
breakpoint modify -i 3 1                       # ignore first 3 hits of bp 1
breakpoint modify -c 'retryCount == maxRetries' 1

# Auto-actions (log-and-continue, a "poor man's printf")
breakpoint command add 1
> p "settling \(order.id) for \(amount)"
> continue
> DONE
breakpoint command add -o "bt" -o "continue" 2   # one-liner form

# One-shot, then delete itself
breakpoint set -n foo -o                       # (-o = --one-shot)

# Manage
breakpoint list
breakpoint disable 1 / enable 1 / delete 1
breakpoint name add MyGroup 1 2 3              # tag a set, toggle together
```

- Set breakpoints before symbols load with `breakpoint set -n symbol -s ModuleName` (`--shlib`); LLDB resolves it when the image maps.
- Auto-continue actions turn a breakpoint into structured logging without recompiling — invaluable in a flow you cannot easily rebuild.

## Watchpoints

Hardware-backed, so **few and small** (4-8 byte slots). Stop when memory is read/written.

```lldb
watchpoint set variable self.balance          # write by default
watchpoint set variable -w read_write self.state
watchpoint set expression -- &globalCache     # arbitrary address
watchpoint set expression -s 8 -- 0x600000abc # size 8 at address
watchpoint modify -c 'balance < 0'            # only trip on the bad value
watchpoint list ; watchpoint delete 1
```

- Best use: "something sets `state` to `.settled` too early — who?" Set the watchpoint, `continue`, and read `bt` when it fires.
- If you get "too many hardware watchpoints", delete unused ones; the count is CPU-limited.

## Reading values — `po` vs `p` vs `v`

- `v` (`frame variable`) reads the variable from memory — **no code execution**, no side effects, works even when expression evaluation is broken (optimized frames, corrupted state). Use it first.
- `p` (`dwim-print`) prints a value with type structure, running formatters.
- `po` prints `debugDescription` / `description` — object-centric.
- `expression` is the full form: run code, mutate state, switch language.

```lldb
v                              # all locals + args in this frame
v -a                           # (--no-args) locals only
v -f x balance                 # format hex; also: d, u, o, b, c, f, p (pointer)
v -D 2 tree                    # (--depth) limit nested expansion
v -R response                  # (--raw) skip synthetic/summary formatters
p order.items.count
po viewController.view         # rich object dump
expression -- self.retryCount = 0            # mutate live
expression -l objc -O -- [self.view recursiveDescription]   # ObjC view tree
expression -p -- import Foundation           # (--top-level) add imports/decls
```

- Swift optionals: `p maybe` shows `.some/.none`; `po maybe!` unwraps.
- Conform domain types (`Money`, `Transaction`) to `CustomDebugStringConvertible` so `po` prints ledger-readable output.
- `expression` runs in-process on the current thread — it can deadlock if that thread holds a lock; prefer `v` when the process is wedged.

## Frames & threads

```lldb
bt                     # current thread backtrace
bt all                 # every thread (find the blocked/main one)
frame select 4         # (f 4) move to frame 4
frame info
up / down              # walk the stack
thread list
thread select 2
thread return          # force current frame to return (skip rest) — dangerous
```

## Images & symbols

```lldb
image list                                   # loaded binaries + load addresses + UUIDs
image list -b MyApp
image lookup -a 0x1049c                       # address -> symbol + source:line
image lookup -v -a 0x1049c                    # verbose (full source info)
image lookup -n "Ledger.settle(_:)"           # symbol -> address/range
image lookup -rn 'authorize'                  # regex over symbols
image lookup -t Transaction                   # look up a type
```

- `image lookup -a` is the interactive equivalent of `atos` — resolves any address from a `bt` or crash to symbol + file:line on an attached process.

## Persistence & ergonomics

- `~/.lldbinit` runs at startup; add aliases:
  ```lldb
  command alias poc expression -l objc -O --
  command alias bpm breakpoint set --func-regex
  ```
- `command script import ~/tools/mycmds.py` loads Python-defined commands.
- `settings set target.load-cwd-lldbinit-file true` to allow per-project `.lldbinit`.
- Type formatting: `type summary add -s "${var.code}: ${var.amount}" Money` gives every `Money` a one-line summary in `v`/`p`.

## Attaching

```bash
lldb -n MyApp                 # by name (waits if not running: --waitfor)
lldb -p 12345                 # by pid
lldb -- ./MyTool arg1         # launch under lldb
```

In-session: `process attach -n MyApp -w` (wait for next launch), `process detach`.
