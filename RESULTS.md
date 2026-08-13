# Results: items 1–4, measured

DESIGN.md §10 ended with a falsifiable claim:

> Steps 1–4 are achievable against Gecko today and should capture a large fraction of
> the total win. If they don't, the thesis is wrong and steps 5–8 shouldn't be funded.

This is what happened when they were built and measured.

**Verdict: the thesis holds, but the credit is distributed almost the opposite of how
the design predicted.** Item 4 is nearly the entire win. Item 1 is close to worthless
on its own, and only pays off via a mechanism that wasn't on the list at all.

Environment: M1 Max, 64 GB, macOS 15.5, Node 24.11 (V8 13.x), Python 3.14 (x86_64 under
Rosetta — noted where it matters). Browsers sampled: **Chrome 150.0.7871.187 (arm64)** and
**Firefox 153.0.3 (aarch64)**, both native, so the per-tab comparison in Addendum A carries no
architecture confound. All raw output in `results/`.

**Baseline for scale, measured on this machine:** the Chrome that was already running
held **4.58 GB across 26 processes**, 17 of them renderers (median 137 MB, mean 215 MB,
max 717 MB). That distribution is the input to item 4 rather than an invented one.

---

## Scoreboard

| # | Item | Predicted | Measured | Already in Gecko? | Verdict |
|---|---|---|---|---|---|
| 1 | JIT tier-down on idle | "self-contained, immediate win" | ~15 MB/tab, and **0 MB of it reaches the OS** without compaction | partly (V8 flushes bytecode by default) | ✗ overrated |
| 2 | Decoded-image eviction | "large win, small patch" | 14–102× amplification, 0.8–51 ms to rebuild | **yes — shipped since Firefox 4** | ⚠ not novel; the *flicker* is the open problem |
| 3 | `mmap`'d shared bytecode cache | "wins scale with tab count" | **49 MB → 0 MB** per process | **mechanism yes, scope no** | ⚠ extend existing code, don't build it |
| 4 | Tab scheduler + WARM | "first user-visible change" | **8.9× less memory, zero state loss** | two-state, pressure-triggered only | ✓✓ carries the design |
| — | *Compaction + decommit* | *not on the list* | **the precondition for #1 mattering** | — | ⚠ promoted |

