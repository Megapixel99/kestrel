# Kestrel — a working browser with a memory budget

A real macOS browser built on WebKit (`WKWebView`) that implements the four-state tab ladder
from [../DESIGN.md](../DESIGN.md) and enforces a user-settable global memory budget.

Findings from running it are in [../RESULTS-ENGINE.md](../RESULTS-ENGINE.md).

```bash
swift build
```

## Modes

**`kestrel gui`** — the browser.

```bash
./.build/debug/kestrel gui
```

The UI exists to make the ladder visible, which is DESIGN.md §7's point: `about:memory` is
excellent and nobody opens it.

- **Tab strip** — one row per tab with its snapshot thumbnail, a colour-coded state pill
  (LIVE green / WARM orange / COLD blue / STUB grey), its *real measured* footprint, and its
  last restore latency. Tabs visibly change colour as the scheduler demotes them.
- **Memory bar** — a stacked bar segmented by tab state, with the budget drawn as a line
  across it. It scales to whichever of total-or-budget is larger, so going over budget is
  visible rather than clipped, and the budget line turns red when you cross it.
- **Budget slider** — 300 MB to 8 GB. Drag it down and watch tabs walk down the ladder in real
  time. This is the whole thesis in one control.
- **Per-tab cap** — the §5a mechanism, selectable from none to 768 MB.
- **Status line** — totals against budget, a count of tabs in each state, cumulative demotions
  and discards, and a notice when the budget is *unreachable* and the scheduler is deliberately
  holding over budget rather than destroying more state.
- **Restore placeholder** — a restoring tab shows its snapshot immediately rather than a blank
  window, which is what makes eviction invisible to the user.

⌘T focuses the address bar, ⌘W closes the selected tab, ⌘Q quits.

**`kestrel probe [n]`** — spawns *n* tabs one at a time, maps each to its WebContent process,
and drives one tab through LIVE → WARM → COLD → restore, reporting what each rung costs. This
is the measurement behind RESULTS-ENGINE.md.

```bash
./.build/debug/kestrel probe 4
```

**`kestrel bench <urlfile> <budgetMB> <policy> <events>`** — headless. Loads real sites, replays
a recency-biased access trace, and logs real memory under one of three policies: `none`,
`discardlru` (what Chrome and Firefox actually do), `kestrel`.

```bash
./run_bench.sh 400 40
```

One policy per process invocation, deliberately: WebKit's process cache keeps released
WebContent processes alive for minutes, so running two policies in one process would let the
first contaminate the second.

## Features

**Ad / tracker blocking** — declarative, via `WKContentRuleList`. A 51-rule built-in starter
set, plus a converter that consumes **real filter lists**.

Drop an EasyList / uBlock / hosts-format list at `~/.kestrel/filters.txt` and Kestrel converts
it to Safari content-blocker JSON at startup and compiles it alongside the built-in rules.
Supported: `||domain^` anchors, `@@` exceptions, `$third-party`, `$domain=a|~b`, resource-type
options, `##` cosmetic rules (grouped per domain to keep the rule count down), and `0.0.0.0`
hosts lines. Deliberately skipped, and counted rather than silently dropped: regex rules,
procedural/scriptlet cosmetics (`#?#`, `##+js`), and options WebKit cannot express (`$csp=`,
`$redirect=`, `$removeparam=`).

```bash
./.build/debug/kestrel filters ~/.kestrel/filters.txt   # convert + compile, with stats
./.build/debug/kestrel bisect  ~/.kestrel/filters.txt   # find the exact rule WebKit rejects
```

`bisect` exists because WebKit reports a whole-list failure as an opaque `WKErrorDomain error 6`.
It compiles each rule alone to name the offender — which is how the converter's own bug was
found: WebKit rejects any trigger carrying **both** `if-domain` and `unless-domain`, so they are
mutually exclusive and the negation has to be dropped.

This is deliberately *not* a JS blocker: DESIGN.md §6 argues a `webRequest`-style listener forces
a live JS context in every tab, while declarative rules are compiled once by WebKit and cost
approximately nothing per tab. Content blocking is the most-installed extension category, so this
choice sets the floor for a browser's per-tab memory.

**Auto-refresh** — per-tab, from the toolbar: 5s / 15s / 30s / 60s / 5m. This one has a design
consequence worth noting: a refreshing tab is a live dashboard, so demoting it would defeat the
point. It gets a **LIVE floor** in the scheduler and pays full price, which the status bar shows.
It is the first feature here that *costs* memory rather than saving it.

**QR codes** — `QR` button renders the current URL via CoreImage's encoder, with save-to-PNG.

**Dark mode** — `Dark` button toggles a Dark-Reader-style stylesheet. Honest about what it is:
real Dark Reader analyses computed styles per element and rebuilds a palette; this is the
cheaper smart-invert approach — invert the document, rotate hue, then un-invert images, video,
canvas and SVG so photos aren't negatives. Handles most sites, gets some wrong, costs one
stylesheet per tab instead of a JS analysis pass.

**Userscripts** — Tampermonkey-style. Drop `*.user.js` into `~/.kestrel/userscripts/` with the
standard metadata block (`@name`, `@match`, `@run-at`). WebKit has no notion of match patterns —
a `WKUserScript` goes into every page — so each script is wrapped in a runtime origin guard
compiled from its `@match` lines. `Scripts` reloads them; reopen a tab to apply.

**Bitwarden autofill** — `Fill` button, via the official `bw` CLI.

```bash
brew install bitwarden-cli
bw login                      # once
export BW_SESSION="$(bw unlock --raw)"
./.build/debug/kestrel gui    # launched from that same shell
```

