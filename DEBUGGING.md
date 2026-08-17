# What went wrong, and why it looked right

[RESULTS.md](RESULTS.md) and [RESULTS-ENGINE.md](RESULTS-ENGINE.md) record where the
*design* was wrong. This file records where the *implementation* was wrong — the bugs
that looked correct while being broken, and what actually distinguished them.

Kept because the failures were more instructive than the successes, and because a clean
summary written afterwards loses exactly the part worth having: what the wrong
explanation was, and what evidence killed it.

---

## 1. Tab switching silently stopped working

**Symptom.** Clicking a tab did nothing. A screen recording showed five switches in the
first seven seconds, then the screen **frozen for 6.25 s and then 14.5 s** — two-thirds
of a thirty-second recording with no pixel changing.

**Why it looked right.** `promote(to:in:)` opens with `guard target > state`. Reasonable:
don't promote a tab that is already at or above the target. And it worked at first.

**Actual cause.** Only the foreground tab stays in the view hierarchy. Switching to a tab
that was still `LIVE` — merely detached — meant `target == state`, so `promote` returned
immediately and never re-attached the web view. The early switches worked because those
tabs were still being promoted from `STUB`, where the guard passes.

**Fix.** A separate `ensureAttached(to:)` that re-attaches regardless of state.

**Lesson.** A state machine's transition function is the wrong place to put a view-
hierarchy side effect. The two have different trigger conditions.

**Second bug hiding behind the first.** The restore placeholder only hid on `didFinish`,
which never fires for an already-loaded tab, so it covered the content permanently. Fixed
by clearing it explicitly whenever no load is coming.

---

## 2. Scrolling stuttered because the memory instrumentation was the problem

**Symptom.** "Scrolling seems clunky." The recording measured it: during a ten-second
scroll, **25% of frames were pixel-identical** to their predecessor. One frame in four,
dropped.

**Why it looked right.** `Tab.currentBytes` returned a real, current measurement. Correct
by construction.

**Actual cause.** It shelled out to `/usr/bin/footprint`, at **226 ms per call**, on every
read. The scheduler's budget loop, the status bar, and each tab row all read it — roughly
eight times per 1.5-second UI tick. That is **~1.8 s of main-thread blocking per 1.5 s of
wall clock.** It did not present as a hang because WebKit composites pages in their own
process, so the page kept scrolling — badly.

**Fix.** Sample on a background queue; the UI reads a cache. Measured after: **1000 reads
in 0.13 ms**. A regression test asserts reads stay free.

**Lesson.** This is the same error as §1 of RESULTS.md in a new place. There, tier-down
optimised `about:memory` while returning nothing to the OS — the wrong number, measured
well. Here, **the act of measuring was itself the largest cost in the system.** A memory
manager that stalls the UI to find out how much memory it is using has already spent more
than it can save.

---

## 3. The ad blocker compiled 58 rules and blocked nothing

**Symptom.** Ads visible on MDN with the blocker reporting rules active.

**Two independent causes**, which is why fixing one changed nothing.

**(a) A startup race.** `ContentBlocker.compile` is asynchronous. `openTab()` ran
synchronously right after it was *initiated*, so the starter tabs were created with **no
rule list attached at all**. Tabs opened later were fine — a nasty failure mode, because
casual testing opens a new tab and sees blocking work.

**(b) Third-party-only rules cannot see first-party ads.** Every rule carried
`"load-type": ["third-party"]`. MDN serves its ads from its own origin via `/pong/`.
Same-origin requests sail straight past. This is a deliberate anti-adblock design, and no
amount of host blocking touches it.

**Fix.** Wait for compilation before opening tabs, retrofit rules onto existing tabs, and
add first-party path rules with no load-type restriction.

**Lesson.** A test that only checked "the JSON compiles" passed throughout. The
end-to-end test that caught it loads a page and asserts specific requests actually fail.

---

## 4. The new tab page became the tab's identity

**Symptom.** New tabs titled `data:text/html;charset=utf-8,%3C...`.

**Cause.** The page was a `data:` URL, so the entire percent-encoded document *was* the
tab's URL, and leaked into the title and address bar.

**Fix.** A `kestrel://newtab` sentinel, with the page loaded via `loadHTMLString`.

**The fix caused the next bug.** `loadHTMLString(html, baseURL: nil)` gives the document
no URL of its own — `webView.url` becomes `about:blank`. So **reload on a new tab loaded a
blank page**, faithfully reloading about:blank. Reload now re-renders the new-tab HTML
when the tab is the new-tab page.

**Lesson.** Worth stating because it recurred: two of the bugs here were created by the
fix to a previous bug.

---

