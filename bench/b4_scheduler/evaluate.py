#!/usr/bin/env python3
"""B4b: evaluate the scheduler against what browsers do today.

Tab sizes are bootstrapped from the REAL per-renderer RSS distribution sampled from
the Chrome running on this machine (results/chrome_renderer_rss_mb.txt): 17 renderers,
median 137 MB, mean 215 MB. Everything downstream of that is a simulation, and is
labelled as one -- the point is to compare *policies* under one honest cost model,
and to find out how much the answer depends on the assumptions we're least sure of.

Revisit behaviour is recency-biased: the probability of returning to a tab falls off
as a power law in how far down the recently-used stack it sits. ZIPF_ALPHA controls
how strongly, and is swept.
"""
import json, os, random, statistics, sys
from scheduler import (Tab, State, CostModel, KestrelScheduler,
                       DiscardLRUScheduler, NoEvictionScheduler)

HERE = os.path.dirname(os.path.abspath(__file__))
MB = 1024 * 1024
GB = 1024 * MB
RSS_FILE = os.path.join(HERE, "..", "..", "results",
                        os.environ.get("RSS_FILE", "chrome_renderer_rss_mb.txt"))


def load_live_sizes():
    with open(RSS_FILE) as f:
        return [int(line.strip()) * 1024 for line in f if line.strip()]


def make_trace(n_events, n_tabs, alpha, seed):
    """(tab_id, dt_seconds) events. Tabs open over the first half of the session."""
    rng = random.Random(seed)
    events, open_tabs = [], [0]
    for i in range(n_events):
        if len(open_tabs) < n_tabs and rng.random() < 0.5:
            tid = len(open_tabs)
            open_tabs.append(tid)
        else:
            # Zipf over LRU stack position: position 1 is the most recent tab.
            k = len(open_tabs)
            weights = [1.0 / (r ** alpha) for r in range(1, k + 1)]
            tot = sum(weights)
            x, acc, idx = rng.random() * tot, 0.0, 0
            for r, w in enumerate(weights):
                acc += w
                if x <= acc:
                    idx = r
                    break
            tid = open_tabs[idx]
        open_tabs.remove(tid)
        open_tabs.insert(0, tid)          # move to front of the LRU stack
        events.append((tid, rng.lognormvariate(3.0, 1.2)))   # dwell seconds
    return events


