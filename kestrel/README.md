# Kestrel — a working browser with a memory budget

A macOS browser built on WebKit (`WKWebView`) that implements the four-state tab ladder
from [../DESIGN.md](../DESIGN.md) and enforces a user-settable global memory budget.

What building it actually proved is in [../RESULTS-ENGINE.md](../RESULTS-ENGINE.md); the
bugs that looked correct while being broken are in [../DEBUGGING.md](../DEBUGGING.md), and
what is still broken is in [../BROKEN.md](../BROKEN.md).

## Building and running

```bash
./make_app.sh && open Kestrel.app --args gui
```

**Launch it as the app bundle, not the bare binary.** macOS attributes camera and
microphone permission requests to the *responsible process* — the app that started the
chain — so a binary launched from a terminal or another program asks on that program's
behalf, using that program's name. `open` hands the launch to LaunchServices, which makes
Kestrel its own responsible process. `make_app.sh` also ad-hoc signs with a stable
identifier so TCC grants survive rebuilds.

For the headless modes the bare binary is fine:

```bash
swift build && ./.build/debug/kestrel selftest
```

## The browser

**Tabs** live on the ladder — LIVE, WARM, COLD, STUB — and a scheduler demotes them to
hold the budget, cheapest-regret first. Horizontal tab strip by default, with a coloured
state dot per tab and a spinner while loading; **vertical tabs** (hamburger menu) trade
width for a per-tab readout of state, memory and last restore latency.

**The bottom bar** is the point of the browser: a budget slider, a per-tab cap, a stacked
memory bar segmented by tab state with the budget drawn across it, and a status line that
says explicitly when the budget is *unreachable* rather than silently sitting over it.

**The address bar suggests** as you type, from bookmarks and history ranked by visits over
age. **Import** bookmarks and history from Firefox, Chrome or Safari (hamburger → Import
From). **Protections** (wrench) reports what is guarding the page and, more usefully, *who*
is responsible for each item — WebKit's tracking prevention, Kestrel's own doing, or an
installed add-on — and can clear a site's stored data.

**Reader view** (toolbar, only on article pages) extracts the article and drops navigation,
ads, scripts and web fonts. It is the one feature here that shrinks a tab without demoting
it. **Container tabs** (hamburger → New Container Tab) give a tab its own cookie jar, cache
and storage through `WKWebsiteDataStore(forIdentifier:)` — real partitioning, asserted by
setting a cookie in one container and failing to read it in another. Containers are also the
one thing WebKit's runtime refuses add-ons, so the browser has to provide them.

**Session restore** keeps scroll position and unsent form contents, not just URLs —
`interactionState` carries neither for a parked tab — writes every ten seconds rather than
only at quit, and tells a crash from a clean exit by a flag file. Password fields are never
captured. A tab with something typed into it will not be parked below COLD, which is where
the typing survives; that demotion floor existed in the scheduler from the start and had
nothing setting its flag until now.

**`about:memory`** (wrench menu, or `kestrel://memory`) is the budget as a page: total
against budget, each rung of the ladder with its share, and every tab's footprint, pid,
restore latency and visit count. It re-renders on the browser's own tick and counts itself.

**Network capture is off until you open a panel.** Wrapping `fetch`/`XHR` and observing
every resource costs the page 15–40% more per request — measured, 300 requests — and every
observed resource is an IPC message. A diagnostic that charges its cost to every page whether
or not anyone is looking is the mistake DEBUGGING.md §2 is about.

**The network panel** (⌥⌘E) lists every request with status, method, domain, size and
timing, and shows headers for the ones where headers exist. WKWebView has no request
observer, so it is assembled from three sources and labels each row with which one it came
from: `PerformanceObserver` for engine-fetched subresources (timing and size, no headers),
wrappers around `fetch`/`XMLHttpRequest` for what the page requests itself (full headers,
method, status), and the navigation delegate's `HTTPURLResponse` for the main document. A
row with no headers says so and says why.

**Everyday features:** find in page (⌘F), bookmarks (⌘D), history, session restore,
reopen closed tab (⇧⌘T), zoom (⌘+/−/0), print (⌘P), save page as web archive, a QR code
for the current URL, pop-up handling, and a search-or-navigate address bar.

Everything beyond that — ad blocking, dark mode, userscripts, password autofill,
screenshots — is an add-on, and a real one. Kestrel used to ship imitations of all five;
they were deleted once WebKit's extension runtime made the originals work.

