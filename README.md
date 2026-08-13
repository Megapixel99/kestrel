# Kestrel

A browser whose memory scales with what you're looking at rather than what you have open:
a design, a measurement harness that tests it, and a working macOS browser that implements
it on WebKit.

- **[DESIGN.md](DESIGN.md)** — the architecture. Annotated with measured results where the
  data contradicted the original claims.
- **[RESULTS.md](RESULTS.md)** — what happened when items 1–4 were built and measured, and
  the revised roadmap.
- **[RESULTS-ENGINE.md](RESULTS-ENGINE.md)** — what happened when the ladder was built on a
  real engine (WebKit), and which of the design's targets turned out to be unreachable from
  outside it.
- **[kestrel/](kestrel/)** — the browser itself: ~5,500 lines of Swift, the tab ladder, the
  scheduler, **real Firefox add-ons**, developer tools, and eight headless test and
  benchmark modes. It used to be ~10,000 lines, half of it imitations of extensions —
  an ad blocker, dark mode, userscripts, a password manager, a screenshot tool. Once
  WebKit's extension runtime made the real add-ons work, the imitations were deleted.
- **[DEBUGGING.md](DEBUGGING.md)** — the implementation bugs that looked correct while
  being broken, including two I could not fix and said so.
- **[BROKEN.md](BROKEN.md)** — what is still broken, what has already been ruled out for
  each, and where to start. Written so picking one up does not mean repeating the
  elimination work.
- **[BENCHMARKS.md](BENCHMARKS.md)** — every comparison in one place, regenerated from
  the data by `bench/compare.py` rather than transcribed.

**Short version:** in simulation the thesis looked strong — 8.9× less memory on a realistic tab
distribution, with almost all of the win from one item (the tab scheduler), one item overrated
(JIT tier-down), and the mechanism that makes the others real (heap compaction) missing from the
list entirely.

**Then it was built on a real engine.** The memory headline shrank to 1.4–2.6×, because the
simulation priced a hibernated tab at 32 KB and WebKit charges 39 MB — a renderer process cannot
be terminated on request. That sets a floor: `budget > live working set + (39 MB x parked tabs)`.

**Above that floor the design does what it promised**: at a 800 MB budget over 10 heavy tabs it
holds the bound with **zero destroyed tabs**, where discard-LRU destroys 5 for 1.5% less memory.
Below the floor it degrades toward discard-LRU. Its advantage also scales with how much a tab
compresses from live to cold — 3.28× for heavy pages, 0.95× for light ones, and at 0.95× there is
nowhere to put anything. See [RESULTS-ENGINE.md](RESULTS-ENGINE.md).

Checking the design against shipping browsers afterwards narrowed it further: Firefox has
discarded background-tab images since v4, already has an mmap'd cross-process bytecode cache
(`ScriptPreloader`) that simply doesn't cover web content, and has shipped tab unloading since
v93 — but pressure-triggered and two-state, which is exactly the baseline the scheduler
benchmark beats. Only the budget-driven ladder is genuinely new.

**Firefox add-ons run, and they are not free.** An `.xpi` is a WebExtension, and WebKit has
shipped its own WebExtensions runtime since macOS 15.4 — so Kestrel loads add-ons rather
than reimplementing them. All 25 installed in the development machine's Firefox profiles
load. They also answer a question the browser comparison could not: the eight add-ons in the
active profile add **244 MB** to a 50 MB browser. That is memory the ladder cannot touch,
because a background page belongs to no tab — which retires the "Firefox had more
extensions" confound by measuring it instead of naming it.

Adding per-tab memory limits closed the last gap — a 512 MB cap with a 3 GB budget holds the
bound 100% of the time with zero breakage — and reframed everything else: **items 1–4 are not
primarily memory savers, they are what lets a page survive being capped**, which is what makes
the budget enforceable. (That reframing stands; the 8.9–10.9× attached to it is a simulated
figure, superseded by the engine measurements.)

## Running the benchmarks

Requires Node 20+, Python 3.10+ with Pillow, and macOS for the memory tooling (`footprint`,
`vm_stat`) in B3. B1/B2/B4 are portable apart from page-size constants.

```bash
cd bench/b1_jit_tierdown && python3 run.py && python3 tierup_sensitivity.py
```

```bash
cd bench/b2_image_cache && python3 decode_vs_hold.py
```

```bash
cd bench/b3_bytecode_cache && node gen_cache.js && python3 run.py
```

```bash
cd bench/b4_scheduler && python3 evaluate.py
```

