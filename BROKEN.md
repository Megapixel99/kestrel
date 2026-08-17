# Open problems

*Last swept 2026-08-16. Items 1–3 and 9 were fixed in earlier passes; 4–6 are limits or
debts, not defects; 10 is a real defect found by re-measuring the benchmarks.*

What is broken, what has already been ruled out, and where to start. DEBUGGING.md is the
record of bugs that were *fixed*; this is the list that is still open, written so picking one
up does not mean repeating the elimination work.

Each entry gives a repro, the evidence, and the next thing worth trying. Anything marked
**eliminated** has been tested directly — don't re-test it without a reason.

---

## ~~1. Dark Reader does not theme pages~~ — FIXED

## ~~2. Adblock Plus and Bitwarden~~ — same cause, FIXED

**One bug, three symptoms.** `ExtensionRuntime.apply(to:)` refused to attach the extension
controller to a web view when no add-on had loaded *yet* — and a web view's controller
cannot be set after creation. The browser creates its first tab before `startExtensions()`
runs, so that tab could never run a content script for the rest of its life, and neither
could any tab already open when an add-on was installed.

Every add-on then failed in whatever way it happens to express "I cannot reach the page":

- Dark Reader called it a protected page (`canAccessTab()` false, because no content script
  ever announced itself)
- Adblock Plus blocked nothing
- Bitwarden matched no site

After the one-line fix, on the same page that had produced nothing for weeks:

    in the page: 8 darkreader styles, background rgb(24, 26, 27)

**This is DEBUGGING.md §3 a second time.** That entry reads: "Tabs created before
compilation finishes get no blocking at all." Same shape, same file, different subsystem —
an asynchronous subsystem attached at web-view creation, and a web view created before it
was ready. The guard that caused it was a micro-optimisation: don't attach a controller
nobody is using. An empty controller costs nothing.

`exttest` now creates the window and its tab **before** loading the add-on, which is the
order the browser actually uses, and nine of its checks fail if the guard comes back.

Everything eliminated while chasing this — `sender.tab.id`, both messaging directions,
ports, `tabs.query`, permissions, background load, manifest parse — was eliminated
correctly. All of it worked. None of it was reachable, because there was no content script
in the tab to use it.

The `world: MAIN` lead in Dark Reader's manifest was a red herring: a two-entry probe
add-on shows both `MAIN` and `ISOLATED` content scripts run.

---

## ~~3. Add-on popups are unverified~~ — now covered

`exttest`'s add-on declares a `browser_action` popup, and the test asserts the popup's own
HTML rendered and that it reaches a usable size. `WKWebExtension.Action.popupWebView` is
reachable without a click, so what looked like it needed a real window did not.

---

## 7. No add-on can block ads in Kestrel, of either manifest version

**Severity:** high, and it looks like a platform limit rather than a bug here.

**Repro**

```bash
cd kestrel && ./.build/debug/kestrel blocktest ubolite 45
```

**Measured, with a control and a self-check.**

| | | |
|---|---|---|
| MV2 blocking `webRequest` | test add-on returns `{cancel:true}` | **request went through** |
| MV3 `declarativeNetRequest` (uBO Lite, 6 enabled rulesets incl. EasyList) | 5 tracker probes | **0 of 5 blocked** |
| …after 180 s for rule compilation | same | **0 of 5 blocked** |
| …in a web view from the controller's own configuration | same | **loaded** |
| `WKContentRuleList` compiled by Kestrel itself | same probe | **blocked** |

The last row is the self-check, and it is what makes the rest trustworthy: the probe detects
blocking that is definitely happening, so "loaded" means the request really was not blocked.

WebKit **grants** `webRequestBlocking` without honouring it, and **accepts**
declarativeNetRequest rulesets — `hasContentModificationRules` reports `true` — without
applying them to any web view reachable through the public API, including one built from
`WKWebExtensionController.Configuration.webViewConfiguration`.

**Corrections to earlier claims in this file.** I previously wrote that MV2 was the problem
and an MV3 blocker was the fix. That was wrong, stated twice, and with more confidence than
the evidence supported. The manifest version is not the discriminator.

**What has not been ruled out**

- WebKit may honour only *dynamic* rules (`declarativeNetRequest.updateDynamicRules`) and
  not manifest-declared static rulesets. A test add-on that adds one dynamic rule for a
  known URL would settle it, and is the obvious next experiment.
- Safari implements this through its own content-blocker plumbing, which a host app may not
  inherit. If so this is unfixable from here and should be recorded as such.

**What does work, and it is worth stating plainly:** `WKContentRuleList` compiled by the
browser blocks reliably — the self-check proves it every run. That is precisely the
mechanism the deleted built-in ad blocker used. Restoring a native content blocker
(Adblock-Plus-list → WKContentRuleList conversion, which `FilterList.swift` did) is the only
demonstrated way to block ads in this browser. Deleting it removed the one thing that worked.

---