The security properties are deliberate, and are the reason it works this way rather than more
conveniently:

- **The master password never touches Kestrel.** You run `bw unlock`; the app only ever sees the
  session key you export, and never prompts for, displays, or stores it.
- **The session is passed to `bw` through the child environment**, not argv, so it stays out of
  `ps` output.
- **Nothing is persisted** — the vault is queried on demand.
- **Origin must match before a credential is offered.** `mail.example.com` matches an item saved
  for `example.com`; `example.com.evil.net` does not. This is the check that stops a look-alike
  page harvesting a saved password, and it is covered by tests in `kestrel selftest`.
- **HTTPS only, main frame only**, and the fill script re-checks the origin at execution time in
  case the page navigated between the vault query and the fill.
- **It never submits the form.** Fields are populated; you review and press the button.
- Credentials are never logged.

```bash
./.build/debug/kestrel selftest
```

runs 17 checks over the blocklist, userscript parsing, dark mode, QR, and every one of the
Bitwarden origin-gate and escaping cases — including that a password containing quotes,
backslashes and `</script>` cannot break out of the injected string.

## Related projects, and what can actually be reused

| project | license | relationship |
|---|---|---|
| [Dark Reader](https://github.com/darkreader/darkreader) | MIT | **Vendored.** Ships a standalone build designed for embedding; `DarkReaderBridge` loads it and falls back to built-in CSS when absent. |
| [Zen](https://github.com/irbis-sh/zen-desktop) | MIT | **Complementary, not integrated.** A system-wide MITM-proxy ad blocker in Go/Wails. Different architecture, and nothing to integrate — if it is running it already filters Kestrel's traffic. |
| [eyeo extensions](https://gitlab.com/eyeo/browser-extensions-and-premium/extensions/extensions) (Adblock Plus / AdBlock) | **GPL-3.0-or-later** | **Reference only.** Vendoring any of it would make Kestrel GPL-3.0. Its filter *syntax* is a spec, not code, so the converter in `FilterList.swift` was written from the syntax rather than derived from their source. |

The licence column is the operative one. Dark Reader's MIT licence is why it could simply be
dropped in; eyeo's GPL is why the filter converter is an independent implementation of a
documented format rather than a port.

**Proxy vs in-engine blocking**, since Zen makes the contrast concrete:

| | Zen (system proxy) | Kestrel (`WKContentRuleList`) |
|---|---|---|
| coverage | every app on the machine | this browser only |
| setup | installs a CA cert for TLS interception | none |
| cosmetic filtering | impossible — never sees the DOM | supported |
| filter syntax | full EasyList | the subset WebKit can express |
| per-tab memory | zero (outside the browser) | approximately zero (compiled in-engine) |
| cost | an always-running process + a network hop | none |

Both beat a JS blocker on the metric DESIGN.md §6 cares about. They are not exclusive — running
Zen alongside Kestrel gets full syntax coverage system-wide *and* in-engine cosmetic filtering.

## Performance notes

**Never read memory on the main thread.** `/usr/bin/footprint` costs ~226 ms per call.
`Tab.currentBytes` returns a cached sample and never spawns anything; `sampleFootprint()`
does the real work and must be called from a background queue. `measureNow()` is the
synchronous version, for headless code where blocking is fine. Reading this wrong dropped
a quarter of frames during scrolling — `kestrel selftest` asserts 1000 reads stay under
50 ms.

**Content rules compile asynchronously.** Tabs created before compilation finishes get no
blocking at all, so startup waits for it and `retrofitBlocker()` attaches newly-compiled
rules to tabs that already exist.

**Third-party-only rules miss first-party ads.** Sites that serve ads from their own
origin (MDN's `/pong/`) are invisible to any rule carrying `load-type: third-party`.
`firstPartyAdPaths` covers those without a load-type restriction.

## Layout

```
Sources/kestrel/
  Tab.swift          the four-state ladder on WKWebView; interactionState is the COLD image
  Scheduler.swift    the policy, ported from ../bench/b4_scheduler/scheduler.py
  MemoryProbe.swift  real per-process footprint via phys_footprint + pid-set diffing
  BrowserApp.swift   the browser UI
  Benchmark.swift    headless policy comparison on real sites
  Probe.swift        per-rung cost measurement
  MemoryBar.swift    the stacked budget bar and tab-strip rows
  ContentBlocker.swift  declarative ad/tracker blocking
  PageFeatures.swift    dark mode, QR codes, userscript engine
  Bitwarden.swift    credential autofill via the bw CLI
  SelfTest.swift     headless checks, including the Bitwarden origin gate
  FilterList.swift   EasyList/uBlock/hosts -> Safari content-blocker JSON
  FilterTest.swift   converter tests, ending in a real WebKit compile
  Bisect.swift       per-rule compile to find what WebKit rejects
  DarkReaderBridge.swift  loads the real Dark Reader library when installed
  DarkTest.swift     end-to-end: does a live page actually go dark
```

## Two things to know before reading the code

**`WKWebView` exposes no process id.** Tabs are created one at a time and their WebContent
process is identified by diffing the pid set before and after. It works and it is the only way,
but it means tab creation is serialised.

**WebKit will not terminate a content process on demand.** Releasing the web view, giving each
tab its own `WKProcessPool`, and navigating away then releasing were all tested; the process
outlived its view by over 110 seconds in every case. So COLD is implemented as *navigate away +
keep the view*, which measured 39 MB against 59 MB for destroying it. The ladder is not
monotonic on this engine, and the scheduler uses measured rung costs rather than assuming an
ordering.
