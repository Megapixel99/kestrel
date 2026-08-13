// B1: How much code memory does a "tab" hold, and how much comes back when it idles?
//
// Models a heavy SPA: N distinct functions, all strongly reachable from a module
// registry (as a real page's module graph would be), warmed until V8 tiers them up.
// Then the tab "goes to background": no more calls, repeated GCs, real elapsed time.
//
// Reachability matters. If we dropped the references, V8 would collect everything and
// we'd be measuring garbage collection, not code flushing. A background tab's closures
// are still reachable -- that is exactly why its code memory persists.

const v8 = require('v8');

const N_FUNCS = parseInt(process.env.N_FUNCS || '4000', 10);
const WARM_CALLS = parseInt(process.env.WARM_CALLS || '3000', 10);
const IDLE_GCS = parseInt(process.env.IDLE_GCS || '20', 10);
const IDLE_MS = parseInt(process.env.IDLE_MS || '3000', 10);

const CODE_SPACES = new Set([
  'code_space', 'code_large_object_space',
  'trusted_space', 'trusted_large_object_space',   // BytecodeArray + Code live here in V8 >= 12
]);

function snapshot(label) {
  const spaces = {};
  let codeBytes = 0, heapBytes = 0;
  for (const s of v8.getHeapSpaceStatistics()) {
    spaces[s.space_name] = s.space_used_size;
    heapBytes += s.space_used_size;
    if (CODE_SPACES.has(s.space_name)) codeBytes += s.space_used_size;
  }
  return { label, spaces, codeBytes, heapBytes, rss: process.memoryUsage().rss };
}

// Distinct bodies so V8 cannot dedupe them. Shapes chosen to exercise the paths that
// actually generate code: arithmetic, property access, array/string ops, a closure.
function genSource(n) {
  const parts = ['const REGISTRY = [];'];
  for (let i = 0; i < n; i++) {
    parts.push(`
function mod${i}(a, b) {
  const seed = ${i};
  let acc = a * ${(i % 97) + 1} + b - seed;
  const state = { id: seed, hits: 0, tag: "m${i}", buf: null };
  const xs = [];
  for (let k = 0; k < 8; k++) {
    xs.push((acc ^ (k * ${(i % 31) + 3})) >>> ${(i % 7) + 1});
    acc = (acc + xs[k]) | 0;
  }
  state.hits = xs.reduce((p, c) => p + c, 0);
  state.buf = xs.filter(x => x % ${(i % 5) + 2} === 0).map(x => x * 2);
  if (state.hits % ${(i % 13) + 2} === 0) {
    state.tag = state.tag + ":" + state.buf.length.toString(${(i % 20) + 16});
  }
  const close = (z) => z + state.hits + seed;
  return close(acc) + state.tag.length + state.buf.length;
}
REGISTRY.push(mod${i});`);
  }
  parts.push('REGISTRY;');
  return parts.join('\n');
}

const t0 = Date.now();
const before = snapshot('empty');

// --- load phase: compile the "page's" scripts ---
const registry = (0, eval)(genSource(N_FUNCS));
const afterCompile = snapshot('after_compile');

// --- warm phase: the tab is in the foreground and busy ---
let sink = 0;
for (let call = 0; call < WARM_CALLS; call++) {
  for (let i = 0; i < registry.length; i++) sink += registry[i](call, i);
}
const afterWarm = snapshot('after_warm');

// Verify we actually tiered up; otherwise the whole measurement is meaningless.
// Natives syntax is a parse error without --allow-natives-syntax, so it must be eval'd.
let optimized = null;
try {
  const probe = new Function('fns', `
    let opt = 0, sampled = Math.min(fns.length, 500);
    for (let i = 0; i < sampled; i++) {
      const st = %GetOptimizationStatus(fns[i]);
      // bit 4 = TURBOFANNED, bit 11 = MAGLEVVED (V8 OptimizationStatus)
      if ((st & (1 << 4)) || (st & (1 << 11))) opt++;
    }
    return { sampled, optimized: opt };
  `);
  optimized = probe(registry);
} catch (e) {
  optimized = { error: 'natives syntax unavailable (needs --allow-natives-syntax)' };
}

// --- idle phase: the tab goes to the background ---
// Bytecode flushing is age-based, incremented per GC cycle, so drive real GCs and
// let real time pass (--flush-code-based-on-time uses the clock instead).
(async () => {
  const step = Math.max(1, Math.floor(IDLE_MS / IDLE_GCS));
  for (let i = 0; i < IDLE_GCS; i++) {
    global.gc();
    await new Promise(r => setTimeout(r, step));
  }
  global.gc({ type: 'major', execution: 'sync' });
  const afterIdle = snapshot('after_idle');

  // The functions must still be callable -- flushing must be transparent.
  const recheck = registry[0](1, 1) + registry[registry.length - 1](1, 1);

  console.log(JSON.stringify({
    config: { N_FUNCS, WARM_CALLS, IDLE_GCS, IDLE_MS, flags: process.execArgv },
    snapshots: [before, afterCompile, afterWarm, afterIdle],
    optimized,
    elapsedMs: Date.now() - t0,
    sink: sink % 1000, recheck: recheck % 1000,   // keep the work alive
  }));
})();
