# Kestrel — a browser designed around a memory budget

**Thesis:** resident memory should be proportional to *what the user is looking at*, not to
*what they have open*. Every mainstream browser gets this backwards: 60 open tabs cost roughly
60 tabs' worth of RAM, because a background tab is a fully live tab that simply isn't painted.

Kestrel's organizing constraint: **the user sets a global memory budget and the browser stays
inside it**, degrading gracefully rather than growing without bound.

---

## 1. Where the memory actually goes

Before proposing anything, it's worth being precise about the sources. Rough order of magnitude
for a mainstream engine (Gecko or Chromium, they're similar in shape):

| Source | Typical cost | Why it's there |
|---|---|---|
| Per-renderer-process baseline | ~30–80 MB private dirty | JS runtime, JIT stubs, atom tables, style system, font & ICU data — duplicated per process |
| JS heap (live objects) | 5–100 MB/tab | The real working set. Legitimately needed *when running* |
| JIT code + inline caches | 10–30% of tab heap | Optimized code for functions that haven't run in an hour |
| Decoded images / GPU textures | 10–200 MB/tab | A 4K image is 33 MB decoded from a 2 MB file — a 16× amplification |
| DOM + layout + display lists | 5–50 MB/tab | ~100–200 B/node, plus frames, plus computed styles |
| Caches (HTTP, bfcache, fonts, shaders) | 100s of MB, global | Mostly anonymous heap, so unreclaimable without swapping |
| Extensions | 5–50 MB × tabs | Content scripts injected everywhere, persistent background pages |

> **Measured (RESULTS.md § Addendum A).** With the same 11 pages loaded side by side on one
> machine: **Firefox 6240 MB / 19 processes, Chrome 4617 MB / 34 processes** — **567 vs 420 MB
> per tab, Firefox +35%.** So the framing this document was written to answer holds up under a
> controlled test. (An earlier *uncontrolled* comparison suggested the opposite; the Chrome
> session in it was running three live video calls.)
>
> The architectural contrast matters more than the totals. Firefox **consolidates** — 1.09
> content processes per tab, median 499 MB each. Chrome **fragments** — 2.36 per tab, median
> 110 MB each. Chrome pays the per-process baseline 2.4× more often and still wins by 35%,
> which means **at this scale the baseline is not the dominant term — retention is.** That
> demotes §4's fork-server work relative to the retention items (§2, §5, §5a), without
> eliminating it: B3 measured 49 MB/process of shareable code cache, worth 2.4× more under
> Chrome's architecture.
>
> Both browsers spend 26–31% of their memory before rendering anything, and neither treats
> total footprint as a bound — which is what §2 addresses.

Two structural observations follow, and they drive the whole design:

**(a) Site isolation multiplies a fixed cost.** Firefox's Fission and Chromium's site isolation are
security-necessary — you cannot let two origins share an address space when Spectre exists. But
each process re-pays a baseline that is ~90% identical read-only engine state. The fix is not
fewer processes (that's a security regression); it's *cheaper* processes.

**(b) Anonymous memory is the enemy.** Anonymous pages can only be swapped, never dropped.
File-backed clean pages can be evicted by the OS for free and faulted back in on demand. Most of
what a browser holds — bytecode, decoded fonts, HTTP cache bodies, shaders, thumbnails — is
*regenerable or already on disk*, yet lives on the heap. Moving it to `mmap`'d files converts hard
memory pressure into soft page-cache pressure.

---

## 2. The tab lifecycle: four states, not two

The central mechanism. Every tab occupies exactly one state; a scheduler moves tabs between them
to hold the global budget.

```
  LIVE  ──freeze──▶  WARM  ──hibernate──▶  COLD  ──evict──▶  STUB
   ▲                  │                     │                 │
   └──── resume ──────┴───── rehydrate ─────┴──── reload ─────┘
       <16 ms              ~80 ms               300–900 ms
```

**LIVE** — foreground tab plus the *N* most recent, where *N* adapts to installed RAM and current
budget headroom. Full DOM, JS heap, layout, GPU tiles. No changes from today.

**WARM** — execution halted at a GC safepoint. Timers, `rAF`, and idle callbacks cancelled;
`freeze` fired on the Page Lifecycle API. GPU tiles released and replaced by one compressed
snapshot. Decoded images dropped, compressed sources retained. The JS heap gets a full compacting
GC, then its arenas are `madvise(MADV_COLD)`/`MADV_FREE`'d — still mapped, still correct, but the
kernel may take the pages under pressure. Target: **< 2 MB private dirty per warm tab.** Resume is
a repaint plus a few faults, so it stays under a frame.

> **Measured (RESULTS.md §4).** That 2 MB target is a *latency* goal, not a memory one. Sweeping
> freeze quality across a 25× range — a warm tab retaining 2% of its live bytes versus 50% —
> moved mean memory by **8%** while moving user-visible jank by **2.3×**. The memory comes from
> having a budget and enforcing it; freeze quality buys smoothness. Ship a crude WARM first.

**COLD** — the renderer process is torn down. Tab state is serialized to a compact on-disk
*session image*: post-load DOM tree (structurally shared against the original response body, so it
compresses to a few tens of KB), CSSOM overrides, scroll offsets, full form state including
uncommitted input, `sessionStorage`, history entry, and — for cooperating pages — an
application-state blob (see §3). Resident cost: **a ~2 KB descriptor plus a thumbnail reference
into an `mmap`'d atlas.**

**STUB** — URL, title, favicon, thumbnail. What a restored-session tab is today.

The important claim: today's browsers only have LIVE and STUB. "Unload background tab" jumps
straight to a network reload and loses your scroll position, your half-written comment, and your
open modal. WARM and COLD are what make aggressive eviction *acceptable to users*, and user
acceptance is what makes the memory savings real.

### The scheduler

Eviction is a caching problem. Browsers do now run eviction policies — Firefox unloads tabs on a
memory-pressure signal, Chrome's Memory Saver discards them proactively on a timer — but both are
two-state and destructive: a demoted tab is gone and reloads from the network. Neither takes a
*budget* as its control target. Kestrel scores every non-foreground tab and demotes the worst
until it is under budget:

```
score(tab) = P(user returns within horizon) × restore_cost(tab)
             ─────────────────────────────────────────────────
                          bytes_recoverable(tab)

P(return)      ← recency, dwell time, pinned, tab-strip adjacency, audible,
                 has unsubmitted input, is a PWA, historical revisit rate
restore_cost   ← measured, not guessed: EWMA of this site's actual resume latency
bytes_recover  ← measured private dirty, not an estimate
```

Demote lowest score first. Promote speculatively on intent signals (tab-strip hover, `Ctrl`-held,
switcher opened) so the common case of returning to a warm tab never shows a spinner.

**Demotion floors.** Not a single "protected" flag — a per-reason floor, because the states differ
in what they risk. WARM is a *paused* tab that preserves everything; COLD serializes form state
into the session image; only STUB discards work.

| reason | floor | rationale |
|---|---|---|
| audible, `MediaStream`, screen-share, uploading, in `beforeunload` | LIVE | must keep executing |
| user-pinned | WARM | asked for it to stay instant, but freezing is invisible |
| unsubmitted form input | COLD | serialized in the session image; never discard to a reload |
| everything else | STUB | |

> **Measured (RESULTS.md §4).** An earlier draft made all of these block demotion entirely. That
> pinned ~16% of tabs permanently LIVE and made the budget unreachable. The per-reason floor is
> what lets the policy hold budget, at **zero state-losing reloads**.

**Fail safe when the budget is unreachable.** Never demote for a trivial gain: COLD → STUB
recovers ~30 KB while destroying a session image. If no candidate recovers at least ~1 MB, stop
and sit over budget rather than shredding state chasing a target the live working set makes
impossible. This one rule took state losses from 757 to 0 and p95 restore from 1100 ms to 450 ms.

---

## 3. The hibernation contract

Full JS heap serialization is not achievable in general — closures capture native handles, and
WASM memories, WebGL contexts, and live sockets have no meaningful disk representation. Pretending
otherwise is where this kind of design usually dies. So Kestrel splits the problem:

**Cooperating pages** implement two new lifecycle events:

```js
addEventListener('serializestate', e => {
  e.provide(store.getState());          // any structured-cloneable value
});
addEventListener('restorestate', e => {
  store.hydrate(e.state);               // fires before first paint on rehydrate
});
```

The browser guarantees the blob survives hibernation, process death, and browser restart. A page
that implements this gets **lossless** cold storage: the tab comes back exactly as it was,
including in-memory application state, with no network request.

This is a small enough API that React, Vue, Svelte, and Next implement it once in their router or
store layer and most of the web inherits it without touching application code. That leverage is
the point — it is the same play that made `bfcache` work.

**Non-cooperating pages** get snapshot-plus-reload: the rendered snapshot is shown instantly, DOM
and form state are restored from the session image, and the page reloads underneath on first
interaction. Degraded, but no worse than today's tab discarding, and visually seamless.

**Opt-out** is per-site and sticky, both by user action and by a response header, for pages that
know they can't survive it.

---

## 4. Cheap renderer processes

Keep one process per site-origin — the security model is not negotiable. Make each one cost
~5–8 MB of private dirty instead of ~40–80 MB.

**Fork-server / zygote, done on all three platforms.** Boot one template process with the engine
fully initialized: interpreter and JIT stubs generated, atom tables built, ICU and font data
loaded, style system tables constructed. Every renderer is a `fork()` of that template, so all of
it is copy-on-write shared. Chromium does this on Linux only; the design commits to equivalents on
Windows (pre-warmed pool + shared sections) and macOS (`posix_spawn` from a pre-initialized image).
This alone is the single largest per-process win available.

**Prelinked, read-only engine image.** At build time, emit the engine's immutable data — bytecode
for self-hosted builtins, JIT trampolines, Unicode tables, the default stylesheet's parsed form —
into a single `mmap`-able blob loaded read-only. It is shared across every process by the page
cache and is evictable.

**`mmap`'d bytecode, shared across tabs.** Parse each script to bytecode once, store it in an
on-disk code cache keyed by content hash, and map it read-only into every process that needs it.
React loaded in twelve tabs becomes one copy of the bytecode, in clean file-backed pages. Today it
is twelve heap copies.

**Rust engine core.** Language-level memory safety means the process boundary is only needed where
there is a genuine adversary. Network, storage, and UI become capability-restricted threads rather
than separate processes; process boundaries are spent on renderers (per site-origin) and on
media/codec workers (per stream, because codecs are C and are where the CVEs live).

---

## 5. Give memory back

**Compacting GC with real decommit.** Generational, concurrent, and — critically — compacting on
freeze, so a warm tab's arenas are dense rather than 40% holes. Freed arenas are `MADV_FREE`'d
promptly with hysteresis, not retained indefinitely against a hypothetical future allocation.

> **Measured (RESULTS.md §1).** This is the load-bearing item, not the one below. Across every
> flushing configuration tested, freeing code objects returned **0–1% of the freed bytes to the
> OS** — partly-occupied pages cannot be unmapped. Only with compaction enabled did RSS actually
> fall, by 21%. Heap-level reclaim without compaction optimizes `about:memory` and nothing else.

**Tier-down JIT.** Engines already tier *up*: interpreter → baseline → optimizing. Contrary to an
earlier draft of this document, they also partly tier *down* — V8 ships `--flush-bytecode` (on by
default, after 6 GCs), `--flush-baseline-code` (off by default), and a
`--flush-code-based-on-tab-visibility` hook. The real gap is narrower and more specific: **V8 will
not flush a function's bytecode while that function has optimized code attached**, because the
bytecode is needed to deoptimize back into. So the existing policy exempts precisely the hot
functions that dominate code memory.

> **Measured (RESULTS.md §1).** Tiering up raises a tab's idle code floor from 18.4 MB to 46.5 MB
> and it never comes back: **28.2 MB permanently retained**, 2.5×. Forcing aggressive flushing
> recovers to 31.7 MB. Worth roughly 15 MB per tab — real, but an order of magnitude less than the
> scheduler, and worth nothing at all until compaction ships.

**Decoded images are a cache, not storage.** Retain the compressed source and a downsampled
preview; decode on demand. A 4K JPEG decodes in single-digit milliseconds and costs 33 MB to hold.
Never hold a decoded surface for content outside the viewport.

**Bounded, viewport-proportional raster.** Allocate tiles for the visible viewport plus a small
prefetch margin, never for the full scrollable area. Cap the GPU texture cache as a function of
display resolution, not page count — on integrated graphics that memory *is* your RAM.

**Every cache is file-backed, capped, and pressure-aware.** HTTP bodies, bytecode, shaders,
decoded fonts, thumbnails: all `mmap`'d files with a hard byte cap, LRU eviction, and a hook on OS
memory-pressure notifications. Anonymous heap is reserved for things that genuinely cannot be
regenerated.

---

## 5a. Per-tab memory limits

The global budget in §2 has a hard floor: **the scheduler may never touch the foreground tab,
so the budget cannot be honoured below the size of the largest live tab.** On a real Firefox
sampled for RESULTS.md, one content process held 1005 MB. Against a 2 GB budget, the protected
live set alone (foreground + MRU + audible) approaches 3 GB, and the scheduler correctly refuses
to shred state chasing a target it cannot reach — it sits over budget 67% of the time.

A budget without a per-tab limit is therefore not a budget. It is a hope.

**The cap is soft, then hard.** A tab crossing its limit does not immediately die:

1. **In-tab reclaim first.** Force a compacting GC, drop every decoded surface outside the
   viewport, tier down the JIT, evict that tab's share of the caches. This is items 1–4 of the
   roadmap, applied *within* one tab rather than across tabs.
2. **Freeze if it's not foreground.** A background tab over its cap doesn't need reclaim at
   all — WARM already exists and is cheaper. The cap only really binds the protected set.
3. **OOM last.** A page that cannot be squeezed into its cap gets an allocation failure and a
   reload, with the same "this page used too much memory" treatment browsers already ship.

**The parameter that decides everything is how far a page can be squeezed** — call it the
*break ratio*, the multiple of its cap a page can be pushed to before it stops working rather
than merely thrashing. And this is where the roadmap closes a loop:

> **Items 1–4 are not primarily memory savers. They are what raises the break ratio.**
> JIT tier-down, decoded-image eviction and heap compaction are precisely the mechanisms that
> let a page run in materially less memory than it naturally asks for. Their direct savings are
> modest — item 1 is worth ~15 MB/tab. Their real value is that they make a per-tab cap
> survivable, which is what makes the global budget reachable, which is where the 8.9× lives.

Measured frontier on the Firefox distribution at a 2 GB budget (RESULTS.md § Per-tab limits):
a **512 MB cap cuts time-over-budget from 67% to 22% with zero breakage** once the break ratio
reaches 2.0. Tightening to 384 MB reaches 2% over budget but needs a break ratio of 3.0 — more
aggressive in-tab reclaim than items 1–4 currently deliver.

**The cap must be adaptive, not a constant.** It is a function of the global budget, the number
of protected tabs, and whether the tab is foreground; a fixed number either strangles the one
heavy page the user actually cares about or fails to bound anything. It should also be visible
and overridable per site, because the alternative to a cap is not "the page works" — it is the
whole browser swapping.

---

## 6. Extensions

Extensions are one of the largest real-world sources of browser bloat, and the cost is structural:
a persistent background page lives forever, and a `webRequest` listener forces a live JS context in
every tab.

- **No persistent background pages.** Event-driven service workers only, terminated when idle.
- **Declarative APIs for the common cases** — request blocking, redirects, CSS injection, header
  modification — so content blockers, which is most of what people install, cost approximately zero
  per tab instead of a JS context per tab.
- **Content scripts are torn down on freeze** and re-injected on resume, from the same shared
  bytecode cache as page scripts.
- **Per-extension memory accounting surfaced in the UI**, with the same eviction pressure applied
  to extension workers as to tabs.

---

## 7. Memory as a product surface

`about:memory` is excellent and no user has ever opened it. Kestrel promotes the accounting to a
first-class feature:

- A **budget slider** in settings: "use at most ___ GB." The scheduler treats it as a hard bound.
- **Per-tab attribution in the tab strip** — hover a tab, see its cost and its state.
- **"This tab is using 1.2 GB"** proactive notice, with a one-click freeze, the way a browser today
  surfaces a slow-script dialog.
- Attribution split by tab, frame, and extension, so users can identify the actual culprit rather
  than blaming the browser.

---

## 8. Targets

Design targets, not measurements — these are the numbers the architecture is built to hit.
[RESULTS.md](RESULTS.md) reports what items 1–4 actually achieved; the per-tab figures below
remain unvalidated, and the warm-tab row is a latency target rather than a memory one.

| | Target |
|---|---|
| Shared engine image (all processes) | ~60 MB, file-backed, evictable |
| Live tab, typical content site | < 25 MB private dirty |
| Warm tab | < 2 MB private dirty |
| Cold tab | ~2 KB resident + file-backed snapshot |
| **100 tabs open, 5 live** | **~500 MB resident** |
| Warm → live | < 16 ms (one frame) |
| Cold → live, cooperating page | < 100 ms, no network |
| Cold → live, non-cooperating page | 300–900 ms, snapshot shown immediately |

---

## 9. Honest trade-offs

**Latency for memory.** This is the whole bargain. It only holds if resume is imperceptible, which
is why so much of the design is about restore paths rather than about allocation. If warm resume
ever exceeds one frame, users will disable the feature and the memory win evaporates.

**Compatibility risk.** Hibernation breaks long-polling connections, WebRTC sessions, WebGL
contexts, and anything holding a socket. The carve-out list in §2 is load-bearing, and it must fail
*safe*: when uncertain, stay warm rather than go cold.

**Ecosystem dependency.** Lossless hibernation needs pages to implement `serializestate`. Without
framework adoption, most tabs land on the degraded path. This is the biggest external risk and
argues for shipping the API early, alone, and standardizing it.

**Scope.** The web platform is on the order of a thousand specifications. A from-scratch engine is
a decade of work, and "Firefox is a memory hog" is not a good enough reason to rewrite the web
platform. The realistic delivery is as changes to an existing engine — and specifically to
*upstream Gecko*. The Firefox derivatives (LibreWolf, Floorp, Mullvad Browser) are privacy and UI
forks that track upstream closely and carry no engine-level memory work; Brave is Chromium-based.
None is a plausible host for engine patches, which means these changes have to be argued in
Bugzilla against a performance team that has already litigated most of them.

**Prior art is the first thing to check, not the last.** Three of the four items benchmarked here
turned out to be partly or wholly shipped already (RESULTS.md § Prior art). The measurements
survived; the novelty claims didn't. Anything added to this document should be checked against
what Gecko and Chromium already do *before* it is costed.

**What not to do:** don't cap process count (that's a security regression sold as an optimization);
don't compress memory in-process (macOS and Windows already do compressed memory, so you'd pay the
CPU twice); don't add a "lite mode" that just breaks pages.

