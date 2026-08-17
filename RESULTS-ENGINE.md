# Results: the ladder on a real engine

Everything in [RESULTS.md](RESULTS.md) was measured on synthetic harnesses or simulated on
real distributions. This is the first time the DESIGN.md §2 ladder runs on an actual browser
engine — WebKit, via `WKWebView`, in [`kestrel/`](kestrel/).

**Headline: the mechanism works. It restores in 82 ms, holds any budget that clears the engine's
COLD floor, and at 800 MB destroys *zero* tabs where discard-LRU destroys 5.**

But the simulated 7.9–11.5× does not survive: on a real engine the reduction is 1.4–2.6×
depending on how tight the budget is, and zero state loss is conditional rather than
unconditional. Both gaps trace to a single modelling error — the simulation priced a hibernated
tab at 32 KB, and WebKit charges **39 MB**, because the renderer process cannot be terminated on
request. That one number sets a floor:

```
budget must exceed  (live working set) + (COLD floor x parked tabs)
```

Above that floor the design does exactly what it claims. Below it, it degrades toward
discard-LRU — the correct failure mode, but not a good one.

Environment: M1 Max, macOS 15.5, Swift 6.1.2, system WebKit. Probe page is synthetic
(20 000 DOM nodes plus a retained JS array — chosen so every tab is identical and the rungs
are comparable); the benchmark below uses real sites.

---

## What works

**Per-tab processes are real and individually measurable.** Each `WKWebView` gets its own
WebContent process. `WKWebView` exposes no pid, so tabs are created one at a time and the new
pid is attributed by set-diffing `ps` output. Four tabs, four processes, **130.0 MB each** —
identical to the decimal, which is what you want from a control.

This matters because DESIGN.md §2 specifies `bytes_recoverable` must be *measured, not
estimated*. It can be.

**`WKWebView.interactionState` is the COLD session image, and it already ships.** It
serialises scroll position, form state and the back/forward list into a blob — **138 bytes**
for the probe page — that restores into a fresh web view. This is the single luckiest fact in
the project: the design's most speculative component turned out to be a public API.

**Restore is fast.** COLD → LIVE, timed to `didFinish` rather than to the API returning:

| | measured |
|---|---|
| COLD → LIVE (probe page, no network) | **82 ms** |
| STUB → LIVE (real sites, full network load) | 127–146 ms |

The design's target was "< 100 ms, no network" for a cooperating page. 82 ms clears it.

---

## What the ladder actually costs

One tab driven through every rung, same process, measured with `phys_footprint`:

| rung | measured | % of LIVE | recovered | design target |
|---|---|---|---|---|
| **LIVE** | 128 MB | 100% | — | < 25 MB |
| **WARM** | 106 MB | **83%** | 17% | < 2 MB |
| **COLD** | 39 MB | **30%** | 70% | ~2 KB |
| **STUB** | 59 MB | 46% | — | ~2 KB |

Three findings, in order of how badly they hurt.

### WARM barely does anything (17% recovered)

WARM here is everything a host application is permitted to do to a page short of destroying
it: detach from the view hierarchy, `setAllMediaPlaybackSuspended(true)`, clear every timer and
interval. That buys **17%**.

The reason is structural: **a host app cannot compact WebKit's heap.** The design's WARM
depends on a full compacting GC followed by `madvise` — B1 already showed compaction is the
step that actually returns pages to the OS — and there is no API for it. WARM as specified is
an *engine-internal* operation being attempted from outside, and it doesn't work.

This lands outside the range the simulation swept. `warm_frac` was swept from 0.02 to 0.50;
**reality is 0.83, worse than the most pessimistic case tested.** The saving grace is what that
sweep found: freeze quality buys latency, not memory — a 25× swing in `warm_frac` moved mean
memory by 8%. So a bad WARM is survivable, which is exactly why the roadmap says ship a crude
one. It is still a real correction, and DESIGN.md §2's "< 2 MB per warm tab" is unreachable
without engine changes.

### COLD leaves a 39 MB process baseline that nothing can reclaim

COLD is `interactionState` captured, then the page navigated to `about:blank`. That recovers
70% — good — and leaves **39 MB** of WebContent process behind.

**WebKit will not release that process on demand.** Tested and confirmed:

- releasing the last reference to the `WKWebView`: process alive after **110 seconds**
- giving each tab its own `WKProcessPool` so the pool dies with the view: no effect
- navigating to `about:blank` *and* releasing the view: **59 MB, still alive** — worse than
  navigating away and keeping the view, which is why `Tab.makeCold()` does the latter

This is WebKit's WebProcessCache doing its job — it keeps processes warm for reuse — but it
means COLD's floor on this platform is a whole process, not the ~2 KB descriptor in §2.
At 80 tabs that is a **3.1 GB floor**, which would defeat the entire budget.

Two caveats, both unresolved: the process cache is bounded and evicts under memory pressure, so
the floor at scale may be far lower than 39 MB × N — untested here, and worth testing before
anyone believes the 3.1 GB figure. And private WebKit SPI (`_WKProcessPoolConfiguration
.usesWebProcessCache`) would likely make teardown deterministic, at the cost of leaving
supported API.

### STUB is worse than COLD

Destroying the web view measured **59 MB** against COLD's 39 MB. The demotion ladder is
therefore not monotonic on this engine below COLD, which is why `Scheduler.recoverableBytes`
treats COLD as the effective floor and the fail-safe from RESULTS.md §4 — never demote for a
trivial gain — does real work here rather than being a theoretical nicety.

---

## A null result worth keeping

The first three-policy run on real sites produced nothing:

```
none        mean 197.8 MB  peak 320.0 MB  over budget 0%  demotions 0
discardlru  mean 182.3 MB  peak 278.0 MB  over budget 0%  demotions 0
kestrel     mean 181.0 MB  peak 274.0 MB  over budget 0%  demotions 0
```

Identical, because the budget was 400 MB and the peak was 320 MB — no policy ever had anything
to do. Two causes, both methodological:

1. **The budget was never reached.** A scheduler comparison with no pressure compares nothing.
2. **The trace never opened most of the tabs.** A pure Zipf-over-LRU-stack revisit model — the
   same one the simulation used — concentrates so hard on recently-used tabs that with 10 tabs
   and 40 events only 9 were ever loaded. In the simulation this was masked because tabs were
   *created* by the trace as it ran; replaying the same model against a fixed tab set is not
   the same experiment.

Fixed by opening each tab once before revisiting (as a user filling a window does) and lowering
the budget until it binds. Recorded here because the failure mode is easy to miss: three
identical rows look like "the policies are equivalent" rather than "the experiment didn't run."

## End-to-end: three policies, real engine

40 events, budget binding, one policy per process. Two URL sets, chosen to vary the one thing
the diagnosis says matters — how much a tab compresses from LIVE to COLD.

**Light pages** (10 real sites: Wikipedia, MDN, HN, go.dev…), 150 MB budget:

| policy | mean | peak | over budget | state lost |
|---|---|---|---|---|
| none | 319.9 MB | 368.6 MB | 88% | 0 |
| discard-LRU | **104.6 MB** | 140 MB | 0% | 17 |
| Kestrel | 121.7 MB | 144 MB | 0% | 14 |

**Heavy pages** (20 000-node DOM + retained JS heap), 500 MB budget:

| policy | mean | peak | over budget | state lost |
|---|---|---|---|---|
| none | 983.7 MB | 1111 MB | 90% | 0 |
| discard-LRU | 420.0 MB | 452 MB | 0% | 12 |
| **Kestrel** | **411.5 MB** | 482 MB | 0% | **7** |

**The simulation's headline does not survive.** It claimed 7.9–11.5× less memory than unmanaged
with *zero* state-losing reloads. The engine appeared to give **2.4–2.6×** — a figure the
correction at the end of this file retracts entirely: re-measured, this run is 1.35× *worse*
than unmanaged. State losses are reduced by
18–42% rather than eliminated.

### Why, precisely

The warm-up ramp gives per-tab LIVE cost on the real sites: 37, 50, 32, 24, 5, 17, 111, 31, 22,
40 MB — mean 37 MB, median 31 MB. The measured COLD floor is **39 MB**.

> On the light set, **COLD costs more than a typical LIVE tab.** Compression ratio 0.95×. Seven
> of ten tabs are cheaper live than cold.

