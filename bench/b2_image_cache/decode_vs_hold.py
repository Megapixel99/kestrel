#!/usr/bin/env python3
"""B2: is it cheaper to hold a decoded image or to re-decode it on demand?

Uses real photographs (macOS desktop pictures, 5120x2880 originals) resampled to
web-realistic sizes and re-encoded at web-realistic quality. PIL here is built on
libjpeg-turbo 3.1.4.1 -- the same decoder family Chrome and Firefox use -- so the
decode timings are directly comparable rather than a proxy.

The question a browser has to answer for every off-screen image is:
    hold  -> w * h * 4 bytes of RGBA, resident, forever
    evict -> keep the compressed source, pay a decode on scroll-back
"""
import io, json, os, statistics, sys, time
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SRC_DIR = "/Library/Desktop Pictures"
REPS = int(os.environ.get("REPS", "7"))
MB = 1024 * 1024

# Web-realistic render sizes: thumbnail, card, content image, hero, full-bleed 4K.
SIZES = [("thumb", 400, 225), ("card", 800, 450), ("content", 1600, 900),
         ("hero", 2560, 1440), ("4K", 3840, 2160)]
FORMATS = [("JPEG", {"quality": 75, "optimize": True}),
           ("WEBP", {"quality": 80, "method": 4}),
           ("AVIF", {"quality": 60})]


def load_sources(n=4):
    srcs = []
    for name in sorted(os.listdir(SRC_DIR)):
        if not name.lower().endswith(".jpg"):
            continue
        try:
            im = Image.open(os.path.join(SRC_DIR, name)).convert("RGB")
            im.load()
            srcs.append((name, im))
        except Exception:
            continue
        if len(srcs) >= n:
            break
    if not srcs:
        sys.exit(f"no source photos found in {SRC_DIR}")
    return srcs


def time_decode(blob, reps):
    """Median full-decode time from an in-memory buffer (no disk I/O in the loop)."""
    ts = []
    for _ in range(reps):
        t0 = time.perf_counter()
        im = Image.open(io.BytesIO(blob))
        im.load()                     # force the actual decode
        ts.append((time.perf_counter() - t0) * 1000.0)
        del im
    return statistics.median(ts)


def main():
    srcs = load_sources()
    print(f"sources: {', '.join(n for n, _ in srcs)}", file=sys.stderr)
    rows = []
    for label, w, h in SIZES:
        for fmt, opts in FORMATS:
            enc_sizes, dec_times = [], []
            for name, im in srcs:
                small = im.resize((w, h), Image.LANCZOS)
                buf = io.BytesIO()
                try:
                    small.save(buf, format=fmt, **opts)
                except Exception as e:
                    enc_sizes = None
                    print(f"  skip {fmt}: {e}", file=sys.stderr)
                    break
                blob = buf.getvalue()
                enc_sizes.append(len(blob))
                dec_times.append(time_decode(blob, REPS))
            if not enc_sizes:
                continue
            rgba = w * h * 4
            enc = statistics.median(enc_sizes)
            rows.append({
                "size": label, "w": w, "h": h, "format": fmt,
                "encoded_bytes": enc, "rgba_bytes": rgba,
                "amplification": rgba / enc,
                "decode_ms": statistics.median(dec_times),
                # the design's "downsampled preview" fallback: 1/8 linear = 1/64 area
                "preview_bytes": (w // 8) * (h // 8) * 4,
            })
            print(f"  {label:<8} {fmt:<5} done", file=sys.stderr)

    hdr = (f"{'render size':<12} {'fmt':<6} {'encoded':>9} {'decoded RGBA':>13} "
           f"{'amplif.':>8} {'decode':>9} {'MB/s held':>10}")
    print("\nB2 — cost of holding a decoded image vs re-decoding it\n")
    print(hdr); print("-" * len(hdr))
    for r in rows:
        dims = "{} {}x{}".format(r["size"], r["w"], r["h"])
        print(f"{dims:<12} {r['format']:<6} "
              f"{r['encoded_bytes']/1024:>8.0f}K {r['rgba_bytes']/MB:>12.1f}M "
              f"{r['amplification']:>7.0f}x {r['decode_ms']:>8.1f}ms "
              f"{r['rgba_bytes']/MB/(r['decode_ms']/1000):>9.0f}")

    print("\n  'MB/s held' = memory freed per second of decode latency you'd pay back.")
    jpg4k = next(r for r in rows if r["size"] == "4K" and r["format"] == "JPEG")
    print(f"\n  A 4K JPEG holds {jpg4k['rgba_bytes']/MB:.0f} MB decoded, "
          f"{jpg4k['amplification']:.0f}x its {jpg4k['encoded_bytes']/1024:.0f} KB source, "
          f"and costs {jpg4k['decode_ms']:.1f} ms to rebuild.")
    print(f"  A 1/8-scale preview of it costs {jpg4k['preview_bytes']/1024:.0f} KB "
          f"({jpg4k['rgba_bytes']/jpg4k['preview_bytes']:.0f}x less than the full surface).")

    with open(os.path.join(HERE, "..", "..", "results", "b2_images.json"), "w") as f:
        json.dump(rows, f, indent=2)
    return rows


if __name__ == "__main__":
    main()
