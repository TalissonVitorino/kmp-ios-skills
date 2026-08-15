---
name: debugging-instruments
description: "Debug and profile a fintech iOS/macOS app with LLDB (breakpoints, po/p/expression, bt, frame variable, image lookup -address, watchpoints), the Xcode Memory Graph Debugger (retain cycles, MallocStackLogging backtraces), and Instruments templates (Time Profiler / CPU Profiler, Allocations, Leaks, Hangs, Animation Hitches, Energy Log, Network, SwiftUI). Also covers os_signpost / OSSignposter intervals + Points of Interest, the xctrace record/export/list CLI for CI, crash symbolication (atos, image lookup), and Xcode build-failure triage. Use when chasing a hang, leak, retain cycle, animation hitch, slow launch, energy drain, or a crash log — the interactive/on-device side. For production telemetry of the same signals use `metrickit`; for SwiftUI-update `.trace` analysis use `swiftui-expert-skill`; to drive the Simulator use `ios-simulator`; the Android/KMP trace counterpart is `perfetto-trace-analysis`."
---

# Debugging & Instruments (iOS / macOS)

Interactive debugging and performance profiling for a fintech iOS app: pause and
inspect with LLDB, find leaks and retain cycles with the Memory Graph Debugger,
and measure CPU / memory / hangs / hitches / energy / network with Instruments.
Grounded in the LLDB, Xcode, Instruments, and `os` (unified logging) tooling.
Target: iOS 26 era, Xcode 26.

- **Production counterpart:** `metrickit` — the *field* version of these signals (hangs, disk-writes, launch time, crashes) sampled from real users. Debug locally here; regress in CI/production there.
- **SwiftUI update traces:** `swiftui-expert-skill` owns deep `.trace` analysis of the SwiftUI instrument (View Body / Properties / Core Animation commits).
- **Simulator control:** `ios-simulator` (`simctl`) to install/launch/deep-link/screenshot the target you profile.
- **Android/KMP counterpart:** `perfetto-trace-analysis` (+ `perfetto-sql`) for the shared/Android side.

## Contents

