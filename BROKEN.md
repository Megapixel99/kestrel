# Open problems

What is broken, what has already been ruled out, and where to start. DEBUGGING.md is the
record of bugs that were *fixed*; this is the list that is still open, written so picking one
up does not mean repeating the elimination work.

Each entry gives a repro, the evidence, and the next thing worth trying. Anything marked
**eliminated** has been tested directly — don't re-test it without a reason.

---

## 1. Dark Reader does not theme pages — "This page is protected by browser"

**Severity:** high. It is the most-used add-on installed, and the symptom looks like a
browser fault rather than an add-on one.

**Repro**

```bash
cd kestrel && ./.build/debug/kestrel extdiag darkreader https://example.com/
```

Or in the GUI: load any https page, open Dark Reader's popup. The page stays light and the
popup reports the page as protected.

**Evidence**

```
granted API perms:   alarms, contextMenus, storage, tabs, theme
granted patterns:    *://*/*
access to all hosts: true        injects into this page: true
background: loaded               manifest errors: none    runtime errors: none
in the page: 0 darkreader styles, background rgba(0,0,0,0), filter none
```

Everything it asked for was granted, its background page loads, WebKit reports no manifest
or runtime error — and nothing reaches the page.

**Eliminated** (all tested against a purpose-built add-on in `exttest`, all passing):

| | |
|---|---|
| content script injection at `document_start` | runs |
| content → background `sendMessage` | replies |
| `sender.tab.id` / `.url` / `frameId` / `documentId` | `tab=true id=28 url=https://example.com/ frame=0 doc=yes` |
| background → content `tabs.sendMessage` | received |
| `runtime.connect` long-lived ports | acked |
| `tabs.query()`, including tabs opened after load | sees both |
| permissions, host patterns, background load, manifest parse | clean |

`sender.tab.id` matters most: Dark Reader's `canAccessTab()` is literally
`Boolean(TabManager.tabs[tab.id])`, populated only from that field, and
`isProtected = !tab.isInjected || tab.isProtected` is the code path printing the message.
The input is present and correct.

**Fixed along the way, did not resolve it:** extension pages were getting WKWebView's
truncated user agent with no product token at all — no Firefox, no Safari, no Chrome. Firefox
add-ons branch on the browser they think they are running in, and Dark Reader's
`canInjectScript()` has no branch for "unknown". Now `… Gecko/20100101 Firefox/141.0`
(`UserAgent.extensionApplicationName`, commit `419a906`).

**Where to start next**

1. Its manifest is an MV2 manifest carrying `"world": "MAIN"` on the first content script —
   a Chrome/MV3 key. WebKit reports no manifest error, and the API does not expose whether
   that entry executes. Build a two-entry content-script test add-on, one `MAIN` and one
   `ISOLATED`, and find out whether an unrecognised `world` value invalidates the sibling
   entry.
2. `ctx.isInspectable` is already true. Attaching Safari's Web Inspector to the add-on's
   background page would show its own console, which is the fastest route to what it thinks
   is wrong — and is the one avenue not yet tried, because it cannot be driven headlessly.
3. Compare against a second theming add-on. If one works, diff the manifests rather than
   the code.

**Files:** `Extensions.swift`, `ExtensionBridge.swift`, `ExtensionDiag.swift`,
`ExtensionTest.swift`.

---

## 2. Adblock Plus and Bitwarden "seem to have issues"

**Severity:** unknown — no specific symptom was ever captured.

Reported alongside #1 and assumed to share a cause. **That assumption is untested.** Both
load cleanly and both were granted everything they declared.

**Where to start:** get one concrete symptom each (an ad that should have been blocked and
was not; a site where the vault finds no match) before assuming anything. `extdiag
adblock_plus <url>` and `extdiag bitwarden <url>` print the same attribution table as #1.

Note that Adblock Plus declares `webRequest` and `webRequestBlocking`, which are MV2 blocking
APIs. Whether WebKit's runtime implements blocking `webRequest` at all is not something
`extdiag` currently reports, and it is the obvious first question for that one.

---

## 3. Add-on popups are unverified, not known-good

**Severity:** low, but it is a coverage gap rather than a bug.

Every other part of the add-on path has a headless check. The popup — WebKit rendering an
add-on's own HTML into an `NSPopover` — has none, because it needs a real window and a real
click. If a popup renders wrongly, nothing in the test suite will say so.

**Where to start:** `WKWebExtension.Action.popupWebView` is reachable headlessly (the UA probe
in `ExtensionDiag` already evaluates JavaScript in it). A check could assert the popup's
document reaches a non-empty `body` and a plausible size, which would catch a blank or
collapsed popup without needing a click.

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