So the ladder had nowhere to put anything: Kestrel parked **zero** tabs at COLD in that run — the
rung appears not once in the trace — and went straight to STUB, which is what discard-LRU already
does. It matched LRU on state loss and lost on memory.

On the heavy set the compression ratio is **3.28×** (128 MB live, 39 MB cold), and the ladder
behaves as designed: same memory as LRU with **42% fewer destroyed tabs**. The advantage tracks
the compression ratio exactly as the diagnosis predicted, which is the one piece of evidence here
that the mechanism is understood rather than merely observed.

**The root cause is a single modelling error.** The simulation put COLD at 32 KB — a descriptor
plus a thumbnail. The engine charges **39 MB**, because the WebContent process survives and
cannot be terminated on request. Three orders of magnitude, and every downstream claim rested on
it. The corollary is a budget feasibility rule the simulation never surfaced:

```
budget must exceed  (live working set) + (COLD floor x number of parked tabs)
```

At 10 heavy tabs that is roughly 384 MB of protected live set plus 273 MB of COLD — 657 MB
against a 500 MB budget, which is exactly why 7 tabs still had to be destroyed. Raise the budget
above that floor and the ladder should reach zero state loss; below it, no policy can.

### Testing the feasibility rule

The rule predicted that raising the budget above the COLD floor would give the ladder room and
take state loss to zero. For 10 heavy tabs: ~4 protected live tabs × 128 MB + 6 parked × 39 MB
≈ 746 MB, so 800 MB should suffice. Rerun at 800 MB:

| policy | mean | peak | over budget | state lost |
|---|---|---|---|---|
| none | 968.2 MB | 1111 MB | **82%** | 0 |
| discard-LRU | 668.5 MB | 765 MB | 0% | **5** |
| **Kestrel** | 678.8 MB | 787 MB | **0%** | **0** |

**Confirmed.** Kestrel destroys nothing while discard-LRU still discards 5 tabs at the same
budget, for 1.5% more memory. State loss across all three engine runs tracks the rule exactly:

| run | budget | headroom vs COLD floor | LRU discards | Kestrel discards |
|---|---|---|---|---|
| light pages | 150 MB | far below | 17 | 14 |
| heavy pages | 500 MB | below | 12 | 7 |
| heavy pages | 800 MB | **above** | 5 | **0** |

This is the design working as specified, and it identifies the operating condition precisely:
**the ladder delivers its promise — hold a budget without destroying user state — only when the
budget clears the floor set by the engine's per-tab COLD cost.** Below that floor it degrades
toward discard-LRU, which is the correct failure mode but not a good one.

Note what the 800 MB run does *not* show: a large memory reduction. It is 1.43× below unmanaged,
against 2.4× at the tighter 500 MB budget. That is not a regression — the budget is the control
input, and a looser budget buys less reduction by construction. What the ladder buys is not a
number, it is the ability to *hit whatever budget you set* without shredding tabs: 0% over budget
against unmanaged's 82%, with zero discards.

### What still holds

- **Kestrel never exceeded budget** on either set, while unmanaged sat over it 88–90% of the time.
- **It is strictly better than discard-LRU on the axis it was designed for** — fewer destroyed
  tabs at equal or better memory — on the workload where the ladder has room.
- **The 82 ms restore is real**, and p95 restore latency was *lower* for Kestrel than for
  discard-LRU on both sets (397 ms vs 400 ms; 3541 ms vs 3546 ms), because restoring from COLD
  beats reloading from network.

## The instrumentation cost more than the thing it measured

Worth recording because it is the same mistake as §1, in a new place.

The browser sampled each tab's memory by shelling out to `/usr/bin/footprint`. That call
costs **226 ms**. `Tab.currentBytes` ran it on *every read* — and the scheduler's budget
loop, the status bar, and every row of the tab strip all read it, about eight times per
1.5-second UI tick. Roughly **1.8 s of main-thread blocking per 1.5 s of wall clock.**

It did not look like a hang, because WebKit composites pages in their own process: the
page kept scrolling, just badly. A screen recording put a number on it — during a
10-second scroll, **25% of frames were pixel-identical to their predecessor**. One frame
in four, dropped.

Sampling now runs on a background queue and the UI reads only a cache: 1000 reads in
**0.13 ms**, with a regression test asserting reads stay free.