## Firefox add-ons

**They run.** A Firefox add-on is a WebExtension — an `.xpi` is a ZIP with a
`manifest.json` — and since macOS 15.4 WebKit ships the same WebExtensions runtime Safari
uses, available to any `WKWebView` app. Kestrel does not reimplement the extension API: it
unpacks the add-on and hands it to WebKit.

```bash
./.build/debug/kestrel extscan ~/Library/Application\ Support/Firefox/Profiles/*/extensions
```

All 25 add-ons installed in the Firefox profiles on the development machine load, uBlock
Origin, NoScript and Greasemonkey among them.

**Ad blockers are the exception, and it is measured rather than assumed.** No add-on blocks
here, of either manifest version. `kestrel blocktest <add-on>` runs five tracker probes with
a control and a self-check: WebKit grants `webRequestBlocking` without honouring it, and
accepts `declarativeNetRequest` rulesets — `hasContentModificationRules` reports true —
without applying them, including in a web view built from the controller's own
configuration. uBO Lite, Manifest V3 with EasyList enabled, blocked 0 of 5 after three
minutes. A `WKContentRuleList` compiled by the browser blocks the same probe every time,
which is what makes the result trustworthy and also names the only mechanism that works.
See [../BROKEN.md](../BROKEN.md) #7. What does *not* survive is the Gecko-only
surface — sidebars, themes, container tabs, the `downloads`/`history`/`privacy` APIs — so
each add-on is checked against that list and told to you **before** you enable it, along
with the permissions it wants. Nothing is granted without that dialog.

Add-ons cost memory the ladder cannot reclaim, and `kestrel extmem` measures it: the eight
add-ons in the current Firefox profile add **244 MB** to a 50 MB browser, because a
background page belongs to no tab and cannot be parked. That is a floor the budget has to
account for.

## Developer tools

**Right-click a page → Inspect** opens a panel docked under it, in the shape Firefox uses,
with three tabs:

- **Inspector** — the DOM as a tree, the selected element's box, attributes and computed
  styles, a breadcrumb, and a highlight drawn over the element in the page. Right-clicking
  selects what was under the cursor: the page records the target on `contextmenu`, because
  by the time the menu item fires the cursor has moved.
- **Network** — the request list from `NetworkMonitor`, with headers where headers exist.
- **Memory** — the budget and every tab's footprint, live.

None of the three is a `WKWebView`. Firefox's devtools are themselves a web page; spending a
web content process on the tool that reports web content processes would be a poor joke in a
browser with a memory budget. The panel takes its height off the page rather than floating
over it, and the top edge drags.

## Developer tools (windows)

Behind the wrench, in the shape Firefox uses: **Task Manager** (per-tab state, memory,
process id, restore latency), Browser Console, Web Inspector, Responsive Design Mode,
Eyedropper, Page Source.

## Headless modes

Every mode below is a real check, not a smoke test.

| mode | what it does |
|---|---|
| `sessiontest` | Container cookie isolation, reader extraction, and: fills a form, parks the tab COLD, brings it back, and asserts the values return — plus the password is never stored, the memory page's numbers come from the scheduler, and a recorded request's headers are real |
| `exttest` | Builds a Firefox add-on, packs it as an `.xpi`, installs it, and asserts its content script ran in a page and its background script answered |
| `extscan <dirs>` | Hands every `.xpi` in a directory to WebKit and reports which load and what each loses |
| `blocktest <add-on>` | Five tracker probes with a control run and a self-check, to answer whether an ad blocker actually blocks — nothing in the extension API reports it |
| `extdiag <add-on> [url]` | What an add-on actually got: granted permissions, host access, background load, content rules, options page structure, and the UA its pages see |
| `extmem <dirs>` | Measures what each add-on costs, one at a time, with background pages forced to run |
| `selftest` | Tab switching, memory-read cost, the new tab page's identity, QR encoding, spinner state, user agent, layout preference |
| `layouttest [dir] [dark]` | Builds the add-ons popover, the browser window at two sizes, both tab layouts and the find bar, and fails on any control that escapes its parent, overlaps a sibling, or is narrower than its own title. Given a directory it also writes a PNG of the popover, so it can be reviewed without clicking through the running browser |
| `probe` | Spawns *n* tabs, maps each to its WebContent process, drives one through the ladder and reports what each rung costs |
| `bench <urls> <budgetMB> <policy> <events>` | Loads real sites and replays an access trace under `none` / `discardlru` / `kestrel` |

