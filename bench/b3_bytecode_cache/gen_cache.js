// B3a: produce REAL V8 code cache blobs from REAL production JS bundles.
//
// These are shipping minified web-app bundles found on this machine (Kindle's web
// app, Microsoft Office's web add-in runtimes), not synthetic code. We compile each
// with vm.Script and ask V8 for its cached data -- exactly the artifact a browser
// writes to its on-disk code cache after a first load.
//
// We compile but do not run: running these would need a DOM. That means we capture
// the eagerly-compiled top level, which is what a browser caches on first visit too.

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const CANDIDATES = [
  '/Applications/Kindle.app/Contents/Resources/appBundle.js',
  '/Applications/Kindle.app/Contents/Resources/bundle.js',
  '/Applications/Kindle.app/Contents/Resources/library-bundle.js',
  '/Applications/Kindle.app/Contents/Resources/intl-polyfill.chunk.js',
  '/Applications/Microsoft PowerPoint.app/Contents/Resources/powerpoint.js',
  '/Applications/Microsoft Excel.app/Contents/Resources/excel.js',
  '/Applications/Microsoft Outlook.app/Contents/Resources/cardRenderHelper_mac.js',
];

const OUT_DIR = path.join(__dirname, 'cache');
fs.mkdirSync(OUT_DIR, { recursive: true });

const report = [];
for (const file of CANDIDATES) {
  if (!fs.existsSync(file)) continue;
  let src;
  try { src = fs.readFileSync(file, 'utf8'); } catch { continue; }
  if (src.length < 50_000) continue;

  let script, cached;
  const t0 = process.hrtime.bigint();
  try {
    script = new vm.Script(src, { filename: file, produceCachedData: true });
    cached = script.cachedData;
  } catch (e) {
    console.error(`  skip ${path.basename(file)}: ${e.message.slice(0, 80)}`);
    continue;
  }
  const compileMs = Number(process.hrtime.bigint() - t0) / 1e6;
  if (!cached || !cached.length) {
    console.error(`  skip ${path.basename(file)}: no cached data produced`);
    continue;
  }

  // Verify the cache is actually usable -- a rejected cache would invalidate the test.
  const t1 = process.hrtime.bigint();
  const s2 = new vm.Script(src, { filename: file, cachedData: cached });
  const warmMs = Number(process.hrtime.bigint() - t1) / 1e6;

  const name = path.basename(file, '.js');
  fs.writeFileSync(path.join(OUT_DIR, name + '.v8cache'), cached);
  report.push({
    name, source_bytes: Buffer.byteLength(src), cache_bytes: cached.length,
    cache_rejected: !!s2.cachedDataRejected,
    cold_compile_ms: +compileMs.toFixed(1), warm_compile_ms: +warmMs.toFixed(1),
  });
}

fs.writeFileSync(path.join(OUT_DIR, 'manifest.json'), JSON.stringify(report, null, 2));

const pad = (s, n) => String(s).padEnd(n);
const rpad = (s, n) => String(s).padStart(n);
console.log('\nB3a — real V8 code cache from real production bundles\n');
console.log(pad('bundle', 24) + rpad('source', 10) + rpad('v8 cache', 10) +
            rpad('ratio', 8) + rpad('cold compile', 14) + rpad('with cache', 12));
console.log('-'.repeat(78));
let totalSrc = 0, totalCache = 0, totalCold = 0, totalWarm = 0;
for (const r of report) {
  totalSrc += r.source_bytes; totalCache += r.cache_bytes;
  totalCold += r.cold_compile_ms; totalWarm += r.warm_compile_ms;
  console.log(pad(r.name.slice(0, 23), 24) +
    rpad((r.source_bytes / 1024).toFixed(0) + 'K', 10) +
    rpad((r.cache_bytes / 1024).toFixed(0) + 'K', 10) +
    rpad((r.cache_bytes / r.source_bytes).toFixed(2) + 'x', 8) +
    rpad(r.cold_compile_ms.toFixed(1) + 'ms', 14) +
    rpad(r.warm_compile_ms.toFixed(1) + 'ms' + (r.cache_rejected ? ' REJECTED' : ''), 12));
}
console.log('-'.repeat(78));
console.log(pad('TOTAL', 24) + rpad((totalSrc / 1024).toFixed(0) + 'K', 10) +
  rpad((totalCache / 1024).toFixed(0) + 'K', 10) +
  rpad((totalCache / totalSrc).toFixed(2) + 'x', 8) +
  rpad(totalCold.toFixed(0) + 'ms', 14) + rpad(totalWarm.toFixed(0) + 'ms', 12));
console.log(`\n  ${(totalCache / 1024).toFixed(0)} KB of code cache per process that loads these.`);
console.log(`  Compile time saved by the cache: ${(100 * (1 - totalWarm / totalCold)).toFixed(0)}%`);