B4 takes env vars: `RSS_FILE` picks the tab-size distribution, `BUDGET_GB` sets the global
budget, `N_TABS` / `N_EVENTS` / `ZIPF_ALPHA` shape the trace. The per-tab cap and break-ratio
sweeps run automatically and take a few minutes.

Five distributions, all sampled from real browsers running on the test machine. The last two
are a **controlled pair** — the same 11 pages loaded side by side in both browsers:

| file | source | procs | median | max |
|---|---|---|---|---|
| `chrome_renderer_rss_mb.txt` | Chrome, `ps` sample | 17 | 137 MB | 717 MB |
| `firefox_content_rss_mb.txt` | Firefox, 16 tabs | 17 | 174 MB | 1005 MB |
| `chrome2_renderer_rss_mb.txt` | Chrome, 11 tabs (3 live Meet calls) | 25 | 146 MB | 723 MB |
| `firefox_matched_rss_mb.txt` | **Firefox, 11 matched tabs** | 11 | 236 MB | 923 MB |
| `chrome_matched_rss_mb.txt` | **Chrome, same 11 tabs** | 26 | 110 MB | 584 MB |

Medians are over every entry in each file. RESULTS.md quotes 262 MB for the Firefox
16-tab sample; that is the median of its 14 *isolated* content processes, excluding three
near-empty ones, and is the right figure for the architectural comparison there. The
benchmark bootstraps from all 17, so 174 MB is the right figure here.

*In simulation* the scheduler result holds at **7.9–11.5× less memory with zero state-losing
reloads** across every one of them, and what varies is how much the per-tab cap matters, which
tracks the tail. On a real engine it delivers 2.4–2.6× and reduces rather than eliminates state
loss — see [RESULTS-ENGINE.md](RESULTS-ENGINE.md) for why the simulated figure was optimistic.

```bash
cd bench/b4_scheduler && RSS_FILE=firefox_content_rss_mb.txt BUDGET_GB=3 python3 evaluate.py
```

Raw output lands in `results/`.

## What each benchmark actually measures

| | what it does | real vs modelled |
|---|---|---|
| **B1** `b1_jit_tierdown` | 4000 hot functions in V8, tiered up and then idled, across five code-flushing configurations | fully real — live V8 heap statistics |
| **B2** `b2_image_cache` | real photographs at web sizes and qualities, decoded with libjpeg-turbo | fully real — same decoder family browsers use |
| **B3** `b3_bytecode_cache` | real V8 code caches from shipping production bundles, held by 16 processes as private copies vs one shared mapping | fully real — `vm_stat` / `footprint`, with a no-payload control subtracted |
| **B4** `b4_scheduler` | the scheduler policy itself, evaluated against status-quo and discard-LRU | **policy code is real; the trace is a simulation.** Tab sizes are bootstrapped from the actual Chrome renderer distribution on the test machine |

B4 is the only one that is not a direct measurement. It compares *policies* under a single
cost model, and the two assumptions it is least sure of — freeze quality and revisit locality
— are swept rather than asserted. The headline result is robust across both sweeps.

## Layout

```
DESIGN.md                     architecture, annotated with measured corrections
RESULTS.md                    verdict on items 1-4 (simulation + real distributions)
RESULTS-ENGINE.md             verdict from building it on WebKit
kestrel/                      a working macOS browser: the ladder, the budget, the scheduler
bench/b1_jit_tierdown/        jit_mem.js, run.py, tierup_sensitivity.py
bench/b2_image_cache/         decode_vs_hold.py
bench/b3_bytecode_cache/      gen_cache.js, child.py, run.py
bench/b4_scheduler/           scheduler.py  <- the policy implementation
                              evaluate.py   <- trace generation and comparison
results/                      raw JSON output + five sampled browser RSS distributions
results/engine/               real-engine benchmark runs
DEBUGGING.md                  implementation bugs, including two never fixed
```

## Reproducing everything

```bash
cd bench/b1_jit_tierdown && python3 run.py          # and the other three benches
cd kestrel && ./make_app.sh && open Kestrel.app --args gui
cd kestrel && ./.build/debug/kestrel selftest       # ~40 assertions
cd kestrel && ./run_bench.sh 800 40 urls_heavy.txt  # the real-engine comparison
```

`node_modules/` and `.build/` are not tracked; `npm install` and `swift build` restore
them. Dark Reader is optional — the browser falls back to a CSS invert without it.

`bench/b4_scheduler/scheduler.py` is the one file here that is a proposed *implementation*
rather than a measurement: the four-state ladder, the scoring rule, the per-reason demotion
floors, and the fail-safe that stops the scheduler destroying state to chase an unreachable
budget.