The lesson generalises past this bug. §1 found that tier-down optimised `about:memory`
while returning nothing to the OS — the wrong number, measured well. This is the mirror
image: **the act of measuring was itself the largest cost in the system.** A memory
manager that stalls the UI to find out how much memory it is using has spent more than it
can save. Anything sampled per-frame or per-tick has to be cheap enough to be free, or it
becomes the problem it was added to observe.

## What this means for the design

**Confirmed on a real engine:** measured per-tab attribution, a shipping session-image API, and
sub-100 ms restore. The three things the ladder needs to exist.

**Corrected:**

1. **§2's WARM target (< 2 MB) is not achievable from outside the engine.** Restate it as an
   engine-internal operation, or drop WARM to a display-level state and treat COLD as the first
   real rung.
2. **§8's COLD target (~2 KB resident) is wrong on WebKit** by four orders of magnitude, because
   the process survives. The target is only reachable in an engine that will terminate a
   renderer on request — which is an argument for the fork-server work in §4, from an angle the
   design didn't anticipate: cheap process *teardown* matters as much as cheap startup.
3. **The ladder is not monotonic.** STUB costs more than COLD here. Any scheduler needs measured
   rung costs rather than an assumed ordering.

**The honest summary:** the parts of this design that live in the browser's *policy* layer —
the budget, the scoring, the floors, the fail-safe — port to a real engine cleanly and are
implemented in [`kestrel/Sources/kestrel/Scheduler.swift`](kestrel/Sources/kestrel/Scheduler.swift).
The parts that live in the *engine* — heap compaction, cheap frozen tabs, process teardown —
cannot be built on top of an engine that doesn't offer them. That is the sharpest thing this
exercise established, and it was not visible from any amount of simulation.

---

## Correction: the per-tab totals undercounted, and by different amounts per policy

*Added 2026-08-14, after a screen recording showed the browser reporting 52 MB for a page
whose content process held 511 MB.*

Every figure above was a **per-tab attributed sum**: one process id per tab, claimed by
diffing `ps` output around tab creation. Two things are wrong with that. WebKit spawns
several content processes at once and the diff picks one arbitrarily. And a process that no
tab claims — including one left behind when a tab is demoted — is counted as nothing.

The benchmark now records both the attributed sum and the browser's real footprint (every
WebContent process younger than the run, summed, which needs no attribution). Re-run,
heavy pages, 800 MB budget, 40 events:

| policy | attributed | **measured** | tabs accounted for | over budget: attributed → measured |
|---|---|---|---|---|
| none | 975.9 MB | **974.9 MB** | **100%** | 82% → 82% |
| discard-LRU | 547.1 MB | **802.2 MB** | 68% | 2% → **62%** |
| Kestrel | 587.9 MB | **788.1 MB** | 75% | 2% → **48%** |

*Three runs. Kestrel measured 1.28x, 1.28x, 1.24x below unmanaged; discard-LRU 1.21x, 1.20x,
1.22x. The figures above are the last, run end-to-end on a single binary.*

**The 100% row is the important one.** Once `_webProcessIdentifier` replaced pid-diffing,
attribution became exact where it can be: with every tab live and every process owned by a
tab, attributed and measured agree to within 1 MB. So the 25–32% gap under the demoting
policies is **not measurement error** — it is real memory in processes that outlived the tabs
they belonged to. Demoting a tab releases its web view; WebKit keeps the process; nobody owns
that memory.

That splits a question this project could not previously answer:

| | share of the gap |
|---|---|
| mis-attribution | ~0% |
| processes orphaned by demotion | all of it |

**The error is not uniform, and it favours exactly the policies this benchmark exists to
promote.** With no policy, every process belongs to a live tab and attribution captures 96%.
Demote tabs and their processes are released — but WebKit keeps them alive, they stop being
attributed to anything, and the reported number falls while the memory does not. Per-event:

    policy=none     event 12:  attributed 1049   measured 1089   procs 10
    policy=kestrel  event 12:  attributed  428   measured  668   procs 10
    policy=kestrel  event 36:  attributed  749   measured  989   procs 13

This is DEBUGGING.md §2 again — *tier-down improved `about:memory` while returning nothing
to the OS* — at the scale of the whole benchmark, and I did not recognise it until the
numbers were put side by side.

