#!/usr/bin/env python3
"""B1b: does tiering up make code memory permanent?

V8 will not flush a function's bytecode while that function has optimized code
attached -- the bytecode is needed to deoptimize back into. So the default
flushing policy exempts precisely the hot functions that dominate code memory.

Sweep warm-up intensity (which controls whether functions reach Maglev/Turbofan)
and watch where the idle floor lands.
"""
import json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "jit_mem.js")
MB = 1024 * 1024
WARM_LEVELS = [20, 100, 300, 600, 1200]

rows = []
for wc in WARM_LEVELS:
    env = dict(os.environ, N_FUNCS="4000", WARM_CALLS=str(wc),
               IDLE_GCS="20", IDLE_MS="4000")
    out = subprocess.run(["node", "--expose-gc", "--allow-natives-syntax", SCRIPT],
                         capture_output=True, text=True, env=env, timeout=600)
    j = json.loads(out.stdout)
    s, o = j["snapshots"], j["optimized"]
    rows.append({"warm_calls": wc,
                 "pct_optimized": 100.0 * o["optimized"] / o["sampled"],
                 "code_warm": s[2]["codeBytes"], "code_idle": s[3]["codeBytes"]})
    print(f"  warm={wc}", file=sys.stderr)

hdr = f"{'calls/fn':>9} {'optimized':>10} {'code warm':>11} {'idle floor':>11} {'reclaimed':>10}"
print("\nB1b — idle floor vs tier-up (4000 functions, V8 default flags)\n")
print(hdr); print("-" * len(hdr))
for r in rows:
    rec = 100.0 * (r["code_warm"] - r["code_idle"]) / r["code_warm"]
    print(f"{r['warm_calls']:>9} {r['pct_optimized']:>9.0f}% "
          f"{r['code_warm']/MB:>10.1f}M {r['code_idle']/MB:>10.1f}M {rec:>9.0f}%")

cold = min(r["code_idle"] for r in rows if r["pct_optimized"] == 0)
hot = max(r["code_idle"] for r in rows if r["pct_optimized"] > 50)
print(f"\n  idle floor, never optimized:  {cold/MB:.1f} MB")
print(f"  idle floor, fully optimized:  {hot/MB:.1f} MB  ({hot/cold:.1f}x)")
print(f"  permanently retained by tier-up: {(hot-cold)/MB:.1f} MB")

with open(os.path.join(HERE, "..", "..", "results", "b1_tierup_sensitivity.json"), "w") as f:
    json.dump(rows, f, indent=2)
