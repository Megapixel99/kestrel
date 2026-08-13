# Kestrel — a working browser with a memory budget

A macOS browser built on WebKit (`WKWebView`) that implements the four-state tab ladder
from [../DESIGN.md](../DESIGN.md) and enforces a user-settable global memory budget.

What building it actually proved is in [../RESULTS-ENGINE.md](../RESULTS-ENGINE.md); the
bugs that looked correct while being broken are in [../DEBUGGING.md](../DEBUGGING.md).

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
Origin, NoScript and Greasemonkey among them. What does *not* survive is the Gecko-only
surface — sidebars, themes, container tabs, the `downloads`/`history`/`privacy` APIs — so
each add-on is checked against that list and told to you **before** you enable it, along
with the permissions it wants. Nothing is granted without that dialog.

Add-ons cost memory the ladder cannot reclaim, and `kestrel extmem` measures it: the eight
add-ons in the current Firefox profile add **244 MB** to a 50 MB browser, because a
background page belongs to no tab and cannot be parked. That is a floor the budget has to
account for.

## Developer tools

Behind the wrench, in the shape Firefox uses: **Task Manager** (per-tab state, memory,
process id, restore latency), Browser Console, Web Inspector, Responsive Design Mode,
Eyedropper, Page Source.

## Headless modes

Every mode below is a real check, not a smoke test.

| mode | what it does |
|---|---|
| `exttest` | Builds a Firefox add-on, packs it as an `.xpi`, installs it, and asserts its content script ran in a page and its background script answered |
| `extscan <dirs>` | Hands every `.xpi` in a directory to WebKit and reports which load and what each loses |
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

**`WKWebView` exposes no process id.** Tabs are created one at a time and their WebContent
process is identified by diffing the pid set. It works, and it is the only way.

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