**Corrected headline for this workload:**

| | reduction vs unmanaged |
|---|---|
| discard-LRU | 975 / 802 = **1.22×** |
| Kestrel | 975 / 788 = **1.24×** |

not the ~1.43× the attributed figures gave. **And the "0% over budget" claim does not
survive at all**: measured, Kestrel is over budget in 48% of samples and discard-LRU in 62%.
The scheduler was demoting until its *own accounting* said it was under budget, which is not
the same as being under budget.

**What survives, and is now on firmer ground than before:** Kestrel holds less real memory
than discard-LRU (788 MB against 802 MB) *while destroying fewer tabs* (6 against 8) and
spending far less time over budget (48% against 62%). On the
attributed numbers it looked marginally worse on memory and better only on state loss. The
comparative case for the ladder is stronger than the old figures suggested; the absolute
case is weaker.

### The per-rung costs were right

Re-measured with the web view naming its own process, six tabs, same synthetic page:

    LIVE    128.0 MB
    WARM    106.0 MB   (83% of live)
    COLD     39.0 MB   (30% of live)
    restore COLD -> LIVE: 87 ms

Identical to the published figures, to the decimal. Two warnings the re-measure was watching
for did not fire: the pid diff was never ambiguous (one tab at a time, 3.5 s apart, exactly
one WebContent process each), and navigating to `about:blank` did **not** move the page to a
different process -- which was the way the 39 MB COLD figure could have been some abandoned
process's footprint rather than the parked tab's. The feasibility floor built on 39 MB stands
unchanged.

This is worth stating plainly because the rest of this correction is bad news: the ladder's
own physics were measured correctly all along. What was wrong was the claim about what the
ladder does to a browser.

### The light-pages run: the ladder made memory worse

The same re-measurement applied to light pages inverts the published result. 11 mixed-weight
real sites, 150 MB budget, 40 events:

| policy | published (attributed) | **measured** | vs unmanaged | over budget | tabs destroyed |
|---|---|---|---|---|---|
| none | 319.9 MB | **255.3 MB** | -- | 85% | 0 |
| discard-LRU | 104.6 MB | **414.8 MB** | **1.62x worse** | 90% | 19 |
| Kestrel | 121.7 MB | **345.9 MB** | **1.35x worse** | 85% | 15 |

Attribution accounted for 100% of the unmanaged run and only **25%** and **36%** of the
managed ones. The policies were reporting roughly a quarter of what they actually held, and
the error was largest exactly where the design looked best.

**This is not a new failure mode -- it is this design's own predicted one, finally measured.**
The feasibility rule in DESIGN.md states `budget > live working set + (39 MB x parked tabs)`.
Eleven tabs at a 39 MB COLD floor need **429 MB** before a single page is displayed; this run
was given **150 MB**, 2.9x below its own floor. The budget was unreachable by construction,
and the scheduler says so in the logs: `gave_up` fires 5 times for discard-LRU and 7 times for
Kestrel.

What DESIGN.md predicted below the floor was *degradation toward discard-LRU*. What actually
happens is worse: **degradation below doing nothing.** A demotion leaves the old WebContent
process alive; the restore spawns another; 45 demotions and 18 restores over 40 events churn
processes faster than WebKit reclaims them. Measured peak reached 530 MB for Kestrel and
650 MB for discard-LRU, against 309 MB for the run that managed nothing at all -- on the
workload whose whole point was that the pages were light.

**The honest summary of the engine work is therefore workload-dependent, and one side of it
is negative:**

| workload | budget vs. floor | Kestrel vs unmanaged |
|---|---|---|
| heavy pages, 800 MB budget | above the floor | **1.24x better** |
| light pages, 150 MB budget | 2.9x below the floor | **1.35x worse** |

The ladder helps when the budget is reachable and hurts when it is not, because below the
floor the process churn costs more than the parked pages save. The old numbers hid this
completely: they reported 2.6x better on precisely the run where the design was 1.35x worse.

The correct fix is not a scheduler tweak. A browser that cannot meet its budget should refuse
the budget -- surface the floor, name the number of tabs it can hold, and stop demoting --
rather than thrash against a target it can prove is unreachable. That is not implemented; it
is recorded in BROKEN.md.
