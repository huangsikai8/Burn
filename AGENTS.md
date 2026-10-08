# Burn

A native macOS replacement for Activity Monitor. Every process is grouped under the app
that owns it, and a sidebar explains what to close, what is stuck, what macOS itself is
doing, and why. The bar is set by Activity Monitor: every figure it shows must be matched,
and anything grouped must add up more completely than its process list does.

## Build and run

```bash
./build.sh && open build/Burn.app      # always rebuild AND relaunch after a change
```

`build.sh` stops the running copy (SIGTERM; the app flushes the minute of history in
progress), assembles the bundle, draws the icon if `Resources/AppIcon.icns` is missing, and
signs with the `WindowDeck Dev` identity so the Accessibility grant survives rebuilds.

Text dump of one sample, for checking figures against `top` without the UI:

```bash
BURN_DUMP=1 BURN_DUMP_SECONDS=4 BURN_DUMP_PROCESSES=1 .build/debug/Burn
```

It prints Σ group CPU, Σ member CPU and whole-system CPU side by side. Coalition totals
should cover ~90% of system CPU; member sums alone cover ~60%.

`BURN_STATE_DIR` points history somewhere other than `~/Library/Application Support/Burn`.

## Layout

| Path | Role |
| --- | --- |
| `Sources/CProc` | C declarations for coalition ids/usage, responsible pid, interface totals |
| `Sampling/ProcessSampler` | kinfo list, per-process rusage v6, coalition counters |
| `Sampling/SystemSampler` | CPU ticks, VM stats, swap, pressure, disk, network, battery, GPU |
| `Sampling/ForeignProcessMemory` | memory of root/other-user processes via `ps` (30 s) and `top` (5 min) |
| `Sampling/AppCensus` | NSWorkspace apps, window counts, persisted last-active / hidden-since |
| `Model/SnapshotBuilder` | raw counters → `AppGroup`s with rates |
| `Model/Monitor` | timer (2 s visible, 10 s background), in-memory hour of per-app points |
| `Insights/InsightEngine` | close suggestions, hidden-busy, runaways, leaks, busy services, what changed |
| `Insights/ServiceKnowledge` | plain-English notes for common macOS services and which signals explain them |
| `History/HistoryStore` | SQLite: per-minute rows 48 h, 15-min rows 30 days, battery ledger |
| `Actions/AppActions` | quit, force quit (unsaved check), signals with admin fallback, sample, lsof |
| `UI/*` | table, footer, insights sidebar, detail panel, menu bar popover, settings |

## Measured facts (macOS 26.5, M5) — don't re-derive

- **Group by resource coalition.** Every process has one (`proc_pidinfo` flavor 20), root
  included. Jetsam coalitions mix unrelated apps (Safari WebContent with Finder QuickLook).
- **Coalition totals include exited members.** Chrome's coalition had started 40k processes.
  Group CPU/energy/disk come from coalition deltas, not member sums.
- `struct coalition_resource_usage` field order was verified against live sums; see `CProc.h`.
- **Mach time units:** rusage and coalition CPU times are ×125/3 ns. A `yes` loop reads 99.3%.
- **Energy Impact** = 100 × (cpu s, background QoS ×0.8 + 0.0002 × *package idle* wakeups +
  disk bytes × weights) per second, weights from `/usr/share/pmenergy/default.plist`.
  Adding interrupt wakeups overstated drivers by up to 34 against `top`'s POWER column.
- `ri_energy_nj` is real CPU energy; watts per app come from it. Efficiency-core work can
  be 17% CPU at 0.04 W, which is why it's a better battery figure than Energy Impact.
- **Other users' processes:** libproc refuses rusage, taskinfo and bsdinfo; kinfo sysctl,
  `proc_pidpath` and coalition ids still work. `ps` is setuid and costs ~10 ms; `top` costs
  ~1.5 s CPU per pass regardless of filters; `nettop` burns ~120% CPU continuously, so there
  is no per-app network column yet.
- **Coalition "billed to me / to others" can't attribute WindowServer load to apps** — a
  coalition's billed-to-me equalled its own CPU. Busy-service causes are therefore measured
  correlates (on-screen windows with CPU/GPU, audio assertions, spawn rate, swap, thermal),
  labelled "likely causes".
- **Unsaved documents:** the window close button's `AXEdited` attribute. Works for AppKit
  and Electron. `AXIsEdited` on the window does not exist.
- `kern.num_tasks` / `kern.num_threads` are limits; live counts come from
  `processor_set_statistics(PROCESSOR_SET_LOAD_INFO)`.
- Burn's own overhead with the window open was 9% before throttling `ps` and caching static
  NSRunningApplication fields, 4.3% after. SwiftUI table updates are most of what remains.

## Rules

- Never quit anything automatically. Suggestions and alerts explain; the person decides.
- Normal Quit uses `NSRunningApplication.terminate()` so apps still ask about unsaved work.
- Don't describe a service in `ServiceKnowledge` unless its role is well established.
- Persisted state (last-active, hidden-since, ignored apps, history) must survive rebuilds.