---

## 10. Delivery order

**This section has been rewritten against measurements.** Items 1–4 of the original order were
built and benchmarked; see [RESULTS.md](RESULTS.md). The thesis survived, but the ordering did not
— the original list led with the weakest item and omitted the one that makes it work.

Revised, by *measured* value per unit risk:

1. **Budget-driven scheduler + a crude WARM state + a per-tab cap (§5a)** — **8.9–10.9× less
   memory, zero state-losing reloads.** The cap ships *with* the budget, not after it: without
   one, the budget is unreachable 67% of the time on a real Firefox tab distribution; with a
   512 MB cap and 3 GB budget it is met 100% of the time with zero breakage. The two are one
   mechanism. This is not one of four comparable wins; it is essentially the whole result. The
   freeze-quality sweep says the crude version is fine to start: a 25× worse WARM costs 8% more
   memory. It is also the only item here that isn't already half-built upstream — Firefox has
   shipped tab unloading since v93, but pressure-triggered and two-state, which §4 shows cannot
   hold a budget. Firefox has the carve-outs right; the ladder and the budget are missing.
2. **Extend Gecko's `ScriptPreloader` sharing to web content bytecode** — **49 MB → 0 MB per
   process.** The `AutoMemMap` cross-process sharing machinery already exists in-tree; it is
   scoped to chrome and startup scripts, while web content goes through the network-cache-based
   JSBC. This is a scope change to shipped code, not new infrastructure.
