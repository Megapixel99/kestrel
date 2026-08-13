#!/usr/bin/env python3
"""B3 child: models one renderer process holding the code cache.

  heap  -- read the cache into a private buffer. This is what browsers do today:
           every process that loads the same library gets its own anonymous copy.
  mmap  -- map the one cache file read-only. Physical pages are shared by the OS
           across every process that maps it, and they are clean, so the kernel can
           drop them under pressure without swapping.

Both modes touch every page so the data is genuinely resident, then keep a sample
warm so the comparison isn't distorted by the macOS memory compressor.
"""
import mmap, os, sys, time

mode = sys.argv[1]
PAGE = 16384

if mode == "control":
    # Loads nothing: calibrates the interpreter's own per-process cost.
    sys.stdout.write(f"READY {os.getpid()} 0\n")
    sys.stdout.flush()
    while True:
        time.sleep(0.2)

path = sys.argv[2]
if mode == "heap":
    with open(path, "rb") as f:
        data = f.read()                      # private, anonymous, dirty
    view = memoryview(data)
elif mode == "mmap":
    f = open(path, "rb")
    data = mmap.mmap(f.fileno(), 0, prot=mmap.PROT_READ)   # shared, file-backed, clean
    view = memoryview(data)
else:
    sys.exit("mode must be heap|mmap")

# Force every page resident.
acc = 0
for off in range(0, len(view), PAGE):
    acc ^= view[off]

sys.stdout.write(f"READY {os.getpid()} {acc}\n")
sys.stdout.flush()

# Keep pages active so neither mode gets silently compressed out from under us.
while True:
    for off in range(0, len(view), PAGE * 16):
        acc ^= view[off]
    time.sleep(0.2)