```bash
./run_bench.sh 800 40 urls_heavy.txt
```

One policy per process invocation, deliberately: WebKit keeps released WebContent
processes alive for minutes, so two policies in one process would contaminate each other.

## Things worth knowing before reading the code

**`WKWebView` exposes no *public* process id — but it does expose one.** This file used to
say diffing `ps` around tab creation "works, and it is the only way". Both halves were
wrong. It does not reliably work: WebKit spawns several content processes at once, the diff
picks one arbitrarily, and the tab reports that figure for good — a browser was seen
reporting 52 MB for a page whose process held 511 MB. And it is not the only way:
`_webProcessIdentifier` answers directly. That is private API, and using it is a deliberate
trade — this is a research browser whose entire subject is memory, and a guessed pid makes
every per-tab number unfalsifiable. It is called through `responds(to:)` with `nil` on
anything unexpected, and the diffing path remains as a fallback.

**Per-tab attribution is exact only while a web view exists.** A COLD or STUB tab has no
view to ask, and WebKit keeps its process alive after the view is gone, so that memory
belongs to no tab. The browser's **total** is therefore measured separately — every
WebContent process younger than the browser, summed — which needs no attribution and cannot
miss a process it never guessed about. Where the two disagree by more than 20%, the status
line says so.

**WebKit will not terminate a content process on demand.** Releasing the view, per-tab
`WKProcessPool`, and navigate-away-then-release were all tested; the process outlived its
view by over 110 seconds every time. COLD is therefore *navigate away and keep the view*,
which measured 39 MB against 59 MB for destroying it. **The ladder is not monotonic** —
STUB costs more than COLD — so the scheduler uses measured rung costs rather than assuming
an ordering.

**Never read memory on the main thread.** `/usr/bin/footprint` costs ~226 ms per call.
`Tab.currentBytes` returns a cached sample and never spawns; `sampleFootprint()` does the
real work off-main. Getting this wrong dropped a quarter of frames while scrolling, and
`selftest` asserts 1000 reads stay under 50 ms.

**An extension's background page is not a tab.** It has no place on the ladder, cannot be
demoted without breaking the add-on, and so raises the floor rather than competing for the
budget. Measure it with `extmem` before setting a budget on a machine with add-ons.

## Layout

```
Sources/kestrel/
  Tab.swift              the four-state ladder; interactionState is the COLD image
  Scheduler.swift        the policy, ported from ../bench/b4_scheduler/scheduler.py
  MemoryProbe.swift      per-process footprint via phys_footprint + pid-set diffing
  BrowserApp.swift       the browser: layout, tabs, navigation, menus
  TabStrip.swift         horizontal tab strip with state dots and load spinner
  MemoryBar.swift        the stacked budget bar and vertical tab rows
  URLBar.swift           address pill: security indicator, progress, QR, bookmark
  NewTabPage.swift       new tab page and the search-or-navigate rule
  QRCode.swift           QR code for the current URL
  UrlBarSuggestions.swift history and bookmarks under the address bar
  Migration.swift        import from Firefox, Chrome, Safari
  Protections.swift      what is guarding the page, and who owns it
  ReaderView.swift       article extraction and the reader document
  Containers.swift       per-container cookie jars
  SessionStore.swift     scroll/form capture, restore, crash detection
  AboutMemory.swift      kestrel://memory, rendered from the scheduler
  NetworkMonitor.swift   request capture from three partial sources
  NetworkWindow.swift    the request list and header view
  AddonsPopover.swift    the installed add-ons list
  AddonStyle.swift       the one shared control it still needs
  DevTools.swift         task manager, console, page source, responsive mode
  Store.swift            bookmarks, history, session
  Prefs.swift            persisted settings
  FindBar.swift          find in page
  UserAgent.swift        the Safari product token WKWebView omits
  Extensions.swift       .xpi install, the WKWebExtension runtime, permissions
  ExtensionBridge.swift  Kestrel's tabs and window, described to that runtime
  ExtensionToolbar.swift add-on buttons, popups, the permission dialog
  ExtensionWeb.swift     installing from addons.mozilla.org
  *Test.swift, Diag/AB   the headless checks and diagnostics above
```
