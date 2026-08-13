#!/bin/bash
# One policy per process: WebKit's process cache would otherwise let one policy's
# leftovers contaminate the next.
URLS=${3:-urls.txt}
BUDGET=${1:-400}
EVENTS=${2:-40}
OUT=../results/engine/$(basename "$URLS" .txt)
mkdir -p "$OUT"
for p in none discardlru kestrel; do
  echo "=== $p (budget ${BUDGET}MB, $EVENTS events) ==="
  ./.build/debug/kestrel bench "$URLS" "$BUDGET" "$p" "$EVENTS" > "$OUT/bench_$p.txt" 2>&1
  tail -1 "$OUT/bench_$p.txt"
  sleep 20   # let WebKit's process cache drain between policies
done