3. **Compaction + eager decommit** — *was not on the original list*. It is the precondition for any
   heap-level saving being visible to the OS at all: without it, freeing code memory returned 0–1%.
4. **1/8-scale previews for discarded images** — *not* "add image discarding": Firefox has
   discarded background-tab images since v4 (`image.mem.discardable`). The unsolved part is the
   pop-in it causes, which is the 50 ms 4K re-decode measured in RESULTS.md §2. A 506 KB preview
   against a 31.6 MB surface is what lets discarding be *more* aggressive rather than less.
5. **JIT tier-down** — **last, not first.** Worth ~15 MB/tab, and worth nothing before (3).
6. **`serializestate`/`restorestate`** — ship and standardize early anyway; adoption is the long pole.
7. **COLD hibernation** — depends on 1 and 6.
8. **Fork-server renderers on all platforms** — architectural, high value, high effort.
9. **Rust engine core** — the long game; only justified if the above hold up in a real engine.

The original gate — *"if items 1–4 don't capture a large fraction of the win, the thesis is wrong"*
— was met: 8.9× on a tab-size distribution sampled from a real running browser, with better
user-visible behaviour than today's tab discarding rather than worse. Items 6–9 are funded, but on
revised grounds: they buy restore fidelity and smoothness, not the headline number.

**What items 1–5 still do not solve.** A budget cannot be honoured below the size of the largest
live tab, and the foreground tab is the one thing no scheduler may touch. In the real Chrome
distribution sampled here a single renderer reached **717 MB**, which is why peak stayed at 2959 MB
against a 2 GB budget. Per-tab memory limits are a separate, still-unaddressed problem.