## 5. Google Meet: "doesn't work on your browser"

**Cause.** WKWebView's stock user agent is

```
Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)
```

and **stops there** — no `Version/… Safari/…` product token. Sniffers see no browser they
recognise and refuse.

**Fix.** Set `applicationNameForUserAgent` to Safari's token, read from the installed
Safari so it does not drift.

**Honest limit.** This could not be reproduced headlessly: signed-out `meet.google.com`
redirects to a marketing page either way, and the failing URL needed a live session. The
defect was unambiguous, but the fix was confirmed by the user, not by me.

---

## 6. Camera and microphone: "not found", with no way to allow

Three layers, each of which alone produced the same symptom.

**(a) WebKit was denying, not asking.** `WKUIDelegate`'s
`requestMediaCapturePermissionFor` **defaults to deny** when unimplemented. It does not
prompt. That is literally "it cannot ask for access."

**(b) No bundle metadata.** A SwiftPM executable has no `Info.plist`, so there were no
`NSCameraUsageDescription` / `NSMicrophoneUsageDescription` strings and no bundle
identifier — macOS will not prompt without them. Fixed by embedding a plist into
`__TEXT,__info_plist` via linker flags.

**(c) TCC blamed the wrong app.** With both fixed, the prompt read *"claude.app would like
to access the microphone"*. macOS attributes a permission request to the **responsible
process** — the app that started the chain — and the binary had been launched from a shell
inside another application. Allowing it would have granted the *parent* microphone access,
with Kestrel working only as a side effect.

**Fix.** Package `Kestrel.app` and launch via `open`, which hands it to LaunchServices and
makes it its own responsible process. Verified: parent PID is now `1`.

**Lesson.** The user spotted (c) from the prompt text. Nothing in the code was wrong at
that point; the defect was in how the process was launched.

---

## 7. Two failures I could not fix, and said so

**CAS login renders wrong under dark mode.** The user isolated it — broken with dark mode,
correct without. I could not reproduce it headlessly: a four-way comparison showed my ad
blocker hid **0** elements beyond what the page hides itself, and CAS served **identical
CSS** regardless of user agent (11 stylesheets, 10,470 rules). An attempted fix — deferring
Dark Reader's `enable()` until stylesheets exist — showed **no measurable difference** in
A/B testing, and the harness's own numbers were implausible, so I did not claim it worked.
Shipped a persistent per-site exclusion instead, which is what Dark Reader's own "Site
list" exists for.

**DuckDuckGo layout.** Measured across four configurations — clean, dark, blocker, both —
and got **8 overlapping text blocks in every one**. The "clean" column is a stock
`WKWebView` with none of Kestrel's features, i.e. Safari's engine. So it reproduces without
Kestrel doing anything: a WebKit-vs-Gecko difference, not a bug I introduced. I also
flagged that the absolute number is unreliable, because the overlapping pairs are
consecutive sentences from one paragraph — the detector over-counts. The meaningful result
is that the count is *unchanged* across configurations.

**Lesson.** Both entries exist because "I could not reproduce this, here is what I ruled
out and how" is more useful than a confident fix that was never demonstrated.

---

## 8. A null result that looked like a finding

The first three-policy benchmark on real sites returned:

```
none        mean 197.8 MB   over budget 0%   demotions 0
discardlru  mean 182.3 MB   over budget 0%   demotions 0
kestrel     mean 181.0 MB   over budget 0%   demotions 0
```

Three nearly identical rows read as "the policies are equivalent." They actually meant
**the experiment never ran**: the budget was 400 MB and the peak was 320 MB, so no policy
had anything to do. Compounding it, a pure Zipf-over-LRU revisit trace — the same model the
simulation used — concentrated so hard on recent tabs that only 9 of 10 were ever loaded.

**Lesson.** When every arm of an experiment agrees, check that the independent variable was
actually varied before believing the result.

---

## 9. The add-on memory benchmark measured Safari

The first run of `kestrel extmem` — how much memory a real Firefox add-on costs — opened
with this:

```
baseline: browser + 1 tab = 723 MB across 14 web processes
...
Pink                                889 MB   -3 MB    none
```

723 MB for one tab is not believable, and an add-on cannot cost minus three megabytes. Both
symptoms have one cause: `MemoryProbe.webContentPids()` returns **every** WebContent process
on the machine, whoever spawned them. Its own doc comment says so — "whoever spawned them.
Filtering to our own children is done by `Snapshot` below" — and I used it without the
filter. The baseline was mostly Safari, and the deltas were partly other applications
breathing.

Recording the pid set *before* the browser exists and subtracting it fixes both:

```
baseline: browser + 1 tab = 50 MB across 1 web process of ours (13 others ignored)
8 add-ons: 244 MB on top of a 50 MB browser
```

The corrected total reproduces across runs (244 MB, 248 MB). The per-add-on rows still go
negative, because each is a delta from the previous one and WebKit reclaims on its own
schedule — so the tool now says to read the total and not the rows, rather than presenting
noise as precision.

**Lesson.** Same shape as §2: the instrumentation was wrong in a way that produced a
plausible-looking table. The tell was not the negative row — it was the 723 MB baseline,
a number I could have sanity-checked against the browser sitting in front of me before
writing any of the analysis.

---

## 10. Six features deleted, and what the deletion proved

Kestrel shipped an ad blocker, a dark mode, a userscript engine, a Bitwarden client, a tab
reloader and a screenshot tool with an annotation editor — about 4,600 lines — because
there was no extension runtime and those were the nearest thing. WebKit's runtime made all
six available as real Firefox add-ons, so they were removed.

Two things worth keeping from the exercise.

**The tests that broke were the ones testing imitations.** `adblocktest`, `darktest`,
`shottest`, `filters`, `bisect`, `diag`, `overlap`, `darkab`, `darkpath` — nine headless
modes, all of them built to debug features that shipping add-ons now provide. The modes
that survived (`probe`, `bench`, `extmem`, `layouttest`, `selftest`) are the ones about the
browser's actual thesis: what memory costs and where it goes.

**Deleting a feature is where you find out what depended on it.** `Scheduler.floor(for:)`
had a case pinning auto-refreshing tabs to LIVE — a per-reason demotion floor, one of the
design's own ideas, existing only for a built-in feature. The Tab Reloader add-on now
reloads a tab through `browser.tabs.reload()`, which the scheduler sees as an ordinary
visit. The floor is gone and the behaviour it protected is gone with it, which is the
honest outcome: an add-on cannot ask the scheduler for special treatment, and DESIGN.md §2
should not claim otherwise.

**Lesson.** The count that matters after this is not lines removed. It is that the ad
blocker was cited in DESIGN.md §6 as a measured architectural result — declarative rules
cost ~nothing per tab — and that claim now rests on a benchmark whose code is deleted.
Measurements outlive the code that produced them only if the write-up says so.

---

## 11. Measuring the wrong process for eight months

The browser reported a Jira board as costing 52 MB. The process rendering it held 511 MB.
The 52 MB belonged to a different application's WebContent process that had been running for
eight days.

Three separate mistakes stacked, and each hid the next.

**`ps` lists every WebContent process on the machine.** They are XPC services parented to
launchd with identical command lines, so there is no parent and no client tag to filter on.
Nothing filtered at all, so any process on the system was a candidate. The one sound
discriminator available is age: a process older than the browser cannot be its.

**`Tab.makeLive` picked with `.first` on an unordered set.** WebKit spawns several content
processes at once — five on a measured launch — and the diff-at-creation trick assumed it
would see exactly one new pid. Whichever it happened to grab, the tab reported for its
lifetime.

**Nothing distinguished "cannot measure" from "costs nothing".** Both rendered `0 MB`, so a
live page the browser had lost track of was counted as free by the scheduler: never in the
total, never a demotion candidate.

### What made it survive so long

The number was always *plausible*. 52 MB for a page is unremarkable; so is 115, or 399. A
wrong number in a believable range is invisible in a way a crash is not, and every test
written against it passed, because the tests asked the browser what it thought rather than
checking the browser against the machine.

It took a screen recording to catch — specifically, the same figure appearing before and
after loading a completely different page. That is a temporal observation, and no single
screenshot or assertion contains it.

### The consequence for the published results

The benchmark's headline was a per-tab attributed sum, so it inherited all of this. Worse,
the error is **policy-dependent**: with no policy every process belongs to a live tab and
attribution captures 96%, but demoting tabs leaves processes alive and unattributed, so the
managed policies undercounted by 25–32%. The reduction fell from 1.43x to 1.28x and "0% over
budget" became 42%. See the correction at the end of RESULTS-ENGINE.md.

### The fixes

`WKWebView._webProcessIdentifier` — private, verified on macOS 15.5 — is asked at every
point a tab's process is established, with `ps` diffing filtered by age as fallback. The
whole-browser total is measured independently by summing the run's own processes, which
needs no attribution and therefore cannot be wrong in this way. Where the two disagree by
more than 20%, the UI says so.

**The lesson is the same one as §2, which this project had already learned:** an
instrument that reports on itself will report success. B1 improved `about:memory` while
returning nothing to the OS; this improved the tab total while the memory stayed in
processes nobody was counting. Both times the fix was to measure from outside the thing
being measured.
