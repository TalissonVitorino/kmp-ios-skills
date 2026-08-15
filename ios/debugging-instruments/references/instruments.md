# Instruments & xctrace — deep reference

Companion to `debugging-instruments`. Profile a **Release** build on a **real device**.

## Time Profiler / CPU Profiler

- Sampling profiler: periodically captures every thread's backtrace. Weight in the call tree = sample count ≈ wall time on that thread, **not** a precise timer.
- Read it via the Call Tree display + the bottom **Call Tree** filter popover:
  - **Invert Call Tree** — leaf (deepest) frames float to the top, so the actually-hot functions surface instead of `main`.
  - **Hide System Libraries** — collapse Apple frames to see *your* code's cost.
  - **Separate by Thread** — keep the main thread distinct; UI stalls live there.
  - **Flatten Recursion**, **Top Functions** for aggregation.
- Pin ranges: option-drag a time range in the track to scope the call tree to a moment (e.g. one tap → response).
- The Time Profiler template also carries **Hangs** and **Thread State Trace**: red hang spans on the track mark main-thread blocks (> ~250 ms). Click a span → its backtrace is your culprit.
- CPU Profiler samples at a higher rate for tight compute loops; otherwise identical reading model.

## Allocations & leaks

- **Allocations** tracks every heap allocation; columns: Persistent (still alive), Transient (freed), Total.
- **Generations workflow** (the reliable leak/abandonment finder):
  1. Let the app settle to baseline.
  2. **Mark Generation**.
  3. Perform one complete, self-reversing action (present → dismiss a screen).
  4. **Mark Generation** again after it returns to baseline.
  5. Inspect the generation delta — anything still Persistent after teardown is abandoned/leaked. Expand to the allocation backtrace (needs MallocStackLogging).
- **Leaks** instrument detects unreachable memory (true leaks incl. retain cycles) on a timer; run alongside Allocations. Green check = none found in the last scan.
- **VM Tracker** (add manually) shows virtual-memory regions — large dirty/anonymous growth that isn't malloc heap (image decoding, Metal, caches).
- Cycle vs. abandonment: Leaks/Memory-Graph catch *cycles*; Allocations generations catch *reachable-but-unbounded* growth (a cache with no eviction). Different fixes.

## Animation Hitches

- A **hitch** = a frame that misses its presentation deadline. Metric: **hitch time ratio** (ms of hitch per second of animation) — Apple's guidance is to keep it low; users perceive hitches, not average FPS.
- Two causes: **commit** hitches (too much work on the main/render thread before commit) and **render** hitches (GPU can't finish in time). The track labels which.
- Record Animation Hitches **with Time Profiler** in one session: when a hitch appears, scope the Time Profiler call tree to that frame to see what ran long.

## Energy Log

- Instruments captures **Energy Impact** plus CPU, GPU, Network, Location, and Display contributors. High impact = sustained CPU, frequent wake-ups, or radio/GPS activity.
- Correlate spikes with the Network and Location tracks; a common fintech drain is polling or a never-cancelled location request.
- For field energy data (real users), use `metrickit`'s `MXCPUMetric` / cellular / GPU metrics instead — Instruments is the local reproduction.

## Network

- **HTTP Traffic** lists requests with timing, sizes, and reuse; **Connections** shows TCP/TLS setup. Look for: duplicate requests, no connection reuse (repeated TLS handshakes), oversized payloads, serial requests that could parallelize.
- Pair with signposts around your networking layer to attribute requests to a user action.

## SwiftUI instrument

- Lanes: **View Body** (how many bodies evaluated + cost), **View Properties**, **Core Animation Commits**, **Time Profiler**.
- The signal to chase: unexpectedly high View Body counts = over-invalidation (a too-broad `@Observable`/state dependency re-rendering a subtree).
- Deep interpretation, the Python `.trace` export scripts, and fixes belong to `swiftui-expert-skill` — hand off the recorded `.trace`.

## xctrace export — parsing in CI

```bash
# 1. See what's exportable
xcrun xctrace export --input run.trace --toc > toc.xml

# 2. Pull a specific table by XPath against the TOC schema
xcrun xctrace export --input run.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
  > timeprofile.xml

# Common schemas: time-profile, allocations-statistics, leaks,
# os-signpost-interval, core-animation-fps-estimate
```

- The TOC (`--toc`) is XML describing every run and table; read it first to find the exact `schema` attribute, then query it with `--xpath`.
- CI gate example: export the leaks/allocations table, parse counts/bytes with a script, fail if over threshold. Keep the `.trace` as a build artifact for a human to open in Instruments.app on failure.
- `xctrace record` flags recap: `--template`, `--device`, `--attach <pid|name>` xor `--launch -- <binary> [args]`, `--time-limit 30s`, `--output x.trace`, `--append-run`, `--all-processes`, `--target-stdout -`.

## Custom instruments

- You can ship a `.instrdst` Instruments Package that turns your signpost schema into a bespoke lane (e.g. a "Checkout Funnel" instrument). Overkill for most apps — Points of Interest + a custom `category` covers the common case.