## 8. Adblock Plus's own UI refuses to render for a browser it does not recognise

**Severity:** low, and it is ABP's constraint rather than Kestrel's.

**Fixed on this side:** the page used to come up blank. ABP's options page is a shell whose
only content is an iframe of `desktop-options.html`, and WebKit refuses that subframe unless
the add-on declared `web_accessible_resources` — stricter than Firefox or Chrome, and ABP
declares none. The tab now navigates to the inner page itself when a lone iframe fails, so
the content loads with nothing loosened: no manifest rewriting, nothing of the add-on's made
readable by arbitrary web pages.

The check has to be repeated, not made once: at `didFinish` the iframe carries only
`data-src`, because ABP's `options.js` is deferred and sets the real `src` a beat later.

**What remains, measured:**

    options page in a tab: …/desktop-options.html  nodes=8
      getBrowserInfo=undefined
      ua=Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:141.0) Gecko/20100101 Firefox/141.0
      text=Your browser version is no longer supported. Please upgrade

The page renders and then refuses. It is not the user agent — that is now a clean Firefox
string with no AppleWebKit prefix, set through `customUserAgent` on the web view Kestrel
creates. It is `browser.runtime.getBrowserInfo`, which is **undefined**: a Firefox-specific
API WebKit's runtime does not implement, so ABP has no version to compare and defaults to
unsupported.

**Where to start, if it is worth it:** `getBrowserInfo` could be shimmed by injecting a
small script into add-on pages that defines it. That is spoofing an API the engine does not
have, on the add-on's behalf, and it would need to be weighed rather than done casually —
an add-on told it is Firefox 141 may then take other Gecko-only paths that fail less
visibly than this one does.

**uBO Lite is unaffected** — its dashboard is a page rather than a frame shell and renders
normally, so the fixes here cost it nothing.

---

## ~~9. Per-tab memory attribution is unreliable~~ — fixed, with one residual limit

**Severity:** high, and it reaches further than the browser's UI.

**How it was found.** Two screen recordings. In the first, a Jira board read `0 MB`. In the
second, the status line read `52 MB` before *and after* loading Jira — the same figure on two
completely different pages. Weighing the processes while that session was still running:

    38183  113 MB   17:00:47   Kestrel's own, spawned at launch
    38589  511 MB   17:01:08   spawned when Jira was opened
    36795   52 MB   Aug 6      another application entirely

The browser was reporting a **different app's** process, and never saw the 511 MB one
rendering the page.

**Two causes.**

1. `ps` lists every WebContent process on the machine. They are launchd-parented XPC
   services with identical command lines, so there is no parent and no client tag to filter
   on. The only sound discriminator is **age**: a process older than the browser cannot be
   its. Nothing filtered on it.
2. `Tab.makeLive` claimed its process with `after.subtracting(before).first` — and WebKit
   spawns **several at once**, five on one measured launch. `.first` on an unordered set is
   an arbitrary pick among them. Whichever it grabbed, it reported for the tab's lifetime.

**Fixed:** foreign processes excluded by age; the process list re-diffed after each
navigation, because WebKit keeps the old process alive and it keeps answering; and the
browser's **total** measured directly by summing its own processes, which needs no
attribution and so cannot be wrong in the way attribution is. When the attributed and
measured totals disagree by more than 20% the status line says so in red.

The gap is real and large. In the test harness:

    the browser measures its own total footprint — 283 MB measured, 62 MB attributed

**What this calls into question.** Every per-tab figure this project has published rests on
that attribution step, including the rung costs in RESULTS-ENGINE.md (LIVE 128 MB, WARM
106 MB, COLD 39 MB). `probe` drives one tab at a time, which makes its diff far more likely
to have been correct, so those numbers are probably sound — but *probably* is the honest
word and they should be re-measured against the summed total before being quoted again.

**Fixed 2026-08-14.** `WKWebView._webProcessIdentifier` answers directly — private API,
verified working on macOS 15.5 (pid resolves, process is live, footprint 92 MB). Used at
every point a tab's process is established, with `ps` diffing as fallback. In the test
harness the attributed total went from 36% of the real footprint to 80%.

**Residual limit, and it is structural:** attribution is exact only while a web view
exists. A COLD or STUB tab has no view to ask, and WebKit keeps its process alive after the
view is released, so that memory belongs to no tab. This is why the whole-browser total is
measured separately rather than summed from tabs — and why the benchmark correction above
matters: a per-tab sum necessarily undercounts once anything is demoted.

---

## ~~9b. A tab's memory can become unmeasurable~~ — superseded by the above

**Severity:** high — the budget is computed from these numbers.

**How it showed up.** A 58-second screen recording of one tab walking from home.apu.edu
through id.atlassian.com to a Jira board. The readout over that span:

    37 MB → 399 → 159 → 160 → 115 → … → 0 MB

with a full Kanban board rendering and the memory bar empty.