def simulate(policy_cls, events, live_sizes, cost, budget, seed):
    rng = random.Random(seed ^ 0x5EED)
    sched = policy_cls(budget, cost)
    tabs, by_id = [], {}
    now = 0.0
    mem_samples, restores, state_losses, stall_ms = [], [], 0, 0.0
    reclaim_ms, oom_breaks, capped_visits, visits = 0.0, 0, 0, 0

    for tid, dt in events:
        now += dt
        tab = by_id.get(tid)
        if tab is None:
            tab = Tab(tid=tid, live_bytes=rng.choice(live_sizes), last_used=now)
            tab.pinned = rng.random() < 0.05
            tab.audible = rng.random() < 0.03
            tab.cooperates = rng.random() < 0.6      # framework adoption rate
            by_id[tid] = tab
            tabs.append(tab)
        else:
            if tab.state != State.LIVE:
                ms = cost.restore_ms(tab)
                restores.append((tab.state, ms))
                stall_ms += ms
                if tab.state == State.STUB:
                    state_losses += 1
                tab.state = State.LIVE
        # --- per-tab memory limit, applied to the tab the user is looking at ---
        # The cap is enforced continuously, but it only *costs* anything when the tab
        # is being used: that is when reclaimed images must be re-decoded and a
        # compacting GC steals frame time.
        visits += 1
        if cost.overshoot(tab) > 1.0:
            capped_visits += 1
            if cost.breaks(tab):
                # The page cannot fit in its cap at all: OOM, reload, work lost.
                oom_breaks += 1
                state_losses += 1
                stall_ms += cost.reload_stub_ms
                tab.state = State.LIVE
            else:
                reclaim_ms += cost.reclaim_cost_ms(tab)
                stall_ms += cost.reclaim_cost_ms(tab)

        tab.last_used = now
        tab.uses += 1
        tab.has_unsubmitted_input = rng.random() < 0.08

        sched.enforce(tabs, now, foreground=tid)
        mem_samples.append(sched.total_bytes(tabs))

    lat = [ms for _, ms in restores] or [0.0]
    lat.sort()
    return {
        "peak_mb": max(mem_samples) / MB,
        "mean_mb": statistics.mean(mem_samples) / MB,
        "over_budget_pct": 100.0 * sum(1 for m in mem_samples if m > budget) / len(mem_samples),
        "final_tabs": len(tabs),
        "restores": len(restores),
        "state_losses": state_losses,
        "stall_s": stall_ms / 1000.0,
        "p50_ms": lat[len(lat) // 2],
        "p95_ms": lat[int(len(lat) * 0.95)],
        "janky_restores": sum(1 for ms in lat if ms > 100),
        "reclaim_s": reclaim_ms / 1000.0,
        "oom_breaks": oom_breaks,
        "capped_visit_pct": 100.0 * capped_visits / max(1, visits),
    }


POLICIES = [("status quo (no eviction)", NoEvictionScheduler),
            ("discard-LRU (browsers today)", DiscardLRUScheduler),
            ("Kestrel (4-state, scored)", KestrelScheduler)]


def run_block(events, live_sizes, cost, budget, seed):
    return {name: simulate(cls, events, live_sizes, cost, budget, seed)
            for name, cls in POLICIES}


def main():
    live_sizes = load_live_sizes()
    n_events = int(os.environ.get("N_EVENTS", "4000"))
    n_tabs = int(os.environ.get("N_TABS", "80"))
    budget = float(os.environ.get("BUDGET_GB", "2.0")) * GB
    alpha = float(os.environ.get("ZIPF_ALPHA", "1.1"))
    seeds = [11, 23, 37, 51, 67]

    src = os.path.basename(RSS_FILE).replace("_rss_mb.txt", "").replace("_", " ")
    print(f"tab sizes bootstrapped from {len(live_sizes)} real {src} processes "
          f"(median {statistics.median(live_sizes)/MB:.0f} MB, "
          f"max {max(live_sizes)/MB:.0f} MB)")
    print(f"{n_events} events, up to {n_tabs} tabs, budget {budget/GB:.1f} GB, "
          f"zipf alpha {alpha}, {len(seeds)} seeds\n")

    agg = {name: [] for name, _ in POLICIES}
    for s in seeds:
        ev = make_trace(n_events, n_tabs, alpha, s)
        for name, r in run_block(ev, live_sizes, CostModel(), budget, s).items():
            agg[name].append(r)
    med = {n: {k: statistics.median(x[k] for x in v) for k in v[0]} for n, v in agg.items()}

    hdr = (f"{'policy':<30} {'mean':>8} {'peak':>8} {'over budget':>12} {'restores':>9} "
           f"{'p95':>8} {'state lost':>11}")
    print(hdr); print("-" * len(hdr))
    for name, _ in POLICIES:
        m = med[name]
        print(f"{name:<30} {m['mean_mb']:>7.0f}M {m['peak_mb']:>7.0f}M "
              f"{m['over_budget_pct']:>11.0f}% {m['restores']:>9.0f} "
              f"{m['p95_ms']:>7.0f}ms {m['state_losses']:>11.0f}")

    sq, lru, kes = (med[n] for n, _ in POLICIES)
    print(f"\n  Kestrel holds mean memory to {kes['mean_mb']:.0f} MB vs "
          f"{sq['mean_mb']:.0f} MB unmanaged ({sq['mean_mb']/kes['mean_mb']:.1f}x less)")
    print(f"  vs discard-LRU at the same budget: {lru['state_losses']:.0f} state-losing "
          f"reloads -> {kes['state_losses']:.0f}, p95 restore "
          f"{lru['p95_ms']:.0f}ms -> {kes['p95_ms']:.0f}ms")

    # --- sensitivity: the freeze quality assumption we are least sure of ---
    print(f"\n  sensitivity to freeze quality (warm_frac = bytes a frozen tab still holds):")
    print(f"    {'warm_frac':>10} {'Kestrel mean':>14} {'peak':>9} {'janky':>8} {'state lost':>11}")
    sens = {}
    for wf in (0.02, 0.05, 0.15, 0.30, 0.50):
        rows = []
        for s in seeds:
            ev = make_trace(n_events, n_tabs, alpha, s)
            rows.append(simulate(KestrelScheduler, ev, live_sizes,
                                 CostModel(warm_frac=wf), budget, s))
        m = {k: statistics.median(x[k] for x in rows) for k in rows[0]}
        sens[wf] = m
        print(f"    {wf:>10.2f} {m['mean_mb']:>13.0f}M {m['peak_mb']:>8.0f}M "
              f"{m['janky_restores']:>8.0f} {m['state_losses']:>11.0f}")

    # --- sensitivity: how recency-biased browsing actually is ---
    print(f"\n  sensitivity to revisit locality (zipf alpha; lower = more random revisits):")
    print(f"    {'alpha':>10} {'Kestrel mean':>14} {'janky':>8} {'LRU state lost':>16} {'Kestrel state lost':>19}")
    for a in (0.6, 0.9, 1.1, 1.5, 2.0):
        krows, lrows = [], []
        for s in seeds:
            ev = make_trace(n_events, n_tabs, a, s)
            krows.append(simulate(KestrelScheduler, ev, live_sizes, CostModel(), budget, s))
            lrows.append(simulate(DiscardLRUScheduler, ev, live_sizes, CostModel(), budget, s))
        km = {k: statistics.median(x[k] for x in krows) for k in krows[0]}
        lm = {k: statistics.median(x[k] for x in lrows) for k in lrows[0]}
        print(f"    {a:>10.1f} {km['mean_mb']:>13.0f}M {km['janky_restores']:>8.0f} "
              f"{lm['state_losses']:>16.0f} {km['state_losses']:>19.0f}")

    # --- per-tab memory limit: the prerequisite for the budget meaning anything ---
    print(f"\n  per-tab memory limit (Kestrel, {budget/GB:.0f} GB budget). A cap bounds the "
          f"live working\n  set the scheduler may not touch, but costs in-tab reclaim and, "
          f"low enough, breakage:")
    print(f"    {'cap':>10} {'mean':>8} {'peak':>8} {'over budget':>12} {'visits capped':>14} "
          f"{'reclaim':>9} {'OOM breaks':>11} {'state lost':>11}")
    caps = [0, 1024, 768, 512, 384, 256, 192, 128]
    cap_rows = {}
    for cap_mb in caps:
        rows = []
        for s in seeds:
            ev = make_trace(n_events, n_tabs, alpha, s)
            rows.append(simulate(KestrelScheduler, ev, live_sizes,
                                 CostModel(per_tab_cap=cap_mb * MB), budget, s))
        m = {k: statistics.median(x[k] for x in rows) for k in rows[0]}
        cap_rows[cap_mb] = m
        label = "none" if cap_mb == 0 else f"{cap_mb} MB"
        print(f"    {label:>10} {m['mean_mb']:>7.0f}M {m['peak_mb']:>7.0f}M "
              f"{m['over_budget_pct']:>11.0f}% {m['capped_visit_pct']:>13.0f}% "
              f"{m['reclaim_s']:>8.0f}s {m['oom_breaks']:>11.0f} {m['state_losses']:>11.0f}")

    base = cap_rows[0]
    fits = [c for c in caps if c and cap_rows[c]["over_budget_pct"] <= 5
            and cap_rows[c]["oom_breaks"] == 0]
    if fits:
        knee = max(fits)
        k = cap_rows[knee]
        print(f"\n  Largest cap that holds the budget with zero breakage: {knee} MB "
              f"-- over budget {k['over_budget_pct']:.0f}% (vs {base['over_budget_pct']:.0f}% "
              f"uncapped), mean {k['mean_mb']:.0f}M (vs {base['mean_mb']:.0f}M), "
              f"{k['reclaim_s']:.0f}s reclaim over the session.")
    else:
        print(f"\n  No cap in the swept range both held the budget and avoided breakage.")

    # break_ratio decides the whole "no cap works" verdict above, and it is the least
    # defensible number in this file -- how far past its cap a page can be squeezed
    # before it stops working rather than merely thrashing. Sweep it.
    print(f"\n  sensitivity to break_ratio (how far over cap a page survives):")
    print(f"    {'break_ratio':>12} " + " ".join(f"{str(c)+'M':>9}" for c in caps if c))
    for br in (1.5, 2.0, 2.5, 3.0, 4.0):
        cells = []
        for cap_mb in [c for c in caps if c]:
            rows = []
            for s in seeds:
                ev = make_trace(n_events, n_tabs, alpha, s)
                rows.append(simulate(KestrelScheduler, ev, live_sizes,
                                     CostModel(per_tab_cap=cap_mb * MB, break_ratio=br),
                                     budget, s))
            ob = statistics.median(x["over_budget_pct"] for x in rows)
            oom = statistics.median(x["oom_breaks"] for x in rows)
            cells.append(f"{ob:>3.0f}%/{oom:<4.0f}" if oom else f"{ob:>3.0f}%/ -  ")
        print(f"    {br:>12.1f} " + " ".join(f"{c:>9}" for c in cells))
    print(f"    (cells are 'over-budget% / OOM breaks'; '-' means no breakage)")

    with open(os.path.join(HERE, "..", "..", "results", "b4_per_tab_cap.json"), "w") as f:
        json.dump({"budget_gb": budget / GB, "rss_file": os.path.basename(RSS_FILE),
                   "caps_mb": {str(k): v for k, v in cap_rows.items()}}, f, indent=2)

    with open(os.path.join(HERE, "..", "..", "results", "b4_scheduler.json"), "w") as f:
        json.dump({"config": {"n_events": n_events, "n_tabs": n_tabs,
                              "budget_gb": budget / GB, "alpha": alpha, "seeds": seeds},
                   "median": med,
                   "sensitivity_warm_frac": {str(k): v for k, v in sens.items()}}, f, indent=2)


if __name__ == "__main__":
    main()
