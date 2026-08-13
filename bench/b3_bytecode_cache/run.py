#!/usr/bin/env python3
"""B3: does an mmap'd shared code cache actually cost less physical memory than
per-process heap copies?

Payload is real V8 code cache data (produced by gen_cache.js from shipping production
bundles), tiled with a per-replica salt up to PAYLOAD_MB so the file is the size of a
browser's code cache holding many sites' libraries, and so identical-page effects
can't flatter either mode.

We spawn N children -- standing in for N renderer processes that all loaded the same
libraries. A `control` mode spawns children that load nothing, which calibrates out
the interpreter's own per-process cost (non-trivial here: this Python runs under
Rosetta). Everything is reported as payload-attributable memory: mode minus control.
"""
import json, os, re, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE_DIR = os.path.join(HERE, "cache")
PAYLOAD = os.path.join(HERE, "payload.bin")
CHILD = os.path.join(HERE, "child.py")
MB = 1024 * 1024

N_PROCS = int(os.environ.get("N_PROCS", "16"))
PAYLOAD_MB = int(os.environ.get("PAYLOAD_MB", "48"))
REPS = int(os.environ.get("REPS", "3"))
PAGE = 16384


def build_payload():
    blobs = [open(os.path.join(CACHE_DIR, f), "rb").read()
             for f in sorted(os.listdir(CACHE_DIR)) if f.endswith(".v8cache")]
    if not blobs:
        sys.exit("no .v8cache files -- run `node gen_cache.js` first")
    unit = b"".join(blobs)
    target = PAYLOAD_MB * MB
    with open(PAYLOAD, "wb") as f:
        written = i = 0
        while written < target:
            salt = (i * 2654435761) & 0xFF          # keep replicas non-identical
            f.write(bytes(b ^ salt for b in unit[:4096]) + unit[4096:])
            written += len(unit); i += 1
    return os.path.getsize(PAYLOAD), len(unit), i


def vm_phys_used():
    """Physical memory in use, from vm_stat (active + wired + compressor-occupied)."""
    out = subprocess.run(["vm_stat"], capture_output=True, text=True).stdout
    def pages(label):
        m = re.search(rf"{label}:\s+(\d+)", out)
        return int(m.group(1)) if m else 0
    return (pages("Pages active") + pages("Pages wired down") +
            pages("Pages occupied by compressor")) * PAGE


def footprint_total(pid):
    """phys_footprint in bytes. Excludes clean shared file-backed pages -- which is
    precisely the accounting macOS itself uses for memory pressure."""
    out = subprocess.run(["footprint", "--", str(pid)], capture_output=True, text=True).stdout
    m = re.search(r"Footprint:\s+([\d.]+)\s*(KB|MB|GB)", out)
    if not m:
        return 0.0
    return float(m.group(1)) * {"KB": 1024, "MB": MB, "GB": 1024 * MB}[m.group(2)]


def rss(pid):
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True)
    return int(out.stdout.strip() or 0) * 1024


def run_mode(mode, n):
    time.sleep(1.5)
    base = vm_phys_used()
    args = [sys.executable, CHILD, mode] + ([] if mode == "control" else [PAYLOAD])
    procs = [subprocess.Popen(args, stdout=subprocess.PIPE, text=True) for _ in range(n)]
    for p in procs:
        line = p.stdout.readline()
        if not line.startswith("READY"):
            for q in procs: q.kill()
            sys.exit(f"child failed in mode {mode}: {line!r}")
    time.sleep(2.0)

    sample = procs[:6]
    out = {
        "sys_phys_delta": vm_phys_used() - base,
        "footprint_mean": statistics.mean(footprint_total(p.pid) for p in sample),
        "rss_mean": statistics.mean(rss(p.pid) for p in sample),
    }
    for p in procs:
        p.kill(); p.wait()
    return out


def main():
    size, unit, reps = build_payload()
    print(f"payload: {size/MB:.1f} MB  ({unit/1024:.0f} KB of real V8 cache data "
          f"x {reps} salted replicas)", file=sys.stderr)
    print(f"{N_PROCS} processes per mode, {REPS} reps\n", file=sys.stderr)

    raw = {m: [] for m in ("control", "heap", "mmap")}
    for r in range(REPS):
        for mode in raw:
            raw[mode].append(run_mode(mode, N_PROCS))
            print(f"  rep {r+1}: {mode}", file=sys.stderr)

    med = {m: {k: statistics.median(x[k] for x in v) for k in v[0]} for m, v in raw.items()}
    ctl = med["control"]

    print(f"\nB3 — {N_PROCS} processes each holding a {size/MB:.0f} MB code cache "
          f"(median of {REPS}; control subtracted)\n")
    hdr = (f"{'mode':<24} {'system physical':>16} {'per-proc footprint':>19} "
           f"{'per-proc RSS':>13}")
    print(hdr); print("-" * len(hdr))
    print(f"{'control (no payload)':<24} {'--':>16} {ctl['footprint_mean']/MB:>18.0f}M "
          f"{ctl['rss_mean']/MB:>12.0f}M")
    for mode, label in (("heap", "private heap copies"), ("mmap", "shared mmap")):
        m = med[mode]
        print(f"{label:<24} {(m['sys_phys_delta']-ctl['sys_phys_delta'])/MB:>15.0f}M "
              f"{(m['footprint_mean']-ctl['footprint_mean'])/MB:>18.0f}M "
              f"{(m['rss_mean']-ctl['rss_mean'])/MB:>12.0f}M")

    h = med["heap"]["sys_phys_delta"] - ctl["sys_phys_delta"]
    m = med["mmap"]["sys_phys_delta"] - ctl["sys_phys_delta"]
    print(f"\n  ideal if unshared (N x payload): {size*N_PROCS/MB:>6.0f} MB    measured {h/MB:.0f} MB")
    print(f"  ideal if shared   (1 x payload): {size/MB:>6.0f} MB    measured {m/MB:.0f} MB")
    if m > 1 * MB:
        print(f"  physical memory saved: {(h-m)/MB:.0f} MB ({h/m:.0f}x less)")
    else:
        print(f"  physical memory saved: {(h-m)/MB:.0f} MB (shared cost is ~0)")
    print(f"\n  Per-process footprint: {(med['heap']['footprint_mean']-ctl['footprint_mean'])/MB:.0f} MB "
          f"heap vs {(med['mmap']['footprint_mean']-ctl['footprint_mean'])/MB:.0f} MB mmap. "
          f"macOS excludes clean\n  shared file-backed pages from phys_footprint, which is the number "
          f"memory\n  pressure actually acts on -- mmap'd cache is nearly free by that accounting.")

    with open(os.path.join(HERE, "..", "..", "results", "b3_bytecode.json"), "w") as f:
        json.dump({"payload_bytes": size, "n_procs": N_PROCS, "reps": REPS,
                   "median": med}, f, indent=2)
    os.remove(PAYLOAD)


if __name__ == "__main__":
    main()
