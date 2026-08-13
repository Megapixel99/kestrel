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
reopen closed tab (⇧⌘T), zoom (⌘+/−/0), print (⌘P), save page as web archive, pop-up
handling, and a search-or-navigate address bar.

## Add-ons

The puzzle icon opens a popover listing Kestrel's built-in features in the shape browsers
use for extensions. They are not installable extensions and the UI says so — there is no
extension runtime here.

| | |
|---|---|
| **Ad blocker** | Declarative `WKContentRuleList`, per-site toggle. Compiled into WebKit rather than run in JavaScript, so it costs ~nothing per tab — the choice DESIGN.md §6 argues for. Point `~/.kestrel/filters.txt` at an Adblock Plus list to extend it. |
| **Dark Reader** | Uses the real library (MIT) when installed, with brightness/contrast/sepia/grayscale and a **site exclusion list**, falling back to a CSS invert when not. |
| **Userscripts** | Tampermonkey-shaped: `~/.kestrel/userscripts/*.user.js` with `@name`, `@match`, `@run-at`, plus a dashboard with enable toggles. |
| **Bitwarden** | Autofill via the official `bw` CLI, and a password generator using `SecRandomCopyBytes` with rejection sampling. |
| **Tab Reloader** | Per-tab auto-refresh. A refreshing tab is pinned LIVE by the scheduler and pays full price — the one feature here that *costs* memory. |
| **Screenshot** | Entire page, visible area, region, element, or PDF, opening in an annotation editor. |

### Screenshot capture

Full-page capture flattens sticky headers before the descent, primes lazy images and
re-measures, and **scales down anything over 80 megapixels rather than allocating it** — a
50,000 px page at 2× would be ~1.6 GB of RGBA. The editor has box/ellipse/arrow/line/pen/
text/step/highlight/blur/pixelate/redact, crop, undo/redo, and header/footer/watermark
templates. Annotations stay vector until export, so undo is exact; blur and pixelate
genuinely resample through Core Image, because an overlay you can peel off is not
redaction.

### Bitwarden setup

```bash
brew install bitwarden-cli && bw login
export BW_SESSION="$(bw unlock --raw)"
./make_app.sh && open Kestrel.app --args gui   # same shell
```

The master password never reaches Kestrel; the session key goes to `bw` through the child
environment rather than argv, so it stays out of `ps`; nothing is persisted; a credential
is only offered when the page's domain matches the URI on the vault item, over HTTPS, and
only when asked; and filling never submits the form.

## Developer tools

Behind the wrench, in the shape Firefox uses: **Task Manager** (per-tab state, memory,
process id, restore latency), Browser Console, Web Inspector, Responsive Design Mode,
Eyedropper, Page Source.

## Headless modes

Every mode below is a real check, not a smoke test.

| mode | what it does |
|---|---|
| `selftest` | ~40 assertions: blocklist, userscript parsing, dark mode, QR, tab switching, prefs, password generator, user agent, per-site exclusions |
| `layouttest [dir] [dark]` | Builds 16 layouts — every add-ons pane, both tab layouts, the screenshot editor, the userscript dashboard, the find bar — and fails on any control that escapes its parent, overlaps a sibling, or is narrower than its own title. Given a directory it also writes a PNG of every add-ons pane, so they can be reviewed without clicking through the running browser |
| `probe` | Spawns *n* tabs, maps each to its WebContent process, drives one through the ladder and reports what each rung costs |
| `bench <urls> <budgetMB> <policy> <events>` | Loads real sites and replays an access trace under `none` / `discardlru` / `kestrel` |
| `shottest` | Full-page capture against a page with a sticky header, asserting it appears once rather than once per band |
| `adblocktest` | Loads a page and asserts specific requests actually fail, including a first-party ad path |
| `darktest` | Asserts a live page's computed background actually goes dark |
| `filters` | Converts an Adblock Plus list and makes WebKit compile the result |
| `bisect [path]` | Compiles each converted rule alone to find exactly which one WebKit rejects |
| `diag <url>` | Loads a page in four configurations (clean / dark / blocker / both) and attributes differences |
| `overlap <url>` | Detects overlapping text blocks across the same four configurations |
| `darkab <url>` | A/B tests Dark Reader timing strategies on one page |
| `darkpath` | Reports which dark-mode path actually ran on a real load |

```bash
./run_bench.sh 800 40 urls_heavy.txt
```

One policy per process invocation, deliberately: WebKit keeps released WebContent
processes alive for minutes, so two policies in one process would contaminate each other.

The last four exist because three separate bug reports turned out to need attribution
rather than guesswork — and two of them exonerated Kestrel. See DEBUGGING.md §7.

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

**Content rules compile asynchronously.** Tabs created before compilation finishes get no
blocking at all, so startup waits and `retrofitBlocker()` attaches rules to existing tabs.

**Third-party-only rules miss first-party ads.** Sites serving ads from their own origin
(MDN's `/pong/`) are invisible to any rule carrying `load-type: third-party`.

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
  ContentBlocker.swift   declarative ad/tracker blocking
  FilterList.swift       Adblock Plus -> WebKit rule conversion
  DarkReaderBridge.swift real Dark Reader when installed, CSS invert when not
  PageFeatures.swift     dark mode fallback, QR codes, userscript engine
  Bitwarden.swift        credential autofill via the bw CLI
  PasswordGenerator.swift
  Screenshot.swift       capture engine: visible, full page, element, PDF
  ScreenshotEditor.swift annotation model and canvas
  EditorWindow.swift     the editor's toolbar and export
  AddonsPopover.swift    the add-ons list and detail panes
  AddonStyle.swift       shared components for those panes
  BarSlider.swift        the filled-bar slider Dark Reader uses
  DevTools.swift         task manager, console, page source, responsive mode
  Store.swift            bookmarks, history, session
  Prefs.swift            persisted settings
  FindBar.swift          find in page
  ScriptManager.swift    userscript dashboard
  UserAgent.swift        the Safari product token WKWebView omits
  *Test.swift, Diag/AB   the headless checks and diagnostics above
```