- [Pick the right tool](#pick)
- [LLDB](#lldb)
- [Memory Graph Debugger](#memgraph)
- [Instruments templates](#instruments)
- [os_signpost / OSSignposter](#signpost)
- [xctrace CLI (CI)](#xctrace)
- [Symbolication](#symbolication)
- [Build-failure triage](#build)
- [Correctness checklist](#checklist)
- Depth: `references/lldb.md`, `references/instruments.md`

<a id="pick"></a>
## Pick the right tool

| Symptom | Tool |
|---|---|
| Wrong value / crash at a line | **LLDB** breakpoints + `po`/`p`/`v` |
| Object never deallocates, retain cycle | **Memory Graph Debugger** (+ MallocStackLogging) |
| Growing memory, no cycle | **Instruments → Allocations** (mark generations) |
| CPU-bound, slow method | **Time Profiler / CPU Profiler** |
| Main-thread stall > 250 ms | **Hangs** instrument (or Time Profiler) |
| Scroll/animation stutter | **Animation Hitches** |
| Battery drain | **Energy Log** |
| Slow/redundant requests | **Network** |
| SwiftUI re-render storms | **SwiftUI** instrument → `swiftui-expert-skill` |
| Measure a specific code region | **os_signpost / Points of Interest** |
| Repeatable profiling in CI | **`xctrace` CLI** |

- Always profile a **Release / optimized** build on a **real device** for timing (`-Onone` Debug numbers lie; the Simulator has no thermal/energy model).
- Reproduce first, then profile the narrow window. Wrap the region in a signpost so you can find it in the timeline instead of eyeballing.

<a id="lldb"></a>
## LLDB

Type `help <cmd>` / `apropos <word>` in the debugger. Short forms shown in parentheses.

### Breakpoints

```lldb
breakpoint set --name viewDidLoad          # (b viewDidLoad) by symbol
breakpoint set --file Ledger.swift --line 42
breakpoint set --selector paymentDidSettle:        # ObjC selector
breakpoint set --func-regex ^.*authorize.*         # regex over symbols
break set -n malloc_error_break                    # break on allocator errors
```

- **Conditions & actions** — evaluate without stopping:
  ```lldb
  breakpoint set -n charge --condition 'amount > 10000'
  breakpoint command add 1                 # attach commands to breakpoint #1
  > po transaction
  > continue
  > DONE
  ```
- `breakpoint modify -i 5 1` — ignore first 5 hits. `breakpoint list` / `breakpoint delete 1`.
- **Symbolic** breakpoints on framework internals: `-[UITableView _endCellAnimationsWithContext:]`, or `break set -E swift` to stop on any Swift error throw.
- **Watchpoints** — stop when memory *changes* (hardware, limited count):
  ```lldb
  watchpoint set variable self.balance     # (wa s v) break on write
  watchpoint set expression -- &_state     # by address
  watchpoint modify -c '_state == .settled'
  watchpoint list / watchpoint delete
  ```
  Ideal for "who mutates this property?" — set it, `continue`, read `bt` when it trips.

### Inspecting

- `po <expr>` — call `debugDescription` (object, "print object"). `p <expr>` — the newer unified `dwim-print`, structured value + type. `v <expr>` (`frame variable`) — read the variable **without executing code** (no side effects, works when the process can't run expressions).
- `p` / `expression` run real code in-process: `expression -- self.retryCount = 0` mutates live state; `expression -l objc -O -- [self view]` switches language.
- `frame variable --no-args` (`v -a`) — locals only. `frame variable -f x balance` — hex format.
- Navigate: `bt` (backtrace, `bt all` = every thread), `frame select 3` (`f 3`), `up` / `down`, `thread backtrace`, `frame info`.
- `image lookup --address 0x1049c` (`im loo -a`) — resolve a raw address (from a crash / `bt`) to symbol + source line. `image lookup -n symbolName`, `image lookup -rn regex`. See [Symbolication](#symbolication).
- `register read`, `memory read --format x --size 8 0x…` for the hard cases.

### Swift specifics

- Use `po`/`p` in the Swift context; drop to `expression -l objc` only for ObjC/CF objects.
- Optionals print as `.some`/`.none` — `po value!` or `p value` to unwrap.
- `po` on a struct calls `CustomDebugStringConvertible`; conform your `Money`/`Transaction` types so the ledger reads cleanly in the debugger.
- `command alias` your common lookups; more Swift-side recipes in `references/lldb.md`.

<a id="memgraph"></a>
## Memory Graph Debugger

Catches **retain cycles** and **leaks** visually: a snapshot of every live allocation and the references between them.

1. Run the app, exercise the suspect flow (present → dismiss a screen a few times).
2. Debug bar → **Debug Memory Graph** button. The left panel lists instances; the canvas shows the reference graph.
3. Select an object → inspector shows **inbound references** (who retains it) and, with stack logging on, the **allocation backtrace**.
4. Runtime issues (⚠️ purple) flag detected leaks and cycles automatically; filter the navigator to them.

### Enable allocation backtraces (MallocStackLogging)

Without this you see *that* an object leaked, not *where* it was born.

- **Scheme → Run → Diagnostics → Malloc Stack Logging.** Choose **"Live Allocations Only"** to keep the log small (enough for cycles/leaks); "All Allocations" also records freed objects for use-after-free hunts.
- Turn it **off** when done — it slows the app and inflates memory.
- Equivalent env var for CLI/CI runs: `MallocStackLogging=1` (or `MallocStackLoggingNoCompact=1`).

### Reading a cycle

- A cycle = two+ objects with `strong` references forming a loop (classically `self` ↔ a closure, or parent ↔ child, delegate held `strong`).
- Fix at the weakest sensible edge: `weak`/`unowned` on the back-reference, `[weak self]` capture lists in escaping closures, `weak var delegate`.
- Export the graph (`.memgraph`) for offline analysis: `File → Export Memory Graph`, then `leaks <file.memgraph>` / `malloc_history <file.memgraph> <address>` / `vmmap` on the command line.
- **Leaks vs. abandoned memory:** a retain cycle is a *leak* (unreachable, never freed). Memory that keeps growing but is still reachable (an unbounded cache, image blobs) is *abandonment* — find it with Allocations generations, not the graph. See `references/instruments.md`.

<a id="instruments"></a>
## Instruments templates

Launch: **Product → Profile (⌘I)** (builds Release), pick a template, or `xctrace list templates`. Record on device. Common templates and what they answer:

| Template | Key instruments | Use it for |
|---|---|---|
| **Time Profiler** | Time Profiler (sampled backtraces) + Hangs + Thread State | Where CPU time goes; main-thread stalls. Start here. |
| **CPU Profiler** | Higher-rate CPU sampling | Fine-grained hotspots in compute code. |
| **Allocations** | Allocations, VM Tracker | Heap growth, abandoned memory, transient churn. |
| **Leaks** | Leaks + Allocations | Cycles/leaks in a scripted run (CI-friendly). |
| **Animation Hitches** | Animation Hitches, Core Animation FPS | Scroll/transition stutter; hitch time vs. frame deadline. |
| **Energy Log** | Energy Impact, CPU/GPU/Network/Location | Battery drain, wake-ups, radio usage. |
| **Network** | HTTP Traffic, Network connections | Redundant/slow requests, connection reuse. |
| **SwiftUI** | View Body, View Properties, Core Animation Commits, Time Profiler | Re-render/update cost → hand to `swiftui-expert-skill`. |
| **Blank** + Points of Interest / os_signpost | your signposts | Measure exactly your code regions. |

### Workflow that actually finds things

- **Time Profiler:** invert the call tree (**Invert Call Tree** + **Hide System Libraries**) so *your* heaviest leaf frames rise to the top. Weight = samples, i.e. time. Pin the **Hangs** track: any red span is a main-thread block > ~250 ms — jump straight to that backtrace.
- **Allocations → generations:** press **Mark Generation** before an action and again after it completes and returns to baseline (e.g. open→close a screen). Anything still alive in that generation after teardown is suspect. Sort by "Persistent" bytes.
- **Animation Hitches:** the metric is *hitch time ratio* (ms of hitch per second of scrolling). Correlate spikes with a Time Profiler track in the same recording to see the offending commit.
- Record with **both** Time Profiler and Points of Interest so your signpost intervals sit above the CPU flame — you see cost *and* which of your regions caused it.
- Deeper per-template guidance (call-tree filters, VM Tracker, hitch anatomy) in `references/instruments.md`.

<a id="signpost"></a>
## os_signpost / OSSignposter

Emit signposts to bound and label regions; they render as intervals/events on the **Points of Interest** and **os_signpost** instruments. Near-zero overhead when not tracing. `OSSignposter` (iOS 15+) is the Swift API; `os_signpost(_:)` is the older C-style call and the instrument's name.

```swift
import OSLog

// Custom category → its own os_signpost lane; `.pointsOfInterest` → the Points of Interest instrument.
let signposter = OSSignposter(subsystem: "com.acme.bank", category: "Checkout")

func settle(_ order: Order) async throws {
    let id = signposter.makeSignpostID()
    // Static interval name + dynamic metadata via the os_log format API:
    let state = signposter.beginInterval("settle", id: id, "orderID=\(order.id, privacy: .public)")
    defer { signposter.endInterval("settle", state) }   // state MUST be passed back to end

    let auth = try await authorize(order)
    signposter.emitEvent("authorized", id: id)          // instantaneous marker on the same interval
    try await capture(auth)
}
```

- `beginInterval` returns an `OSSignpostIntervalState` you **must** hand to the matching `endInterval` — that pairing is how Instruments computes duration. Reuse one `id` for a begin/event/end trio; use a fresh `makeSignpostID()` per concurrent operation so overlapping intervals don't cross.
- Interval/event **names must be string literals** (they key the instrument); put runtime data in the trailing `os_log`-style arguments (`privacy: .public` to keep values in the trace — default is redacted).
- To show up on **Points of Interest**, construct with `category: .pointsOfInterest`.
- Guard expensive metadata: `if signposter.isEnabled { … }`.
- Convenience: `signposter.withIntervalSignpost("name", id: id) { … }` wraps a synchronous region (begin/end via `defer` internally).
- Not seeing intervals? You profiled a build where signposts were disabled, or begin/end names/ids don't match — verify with the os_signpost instrument's detail view.

<a id="xctrace"></a>
## xctrace CLI (CI / automation)

`xcrun xctrace` drives Instruments headlessly — regression-gate performance in CI. (Legacy `instruments -t` is removed; use `xctrace`.)

```bash
# Discover
xcrun xctrace list templates
xcrun xctrace list devices          # names + UDIDs for --device

# Record: launch a fresh install, cap the run, write a .trace
xcrun xctrace record \
  --template 'Time Profiler' \
  --device 'iPhone 16 Pro' \
  --time-limit 20s \
  --output run.trace \
  --launch -- /path/to/App.app

# Or attach to a running process (by pid or name)
xcrun xctrace record --template 'Allocations' --attach MyApp --output alloc.trace --time-limit 30s
```

- Export for parsing (assertions in CI):
  ```bash
  xcrun xctrace export --input run.trace --toc                 # list exportable tables (XML)
  xcrun xctrace export --input run.trace \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'
  ```
- `--time-limit 20s|1m`, `--all-processes`, `--append-run` to add runs to an existing `.trace`. `--target-stdout -` streams the app's stdout; it's mutually exclusive with `--attach`.
- CI pattern: record with a Leaks or Allocations template, export the TOC, fail the job if the leaked-bytes/table count exceeds a threshold. Full export XPath recipes in `references/instruments.md`.
- For SwiftUI-update trace parsing scripts, defer to `swiftui-expert-skill`.

<a id="symbolication"></a>
## Symbolication

Turn addresses (crash logs, `bt` frames, exported traces) into `symbol + file:line`. Requires the matching **dSYM** (Release builds strip symbols into it — archive and keep it).

- Match by build UUID: `dwarfdump --uuid MyApp.app/MyApp` must equal the crash report's binary UUID (and the dSYM's).
- One address:
  ```bash
  atos -o MyApp.app.dSYM/Contents/Resources/DWARF/MyApp -arch arm64 -l 0x104080000 0x104099abc
  ```
  `-l` is the binary's **load address** (from the report's Binary Images section); the trailing addresses are the frames.
- In LLDB on a live/attached process, `image lookup --address 0x…` does the same without a dSYM lookup.
- Full symbolication of a `.crash` / `.ips`: `symbolicatecrash <file>` (bundled in Xcode; needs the dSYM on the Spotlight path and `DEVELOPER_DIR` set), or LLDB's crashlog command — `(lldb) command script import lldb.macosx.crashlog` then `crashlog <file>`.
- `.ips` JSON crash logs from `metrickit` / TestFlight symbolicate the same way — see `metrickit` for capturing them in the field.
- **Keep every Release dSYM** (upload with the build). Without the exact-UUID dSYM, addresses are unrecoverable.

<a id="build"></a>
## Build-failure triage

- Read the **first** error, not the last — later errors are usually fallout. In Xcode's Issue navigator, expand the failing task's full transcript (or build with `xcodebuild ... | xcbeautify`).
- **Swift type-check timeouts / "unable to type-check in reasonable time":** break up large literal expressions and add explicit types; it's a solver blow-up, not a real error.
- **Linker `Undefined symbol`:** missing source in target membership, a framework not linked, or a `#if`-excluded symbol. `Duplicate symbol` = same symbol in two objects (category/extension clash, a `.m` compiled twice).
- **Module / `No such module`:** stale derived data or an unbuilt dependency — build the dependency scheme first; for SwiftPM resolve packages (`swift package resolve`), for a KMP-produced framework rebuild the XCFramework (see `kmp-ios-integration`).
- **Code signing / provisioning:** read the exact message; check team, bundle id, entitlements vs. the profile's capabilities. Reproduce headlessly with `xcodebuild -showBuildSettings` and `-scheme … build`.
- **Sandbox/`Command PhaseScriptExecution failed`:** a Run Script phase failed — run its script manually with the same env; check `SRCROOT`, input/output file lists, `ENABLE_USER_SCRIPT_SANDBOXING`.
- Nuke stale state as a last resort: **clean build folder (⇧⌘K)** / delete `~/Library/Developer/Xcode/DerivedData` — but only after you've read the actual error; it hides more than it fixes.

<a id="checklist"></a>
## Correctness checklist

- [ ] Timing/memory measured on a **real device**, **Release** build — never Simulator or `-Onone` for perf numbers.
- [ ] Bug **reproduced** and the region **signposted** before profiling — you measure a known window, not a guess.
- [ ] `v`/`frame variable` used (not `po`) when you must not run code / trust side-effect-free reads; `expression` reserved for deliberate mutation.
- [ ] Watchpoint used to find the mutator of a property, then `bt` at the trip.
- [ ] Memory Graph run **after** exercising the flow, with **MallocStackLogging (Live Allocations)** on to get allocation backtraces — and turned back **off** afterward.
- [ ] Retain cycles fixed at the weakest edge (`weak`/`unowned`, `[weak self]`), not by nilling things manually.
- [ ] Time Profiler read with **Invert Call Tree + Hide System Libraries**; Allocations read via **generations** around a complete action.
- [ ] Signpost interval/event names are **string literals**; dynamic data in `os_log` args with `privacy: .public`; each concurrent op gets its own `makeSignpostID()`.
- [ ] **No PII / PAN / tokens / balances in signpost or log arguments** unless explicitly `.public` and safe — default-redacted is the safe default for a fintech app (see `swift-security`).
- [ ] `beginInterval` state is captured and passed to `endInterval` (ideally via `defer`).
- [ ] CI profiling via `xctrace record`/`export`; the exact-UUID **dSYM archived** for every Release so crashes symbolicate.
- [ ] Build failures triaged from the **first** error; DerivedData wipe only after reading it.
- [ ] Production regressions of these same signals watched via `metrickit`; SwiftUI `.trace` deep-dives handed to `swiftui-expert-skill`.