The "already in Gecko" column is the result of checking the design against shipping browsers
rather than against memory; see [§ Prior art](#prior-art-what-firefox-already-does) below. It
does not invalidate any measurement here, but it sharply narrows what is actually *new*.

---

## 1. JIT tier-down — the design was wrong about the premise

DESIGN.md §5 asserted: *"Every engine tiers up… None tier down."* **That is false.** V8 on
this machine ships three flushing mechanisms:

```
--flush-bytecode            ON   (flushed after --bytecode-old-age=6 GCs)
--flush-baseline-code       OFF
--flush-code-based-on-tab-visibility     exists — flush code when a tab backgrounds
```

So the mechanism is largely built and partly switched off. Measuring 4000 hot functions
(100% confirmed Maglev/Turbofan optimized) going idle for 20 GCs:

| configuration | code warm | code idle | reclaimed | RSS returned |
|---|---|---|---|---|
| naive (no flushing) | 52.7 M | 46.5 M | 12% | 1% |
| **V8 default (today)** | **52.2 M** | **46.5 M** | **11%** | **0%** |
| + flush baseline code | 52.7 M | 46.5 M | 12% | 0% |
| aggressive tier-down | 49.8 M | 31.7 M | 36% | 1% |
| aggressive + compaction | 50.2 M | 31.7 M | 37% | **21%** |

Two findings, and the second is the important one.

**(a) Tiering up makes code memory permanent.** V8 will not flush a function's bytecode
while that function has optimized code attached — the bytecode is needed to deoptimize
back into. So the default policy exempts precisely the hot functions that dominate code
memory. Sweeping warm-up intensity:

| calls/fn | optimized | idle floor |
|---|---|---|
| 20 | 0% | 18.4 M |
| 100 | 0% | 18.4 M |
| 300 | 99% | 46.3 M |
| 1200 | 100% | 46.5 M |

**Tiering up permanently adds 28.2 MB — a 2.5× higher idle floor** that no amount of
idling recovers. Aggressive flushing claws back to 31.7 MB, still well above the 18.4 MB
floor: even `--stress-flush-code` won't fully release optimized code.

**(b) Freeing heap objects returns nothing to the OS.** Look at the RSS column. Every
configuration reclaimed 11–37% of *heap* code memory; all but one returned **0–1%** of it
to the operating system. Freed objects land in fragmented arenas, and a partly-occupied
page cannot be unmapped. Only with `--compact-on-every-full-gc` does RSS actually fall —
by 103.9 MB, 21%.

This reframes item 1 entirely. Tier-down is not a memory optimization; it is an
*enabler* for one. **Compaction and decommit are the actual mechanism, and they were not
on the list of four.** Shipping item 1 alone would have produced a nice `about:memory`
graph and no change in what the OS sees — the exact failure mode of optimizing the
number you measure instead of the number that matters.

## 2. Decoded-image eviction — confirmed, with a caveat about size

Real photographs resampled to web sizes, re-encoded at web quality, decoded with
libjpeg-turbo 3.1.4.1 (the same decoder family browsers use, so these times are directly
comparable rather than a proxy):

| render size | fmt | encoded | decoded RGBA | amplification | decode |
|---|---|---|---|---|---|
| 400×225 thumb | JPEG | 25 K | 0.3 M | 14× | 0.8 ms |
| 800×450 card | JPEG | 86 K | 1.4 M | 16× | 2.7 ms |
| 1600×900 content | JPEG | 266 K | 5.5 M | 21× | 10.2 ms |
| 2560×1440 hero | JPEG | 538 K | 14.1 M | 27× | 23.8 ms |
| 3840×2160 4K | JPEG | 967 K | 31.6 M | 34× | 50.8 ms |
| 3840×2160 4K | AVIF | 318 K | 31.6 M | **102×** | 39.0 ms |

Holding a decoded surface costs 14–102× its source. Evicting buys back 421–812 MB per
second of decode latency you'd owe.

**The caveat the design missed:** eviction is not uniformly free. A 4K image at 50.8 ms
is three dropped frames on scroll-back — a visible hitch, not a free win. The honest
policy is size-dependent: evict small and medium images outright (≤10 ms, absorbable
off-thread), and for large ones retain the **1/8-scale preview**, which costs 506 KB
against 31.6 MB (**64× less**) and lets you paint instantly while the full decode lands
asynchronously. The design proposed the preview; the data says it is mandatory above
roughly the "content" size, not an optimization.

## 3. `mmap`'d shared bytecode cache — confirmed, and it is free

Real V8 code caches generated from shipping production bundles found on this machine
(Kindle's web app, Microsoft Office web runtimes):

| bundle | source | V8 cache | cold compile | with cache |
|---|---|---|---|---|
| appBundle | 1629 K | 197 K | 28.2 ms | 0.1 ms |
| powerpoint | 558 K | 437 K | 14.5 ms | 0.0 ms |
| excel | 890 K | 322 K | 15.5 ms | 0.0 ms |
| **total (7 bundles)** | **5282 K** | **1240 K** | **95 ms** | **~0 ms** |

Then 16 processes each holding a 48 MB cache, with a no-payload control subtracted to
calibrate out interpreter overhead:

| mode | system physical | per-process footprint | per-process RSS |
|---|---|---|---|
| control (no payload) | — | 8 M | 14 M |
| private heap copies | **+415 M** | **+49 M** | +49 M |
| shared `mmap` | ~0 M | **+0 M** | +12 M |

Per-process cost goes from **49 MB to 0 MB**. macOS excludes clean shared file-backed
pages from `phys_footprint` — the accounting its memory-pressure system actually acts on
— so a mapped cache is genuinely free by the measure that decides whether you swap.

Note the RSS column: 49 MB vs 12 MB, while footprint says 49 MB vs 0 MB. **RSS
double-counts shared pages and is the wrong instrument**, which is worth knowing given
that "browser uses N GB" arguments are almost always made in RSS.

The 95 ms → 0 ms compile saving is a second, unplanned dividend: it is a direct
down-payment on the cold-restore latency that item 4 depends on.

## 4. The tab scheduler — this is the design

80 tabs, sizes bootstrapped from the real Chrome renderer distribution, 4000 activation
events, 2 GB budget, 5 seeds, median reported. Simulation on measured inputs — labelled
as such — comparing *policies* under one cost model.

| policy | mean | peak | over budget | restores | p95 | state lost |
|---|---|---|---|---|---|---|
| status quo (no eviction) | 17141 M | 17584 M | 100% | 0 | — | 0 |
| discard-LRU (browsers today) | 3145 M | 5208 M | 97% | 2453 | 1100 ms | **2453** |
| **Kestrel (4-state, scored)** | **1929 M** | 2959 M | **4%** | 1758 | **450 ms** | **0** |

**8.9× less memory than unmanaged, with zero state-losing reloads.**

The comparison against discard-LRU is the sharper result. At the *same budget*, LRU sits
over it **97% of the time** — it cannot reach the target at all. Its only tool is
destructive, so it must skip every tab that would lose work (pinned, audible, unsubmitted
input), and it runs out of legal victims. The tiered ladder isn't merely gentler; it is
**the only one of the two that can hold a budget**, because WARM and COLD are
non-destructive and therefore always available.

### The finding that changes the roadmap

Sweeping `warm_frac` — how much memory a frozen tab still holds, i.e. how good the freeze
implementation is:

| warm_frac | mean memory | janky restores | state lost |
|---|---|---|---|
| 0.02 (design target) | 1885 M | 685 | 0 |
| 0.15 | 1929 M | 1073 | 0 |
| 0.50 (crude freeze) | 2030 M | 1571 | 0 |

**A 25× difference in freeze quality moves mean memory by 8%.** It moves user-visible
jank by 2.3×.

So freeze quality buys *latency*, not *memory*. The memory comes from having a budget and
enforcing it at all. This is the single most useful result here, because it means the
hard engineering (compacting a frozen heap down to 2 MB, `madvise` discipline, hibernation
fidelity) can be deferred: **ship a crude WARM state and you still get essentially the
whole memory win**, then improve freeze quality to buy back smoothness.

Robustness: mean memory stays flat at ~1930 MB across revisit-locality exponents from 0.6
to 2.0, and Kestrel records zero state losses at every setting while LRU ranges from 1236
to 3028. The result is not an artifact of the trace model.

### Two bugs the implementation surfaced

Both were errors in DESIGN.md, found by writing the code:

**The carve-out list was too blunt.** §2 said never demote a tab with unsubmitted input.
Wrong: WARM is a *paused* tab that preserves everything, and COLD serializes form state
into the session image. Only STUB actually discards work. A single "protected" flag made
the 2 GB budget unreachable, because ~16% of tabs pinned themselves permanently LIVE.
Replacing it with a per-reason floor — audible ⇒ LIVE, pinned ⇒ WARM, unsubmitted input
⇒ COLD — is what let the policy reach budget at all.

**The scheduler needed a fail-safe floor.** When the protected live set alone exceeds
budget, the original policy kept demoting COLD → STUB, recovering ~30 KB per tab while
destroying session images and forcing network reloads — chasing a target it could not
reach. Adding "never demote for less than 1 MB of recovery, and give up when the budget
is unreachable" took state losses from 757 to **0** and p95 restore from 1100 ms to
450 ms. Refusing to act is a policy decision, and it has to be written down.

---

## Addendum A: the premise, tested twice — the controlled test supports it

This project started from "Firefox is a memory hog." It was tested twice, and **the second,
controlled test reversed the first.** Both readings are kept here because the reversal is the
useful part.

### A2. Controlled: the same 11 tabs in both browsers

Same machine, same 11 pages (GitHub, KDE Invent, two blank tabs), loaded side by side:

| | Firefox 153.0.3 | Chrome 150 |
|---|---|---|
| Tabs | 11 | 11 |
| Processes | 19 | **34** |
| Total | **6240.7 MB (6.09 GiB)** | **4616.8 MB (4.51 GiB)** |
| **Memory per tab** | **567.3 MB** | **419.7 MB** |
| Content procs per tab | 1.09 | **2.36** |
| Content proc median / mean / max | **499 / 512 / 923 MB** | **110 / 131 / 584 MB** |
| Fixed overhead | 1926 MB (31%) | 1207 MB (26%) |

**With the workload actually matched, Firefox uses 35% more memory than Chrome** — +1624 MB —
and 60% more fixed overhead. The premise this project was built on is supported after all.

The split is roughly even: ~905 MB of the gap is content processes, ~719 MB is fixed overhead
(Firefox's parent process is 669 MB against Chrome's 395 MB, and its single WebExtensions
process is 563 MB, 9% of Firefox's entire footprint on its own).

**The architectural contrast is the interesting part**, and it cuts against part of this design:

> Firefox **consolidates** — 1.09 content processes per tab, median 499 MB each.
> Chrome **fragments** — 2.36 processes per tab, median 110 MB each.
>
> Chrome pays the fixed per-process baseline **2.4× more often and still wins by 35%.**

So at this scale the per-process baseline is *not* the dominant term — what each process
**retains** is. That is a mild argument against prioritising §4's fork-server work (which
attacks the baseline) and in favour of items 1–4 and the scheduler (which attack retention).
It does not eliminate the baseline argument — B3's 49 MB/process is real, and it is worth 2.4×
more in Chrome's architecture — but it does demote it.

**Two confounds I can't rule out from screenshots**, both of which could explain part of the gap:

1. **Extension load may not be matched.** Firefox's WebExtensions process is 563 MB. Chrome
   runs extensions inside renderer processes where they aren't separately visible, so if the
   two profiles carry different extensions, a large slice of the 1624 MB gap is that, not the
   engine.
2. **Chrome's Memory Saver may have already discarded idle tabs**, since it discards
   proactively on a timer (§ Prior art). If so, Chrome looks better here *because it is already
   doing a crude version of what this design proposes* — which would make this a point in
   favour of the thesis rather than a point about engine efficiency.

### A1. Uncontrolled: what the first comparison said, and why it was wrong

The first pair of snapshots — taken before the workloads were matched — pointed the other way:

| | Firefox | Chrome |
|---|---|---|
| Tabs | 16 | 11 |
| Processes | 25 | **34** |
| Total | 7659 MB (7.48 GiB) | 6277 MB (6.13 GiB) |
| Non-content overhead | 26% | 21% |
| Content procs **per tab** | 1.06 | **2.27** |
| **Total memory per tab** | **479 MB** | **571 MB** |
| Content memory per tab | 355 MB | 452 MB |
| Largest single process | 1005 MB | 723 MB |
| Content proc median / mean | 262 / 399 MB | 146 / 199 MB |

On these numbers Chrome cost **19% more per tab** than Firefox, and I wrote that the premise was
unsupported. That conclusion was wrong, and the flaw was visible at the time: the Chrome session
was running **three live Google Meet calls** — WebRTC video, legitimately expensive — against a
Firefox session of GitHub, Bugzilla and Swagger tabs. I flagged it as uncontrolled and drew a
conclusion from it anyway. Matching the workload (A2) moved the result by 54 percentage points
and flipped its sign.

The lesson is worth more than the number: **an explicitly-labelled confound is still a confound.**
Naming it does not license the inference.

One observation from A1 does survive, because it is architectural rather than workload-driven —
Chrome runs ~2.1–2.4× more renderer processes per tab in both samples. That multiplies the fixed
per-process baseline, so B3's 49 MB/process is worth correspondingly more under Chrome's
architecture. But A2 shows this does not decide totals.

**What holds across both readings:** both browsers land in the 420–570 MB per tab range, both
spend a quarter to a third of their memory before rendering anything, and neither treats total
footprint as a bound. That last point is the actual finding, and it is what §2 addresses.

---

## Addendum B: a live Firefox, 16 tabs, 7.48 GB

A second real distribution, read off an Activity Monitor snapshot of Firefox on the same
machine — 16 tabs open. It is a harsher test than the Chrome sample and it moves one caveat
from "worth noting" to "load-bearing".

| | |
|---|---|
| Total across 25 Firefox processes | **7.48 GB** |
| Content processes | 17 (14 "Isolated Web Content", 3 near-empty "Web Content") |
| Non-content overhead | **1.85 GB — 24%, before a single page** (parent 689 MB, WebExtensions 578 MB, GPU helper 490 MB) |
| Isolated content procs | median 262 MB, mean 399 MB, max **1005 MB** |
| Top 4 processes | 3.56 GB = **47% of all Firefox memory** |
| Empty content procs | 28.1 MB × 3, identical to 0.1 MB |

Four things worth pulling out.

**16 tabs, 25 processes.** Tab count and process count are not the same thing under Fission —
cross-origin iframes get their own processes. Per-tab reasoning about browser memory is
already the wrong unit.

**The extension process is the 6th-largest thing in the browser** at 578 MB, ahead of every
content process but four. §6 of the design treated extensions as a structural memory problem;
this is what that looks like in practice.

**28.1 MB is the per-process floor**, reproduced to a tenth of a megabyte across three
near-empty content processes. That is the fixed cost site isolation re-pays per process, and
it's the number the fork-server and shared-engine-image items (§4) exist to attack. B3 showed
49 MB/process of code cache is recoverable by sharing; this is the same argument from the
other end.

**Firefox's unloader will never fire here, by design.** The memory-pressure gauge in that
snapshot is green. The unloader is triggered by a pressure signal, not a budget — so the
browser is holding 7.48 GB and has no reason to act on it. Meanwhile the *system* is at
43.2 GB used with 4.77 GB compressed and 2.73 GB of swap: the machine is paying for this, just
not through the signal the browser watches. This is the §4 critique happening live, and it is
not a bug — it is the specified behaviour of a pressure-triggered design.

### Re-running the scheduler on this distribution

| budget | policy | mean | peak | over budget | state lost |
|---|---|---|---|---|---|
| 2 GB | status quo | 26772 M | 27461 M | 100% | 0 |
| 2 GB | discard-LRU | 4919 M | 8635 M | 98% | 2494 |
| 2 GB | **Kestrel** | **2446 M** | 4863 M | **67%** | **0** |
| 4 GB | **Kestrel** | **3823 M** | 4863 M | **1%** | **0** |

The headline holds and gets bigger — **10.9× less memory than unmanaged at 2 GB, 7.0× at
4 GB, still zero state-losing reloads**, against a discard-LRU baseline that is over budget
98% of the time.

But look at the "over budget" column at 2 GB: **67%, against 4% on the Chrome distribution.**
This is the caveat from §10 no longer being theoretical. With a 1005 MB maximum tab, four
MRU tabs kept live, plus audible carve-outs, the protected live set alone can approach 3 GB —
so a 2 GB budget is not merely missed, it is *arithmetically unreachable*, and the scheduler
correctly declines to shred state chasing it. Give it 4 GB of headroom and it holds the bound
1% of the time over.

**Conclusion: a global budget is necessary but not sufficient.** It cannot be honoured below
the size of the largest live tab, and on a real Firefox that floor is around 1 GB for a single
page. Per-tab memory limits — capping what one origin may retain, which nothing in items 1–5
addresses — are not a refinement of this design. They are a prerequisite for the budget slider
in §7 to mean anything.

---

## Per-tab memory limits

The addendum ended by calling per-tab limits a prerequisite rather than a refinement. So they
were implemented ([`scheduler.py`](bench/b4_scheduler/scheduler.py) `CostModel.per_tab_cap`) and
swept.

A cap that only truncated memory would look free, and that would be the whole error. Three
effects are modelled: the truncation (**win**), recurring in-tab reclaim for a tab whose natural
demand exceeds its cap — one compacting GC at ~30 ms from §1, plus re-decoding visible images at
~10 ms each from §2 (**jank**), and outright OOM for a page that cannot be squeezed far enough
(**breakage**).

**Firefox distribution, 2 GB budget:**

| cap | mean | peak | over budget | visits capped | reclaim | OOM breaks |
|---|---|---|---|---|---|---|
| none | 2446 M | 4863 M | 67% | 0% | 0 s | 0 |
| 1024 MB | 2446 M | 4863 M | 67% | 0% | 0 s | 0 |
| 768 MB | 2331 M | 4217 M | 66% | 21% | 9 s | 0 |
| **512 MB** | **1991 M** | **2886 M** | **22%** | 25% | 39 s | **0** |
| 384 MB | 1939 M | 2207 M | 2% | 30% | 48 s | 290 |
| 256 MB | 1967 M | 2048 M | 0% | 40% | 14 s | 1002 |
| 128 MB | 1991 M | 2048 M | 0% | 60% | 29 s | 1451 |

A 1024 MB cap does nothing — it is above the largest tab in the distribution. Below that the
trade appears immediately: **512 MB cuts time-over-budget from 67% to 22% with zero breakage**,
and everything tighter starts destroying pages.

**Firefox distribution, 3 GB budget** — the same cap now closes the gap completely:

| cap | mean | peak | over budget | OOM breaks |
|---|---|---|---|---|
| none | 2921 M | 4863 M | 15% | 0 |
| 768 MB | 2899 M | 4217 M | 7% | 0 |
| **512 MB** | 2921 M | **3072 M** | **0%** | **0** |
| 384 MB | 2944 M | 3072 M | 0% | 290 |

**512 MB per-tab cap + 3 GB budget holds the bound 100% of the time, with zero breakage and
zero state loss**, at a cost of 39 s of in-tab reclaim spread across a 4000-event session —
about 39 ms on each of the 25% of visits that touch a capped tab, or roughly two dropped frames
when you land on a heavy page. That is the configuration to build.

Note that mean memory barely moves (2921 M capped vs 2921 M uncapped). The cap is not there to
lower the average. **It is there to bound the peak**, which is the only thing that determines
whether the budget is a real constraint or a wish.

**Chrome distribution, 2 GB budget** — the same sweep on the lighter-tailed sample (max tab
717 MB rather than 1005 MB):

| cap | mean | peak | over budget | visits capped | reclaim | OOM breaks |
|---|---|---|---|---|---|---|
| none | 1929 M | 2959 M | 4% | 0% | 0 s | 0 |
| 768 MB | 1929 M | 2959 M | 4% | 0% | 0 s | 0 |
| 512 MB | 1934 M | 2436 M | 2% | 7% | 6 s | 0 |
| **384 MB** | 1941 M | **2176 M** | **0%** | 25% | 16 s | **0** |
| 256 MB | 1970 M | 2048 M | 0% | 30% | 26 s | 290 |

Which surfaces something the Firefox run alone would have hidden: **the cap's value is
proportional to the tail of the tab-size distribution, not to the mean.** Chrome's uncapped
configuration is already within 4% of its budget and a cap buys only that last 4%. Firefox's is
67% over, and the cap is the difference between a budget and a wish. Mean tab size differs by
less than 2× between the two samples; the *maximum* differs by 40%, and that is what decides
whether the budget is enforceable.

Practical consequence: the cap must be derived from the budget and the observed live-set tail
at runtime, not shipped as a constant. 384 MB is right for one of these distributions and 512 MB
for the other, and neither is right for a machine with 8 GB of RAM.

**Third distribution (Chrome, 11 tabs incl. 3 live Meet calls), 2 GB budget** — the lightest
tail of the three (max 723 MB, median 146 MB):

| policy | mean | peak | over budget | state lost |
|---|---|---|---|---|
| status quo | 15101 M | 15438 M | 100% | 0 |
| discard-LRU | 2451 M | 3854 M | 75% | 2332 |
| **Kestrel** | **1923 M** | 2611 M | **2%** | **0** |

**7.9× less memory, zero state loss**, and uncapped it is already within 2% of budget — cap
512 MB and it reaches 0% with no breakage. Across all three real distributions the scheduler
result holds at **7.9–10.9×** with zero state-losing reloads, while discard-LRU is over budget
75–98% of the time. The spread in *how much the cap matters* tracks the tail exactly as
predicted: Chrome-with-Meet needs almost none, matched Firefox needs the most.

### The assumption that decides it, and what it means

The verdict above rests on *break ratio* — how far past its cap a page can be pushed before it
stops working rather than merely thrashing — which is the least defensible number in the model.
Sweeping it (cells are over-budget% / OOM breaks, 2 GB budget):

| break ratio | 1024M | 768M | 512M | 384M | 256M | 128M |
|---|---|---|---|---|---|---|
| 1.5 | 67% / – | 66% / – | 22% / 833 | 2% / 1002 | 0% / 1211 | 0% / 1973 |
| 2.0 | 67% / – | 66% / – | **22% / –** | 2% / 833 | 0% / 1002 | 0% / 1610 |
| 2.5 | 67% / – | 66% / – | **22% / –** | 2% / 290 | 0% / 1002 | 0% / 1451 |
| 3.0 | 67% / – | 66% / – | **22% / –** | **2% / –** | 0% / 833 | 0% / 1211 |
| 4.0 | 67% / – | 66% / – | **22% / –** | **2% / –** | **0% / –** | 0% / 1002 |

The frontier is diagonal and the conclusion is not "no cap works" — it is that **the viable cap
is set entirely by how squeezable pages are.** Break ratio 2.0 buys a safe 512 MB cap; 3.0 buys
384 MB; 4.0 buys 256 MB and perfect budget adherence.

Which closes the loop on the whole exercise:

> **Items 1–4 are not primarily memory savers. They are what raises the break ratio.**

JIT tier-down, decoded-image eviction and heap compaction are exactly the mechanisms that let a
page run in less memory than it naturally asks for. Judged as direct savings they were
underwhelming — item 1 is worth ~15 MB/tab and returns nothing to the OS without compaction.
Judged as *break-ratio purchases* they are the reason a per-tab cap is survivable at all, which
is what makes the global budget reachable, which is where the 8.9–10.9× actually lives.

That reframing is worth more than any single number here. It also sharpens the next question,
which none of this answers: **what break ratio do items 1–4 actually deliver on a real page?**
That is measurable — cap a real renderer and see where pages start failing — and it is the
experiment that should come next.

---

## Prior art: what Firefox already does

The benchmarks above were run before checking the design against shipping browsers, which was
the wrong order. Doing it afterwards changed the framing of three items out of four. Nothing
measured here is invalidated — but "novel proposal" becomes "extend an existing mechanism" in
two cases, and "already solved" in a third.

**Item 2 is not new. It shipped in Firefox 4.** `image.mem.discardable` defaults to true and
Firefox discards decoded images from background tabs. The design proposed a solved problem.

What is *not* solved is the side effect, and it is the exact one B2 predicts: users report tab
switches where "text appears first without images and then images appear after a delay"
([bug 661304](https://bugzilla.mozilla.org/show_bug.cgi?id=661304),
[bug 1149893](https://bugzilla.mozilla.org/show_bug.cgi?id=1149893) — the latter literally adds
a pref to decode everything eagerly and spend the memory instead). That flicker is the 50.8 ms
4K decode measured in §2. So the contribution collapses from "evict decoded images" to
something narrower and more useful: **the 1/8-scale preview at 506 KB against 31.6 MB is what
lets you discard aggressively *without* the pop-in that made this controversial for fifteen
years.** That is a real gap, and a much better-defined patch than the original item.

**Item 3's mechanism already exists in-tree — pointed at the wrong scripts.** Gecko's
[`ScriptPreloader`](https://github.com/mozilla/gecko-dev/blob/master/js/xpconnect/loader/ScriptPreloader.cpp)
memory-maps a bytecode cache via `AutoMemMap` and shares it across content processes, migrated
to Stencil-XDR in
[bug 1688788](https://bugzilla.mozilla.org/show_bug.cgi?id=1688788). But it is scoped to browser
chrome and early-startup scripts. Web content instead uses the
[JavaScript Startup Bytecode Cache](https://blog.mozilla.org/javascript/2017/12/12/javascript-startup-bytecode-cache/),
which stores bytecode in the *network cache* as alternate data, loaded per document.

This is a much stronger position than the design assumed. The proposal is no longer "build an
mmap'd shared cache" — the hard part is written, shipped, and battle-tested. It is **"extend
`ScriptPreloader`'s sharing model to web content bytecode."** B3's 49 MB → 0 MB per process is
the size of that prize. (Whether JSBC currently keeps a private per-process copy of decoded
bytecode is not established by the public docs and should be confirmed in the source before
anyone commits to a number.)

**Chrome is further ahead than the Firefox-only framing suggested, and one claim here needed
correcting.** Chrome 150 ships Memory Saver, which per
[Chrome's own developer docs](https://developer.chrome.com/blog/memory-and-energy-saver-mode)
"will **proactively** discard tabs that have been unused in the background for some time" — a
timer, not a pressure signal. Secondary sources report Chrome 140+ replaced the fixed timer with
ML-based revisit prediction; that is analogous to this design's `p_return()` term, but it is not
confirmed by Chrome's own documentation and shouldn't be relied on. So the earlier statement in
§4 that browsers "run no global policy at all" was too strong: Chrome runs one, and it acts
before pressure.

What Chrome's documentation *does* settle is the part that matters most here:

> "When a tab is discarded… the page itself is gone, exactly as if the tab had been closed
> normally. If the user revisits that tab, the page will be reloaded automatically."

**Two states, and the demotion is destructive.** No intermediate frozen state, no session image,
no exposed budget. Which means the `discard-LRU` baseline in §4 is a faithful model of *both*
shipping browsers — and note that the simulated baseline enforces at every event rather than on
a pressure signal, so it is modelled as the **proactive** Chrome variant, not the weaker Firefox
one. It still sits over budget 97–98% of the time.

That is the useful result: **making discarding proactive does not let it hold a budget.** The
binding constraint is the destructive-only toolset — the policy runs out of tabs it is allowed
to kill — not the trigger. Only non-destructive intermediate states fix it.

**Item 4 is the one that stands.** Firefox has had tab unloading since version 93
([Mozilla Hacks](https://hacks.mozilla.org/2021/10/tab-unloading-in-firefox-93/),
[source docs](https://firefox-source-docs.mozilla.org/browser/tabunloader/)), with an
`about:unloads` page, LRU ordering, and exclusions for media, PiP, WebRTC and pinned tabs.

But per the source docs it is **triggered by a memory-pressure signal, not a budget**, and it
has **exactly two states, loaded and unloaded**. That is precisely the `discard-LRU` policy
benchmarked in §4 — and §4's result is a direct critique of it: at a fixed budget, a
destructive-only policy sits over target **97% of the time**, because the same exclusion list
that protects user work also starves it of legal victims. The exclusions Firefox ships are
correct *and* are what makes a two-state design unable to hold a bound.

So item 4's contribution is specific and survives intact: **(a) a proactive budget rather than
a reactive pressure signal, and (b) non-destructive intermediate states so the scheduler always
has somewhere to put a tab it may not discard.** Firefox has the carve-outs right and the
ladder missing.

**Where such a patch could land.** Of the Firefox derivatives, LibreWolf, Floorp and Mullvad
Browser are privacy/UI forks that track upstream closely and carry no engine-level memory work;
they are consumers of Gecko, not plausible hosts for this. Brave is Chromium-based. That leaves
upstream Gecko as the realistic home for items 1–5, which raises the bar — these have to be
argued in Bugzilla against Mozilla's own performance team, who have already litigated items 2
and 4 at length. The measurements here are the form that argument would have to take.

---

## Where this leaves the design

**Confirmed.** Memory proportional to what you're looking at is achievable, and most of
it comes from one mechanism — a global budget with a non-destructive eviction ladder —
not from engine micro-optimization. 8.9× on a realistic tab distribution, with better
user-visible behaviour than what browsers do today, not worse.

**Corrected.** Five claims in DESIGN.md did not survive contact:

1. *"None tier down"* — false; V8 flushes bytecode by default and has a
   tab-visibility hook. The real gap is that optimized functions are exempt.
2. *Item 1 is a cheap standalone win* — false; without compaction it returns 0–1% to the
   OS. **Compaction/decommit is promoted to its own roadmap item and must precede it.**
3. *Warm tabs must reach < 2 MB* — not load-bearing for memory. Restated as a latency
   target.
4. *Decoded-image eviction is a novel win* — false; Firefox shipped it in version 4. The
   open problem is the pop-in it causes, which the 1/8-scale preview addresses.
5. *An `mmap`'d shared bytecode cache must be built* — false; `ScriptPreloader` already is
   one. It just doesn't cover web content.

**Revised delivery order**, by measured value per unit risk:

1. **Budget-driven scheduler + a crude WARM state + a per-tab cap** — 8.9–10.9×, the sweep says
   a crude WARM is fine, and it is the only item of the four that isn't already half-built.
   Firefox has the carve-outs; it is missing the ladder, the budget, and the cap. The cap is
   not a follow-up: without it the budget is unreachable 67% of the time on a real Firefox
   distribution, and with it (512 MB / 3 GB) the figure is 0%.
2. **Extend `ScriptPreloader` sharing to web content bytecode** — 49 MB/process, no compat
   risk, and the mmap machinery already exists and ships. Confirm JSBC's per-process residency
   in the source first.
3. **Compaction + eager decommit** — the precondition for any heap-level saving being real.
4. **1/8-scale previews for discarded images** — *not* "add image discarding", which Firefox
   has had since v4. This is the fix for the fifteen-year-old pop-in complaint that discarding
   causes, and it is what would let the existing policy be more aggressive rather than less.
5. **JIT tier-down** — last, not first. Worth ~15 MB/tab, and only after (3) makes it count.

**Unchanged.** Items 5–8 (`serializestate`, COLD hibernation, fork-server renderers, Rust
core) still look justified — item 4's result is what funds them — but the freeze-quality
sweep says they buy smoothness and restore fidelity rather than the headline number. They
should be argued for on those terms.

**The risk that was open, now closed.** Peak hit 2959 MB against a 2 GB budget on the Chrome
distribution and **67% over on the live Firefox distribution**, because the foreground tab is
the one thing no scheduler may touch and a single real content process reached 1005 MB. Per-tab
limits were then implemented and swept (§ Per-tab memory limits): **a 512 MB cap with a 3 GB
budget holds the bound 100% of the time with zero breakage and zero state loss.** A global
budget without a per-tab limit is not a budget; the two are one mechanism and must ship
together.

**The risk that is now the top one.** The cap's viability rests entirely on *break ratio* — how
far a page can be squeezed below its natural demand before it fails — and that number is
currently an assumption, not a measurement. Everything downstream of it is conditional. The
next experiment is to cap a real renderer and find where real pages actually break.