**What was wrong regardless of cause:** "cannot measure this tab" and "this tab costs
nothing" both rendered as `0 MB`. The scheduler treated an unmeasurable live page as free —
never counted, never a demotion candidate. A browser whose claim is that memory scales with
what you are looking at was silently not looking. `Tab.footprintKnown` now separates the two,
and the status line, `about:memory` and the dev panel all show `?` / `UNMEASURED` rather than
a plausible zero.

**What is fixed:** a tab whose recorded process has died no longer keeps the stale pid. Where
exactly one orphaned tab meets exactly one unclaimed WebContent process, it is reclaimed.

**What is deliberately not done:** reclaiming beyond that unambiguous case. An earlier
version assigned "the largest unclaimed process to the foreground tab" and, in the test,
moved a tab reporting 29 MB onto a 13 MB process belonging to something else. In a budget a
confident wrong number is worse than an admitted gap, because it gets acted on.

**Still unknown: which zero path the recording hit.** Two produce it and they were
indistinguishable — `isAlive(pid)` false, or `/usr/bin/footprint` failing for a live pid. My
first diagnosis, process-swap-on-cross-site-navigation, **did not reproduce**: navigating
example.com → apple.com kept the same pid, which is consistent with Kestrel giving each tab
its own `WKProcessPool`. Recorded here because it was stated confidently before being tested.

**Where to start:** reproduce with the browser running and watch for `UNMEASURED`. If it
appears, `MemoryProbe.isAlive` versus a failing `footprint` call can now be told apart by
whether a pid is present. `probe` mode drives the ladder against real sites and is the
natural place to add a long-running navigation walk.

---

## 4. Network panel: `timing` rows have no headers

**Severity:** none — a documented limit of the platform, listed here so it is not
rediscovered as a bug.

WKWebView exposes no request observer. Headers exist only where something hands them over:
`fetch` and `XMLHttpRequest`, through wrappers Kestrel injects, and the main document, whose
`HTTPURLResponse` arrives in the navigation delegate. A script, stylesheet, font or image
fetched by the engine itself is visible to `PerformanceObserver` — where its size and timing
come from — and its headers are not observable. Rows are labelled with their source, and the
detail pane explains the gap rather than showing an empty table.

**Only fix worth having** would be routing all traffic through a `WKURLSchemeHandler` or a
local proxy, i.e. becoming the network stack. That is a large change with real correctness
risk (HSTS, cookies, HTTP/2, caching) for a devtools nicety.

---

## 5. No add-on can influence the scheduler

**Severity:** by design, recorded because the design once claimed otherwise.

The deleted built-in tab reloader had a demotion floor pinning an auto-refreshing tab to
LIVE. The Tab Reloader *add-on* reloads through `browser.tabs.reload()`, which the scheduler
reads as an ordinary visit. There is no mechanism for an add-on to request a floor, and no
API in WebKit's runtime that would surface the intent.

DESIGN.md §2's per-reason floors are now: audible → LIVE, pinned → WARM, unsubmitted input →
COLD. The refresh floor is gone.

---

## 6. DESIGN.md §6's ad blocker measurement has no code behind it

**Severity:** documentation integrity.

The declarative ad blocker was cited as a measured architectural result — content rules
compiled into WebKit cost approximately nothing per tab — and it was deleted along with the
other five built-ins. The measurement stands; the code that produced it does not. §6 is
annotated in place, and `extmem` measures what an installed add-on costs instead, but a
reader following the design's argument will hit a claim whose implementation is gone.

---

## 10. The scheduler thrashes against a budget it can prove is unreachable

**Severity:** real, and it makes the browser worse than having no scheduler at all.

The feasibility floor is `budget > live working set + (39 MB × parked tabs)`. Nothing enforces
it. Give the scheduler 11 tabs and a 150 MB budget — 2.9× below the 429 MB those tabs need at
the COLD rung — and it demotes 45 times over 40 events, restores 18, and lands at **345.9 MB
measured against 255.3 MB for doing nothing** (discard-LRU: 414.8 MB). Each demotion strands a
WebContent process WebKit keeps alive; each restore spawns a fresh one; the churn costs more
than the parked pages save.

The scheduler already detects it — `gave_up` fires 7 times in that run — and then carries on
demoting anyway. What it should do instead: compute the floor from the tab count, and when the
budget is below it, stop demoting and say so in the UI ("this budget can hold 3 tabs"). A
browser that can prove its target is unreachable should refuse the target rather than thrash
at it.

Measured in `results/engine/bench_*.txt`; written up at the end of RESULTS-ENGINE.md.

---

## Fixed, for contrast

Recent things that *were* broken and are not, in case a symptom looks familiar:
tab switching, scroll jank, the ad blocker's first-party rules, the new tab page's identity,
Google Meet's UA, camera/mic permission, TCC attribution, add-on options pages loading blank,
the layout test moving the tab strip, the network panel's empty header pane. All in
DEBUGGING.md with the reasoning.
