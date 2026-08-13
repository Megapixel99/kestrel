#!/usr/bin/env python3
"""B1 runner: sweep V8 code-flushing configurations and report what a backgrounded
tab actually gets back.

V8 defaults (verified via --v8-options on this machine):
  --flush-bytecode        ON    bytecode flushed after --bytecode-old-age=6 GCs
  --flush-baseline-code   OFF   Sparkplug baseline code is never flushed
  optimized code          never flushed except via deopt

So "tier-down" is partly built and partly switched off. This measures the gap.
"""
import json, statistics, subprocess, sys, os

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "jit_mem.js")

BASE = ["--expose-gc", "--allow-natives-syntax"]

CONFIGS = {
    "naive (no flushing)":      ["--no-flush-bytecode"],
    "V8 default (today)":       [],
    "+ flush baseline code":    ["--flush-baseline-code"],
    "aggressive tier-down":     ["--stress-flush-code", "--flush-baseline-code"],
    "aggressive + compaction":  ["--stress-flush-code", "--flush-baseline-code",
                                 "--compact-on-every-full-gc"],
}

ENV = {
    "N_FUNCS":    os.environ.get("N_FUNCS", "4000"),
    "WARM_CALLS": os.environ.get("WARM_CALLS", "600"),
    "IDLE_GCS":   os.environ.get("IDLE_GCS", "20"),
    "IDLE_MS":    os.environ.get("IDLE_MS", "4000"),
}
REPS = int(os.environ.get("REPS", "3"))
MB = 1024 * 1024


def run_one(flags):
    env = dict(os.environ, **ENV)
    out = subprocess.run(["node", *BASE, *flags, SCRIPT],
                         capture_output=True, text=True, env=env, timeout=600)
    if out.returncode != 0:
        raise RuntimeError(f"node failed ({out.returncode}): {out.stderr[-2000:]}")
    return json.loads(out.stdout)


def main():
    results = {}
    for name, flags in CONFIGS.items():
        reps = []
        for r in range(REPS):
            j = run_one(flags)
            _, _, warm, idle = j["snapshots"]
            opt = j["optimized"]
            reps.append({
                "code_warm":  warm["codeBytes"],
                "code_idle":  idle["codeBytes"],
                "heap_warm":  warm["heapBytes"],
                "heap_idle":  idle["heapBytes"],
                "rss_warm":   warm["rss"],
                "rss_idle":   idle["rss"],
                "optimized":  opt.get("optimized"),
                "sampled":    opt.get("sampled"),
            })
            print(f"  {name} rep {r+1}/{REPS}", file=sys.stderr)
        med = {k: statistics.median(x[k] for x in reps) for k in reps[0] if reps[0][k] is not None}
        med["flags"] = flags
        results[name] = med

    print(f"\nB1 — code memory in a backgrounded tab   "
          f"({ENV['N_FUNCS']} functions, {ENV['WARM_CALLS']} calls each, "
          f"idle = {ENV['IDLE_GCS']} GCs / {int(ENV['IDLE_MS'])/1000:.0f}s, median of {REPS})\n")
    hdr = f"{'configuration':<26} {'code warm':>10} {'code idle':>10} {'reclaimed':>11} " \
          f"{'RSS warm':>10} {'RSS idle':>10} {'RSS back':>9}"
    print(hdr); print("-" * len(hdr))
    for name, m in results.items():
        rec = m["code_warm"] - m["code_idle"]
        pct = 100.0 * rec / m["code_warm"] if m["code_warm"] else 0
        rss_back = m["rss_warm"] - m["rss_idle"]
        rss_pct = 100.0 * rss_back / m["rss_warm"] if m["rss_warm"] else 0
        print(f"{name:<26} {m['code_warm']/MB:>9.1f}M {m['code_idle']/MB:>9.1f}M "
              f"{rec/MB:>6.1f}M {pct:>3.0f}% {m['rss_warm']/MB:>9.1f}M "
              f"{m['rss_idle']/MB:>9.1f}M {rss_back/MB:>6.1f}M {rss_pct:>3.0f}%")

    base = results["V8 default (today)"]
    best = results["aggressive tier-down"]
    gap = base["code_idle"] - best["code_idle"]
    print(f"\n  tier-up cost:            {(base['code_warm'] - base['code_idle'])/MB:.1f} MB "
          f"reclaimed by V8 today")
    print(f"  still on the table:      {gap/MB:.1f} MB "
          f"({100.0*gap/base['code_idle']:.0f}% of what a default idle tab still holds)")
    print(f"  sanity: {best['optimized']:.0f}/{best['sampled']:.0f} sampled functions "
          f"were Maglev/Turbofan optimized before idling")

    with open(os.path.join(HERE, "..", "..", "results", "b1_jit.json"), "w") as f:
        json.dump({"env": ENV, "reps": REPS, "results": results}, f, indent=2)


if __name__ == "__main__":
    main()
