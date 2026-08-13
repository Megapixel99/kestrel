# Open problems

*Last swept 2026-08-13. Items 1–3 were fixed in that pass; 4–6 are limits or debts, not
defects.*

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

## Fixed, for contrast

Recent things that *were* broken and are not, in case a symptom looks familiar:
tab switching, scroll jank, the ad blocker's first-party rules, the new tab page's identity,
Google Meet's UA, camera/mic permission, TCC attribution, add-on options pages loading blank,
the layout test moving the tab strip, the network panel's empty header pane. All in
DEBUGGING.md with the reasoning.
