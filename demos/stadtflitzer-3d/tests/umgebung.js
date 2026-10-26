// Testumgebung: three.js und die Spieldateien in node laden (ohne Browser/Grafikkarte).
// Aufruf in Tests: const U = require('./umgebung'); dann U.THREE, U.SF, U.DATEN.
const path = require('path');
const root = path.join(__dirname, '..');
global.window = global; global.self = global;
const ctx2d = new Proxy({}, { get: (t, k) => k === 'measureText' ? (() => ({ width: 100 })) : (k in t ? t[k] : () => {}), set: (t, k, v) => (t[k] = v, true) });
global.document = { createElement: () => ({ width: 0, height: 0, style: {}, getContext: () => ctx2d, addEventListener() {} }),
  readyState: 'loading', addEventListener() {}, getElementById: () => null, body: { appendChild() {} } };
global.navigator = { userAgent: 'node' };
global.requestAnimationFrame = () => 0;
global.THREE = require(path.join(root, 'lib/three.min.js'));
for (const s of ['muenchen', 'hamburg', 'berlin', 'koeln']) require(path.join(root, 'data', s + '.js'));
const fs = require('fs');
for (const f of ['world.js', 'car.js', 'race.js']) { const p = path.join(root, 'js', f); if (fs.existsSync(p)) require(p); }
let fehler = 0, ok = 0;
function pruefe(name, bedingung, info) {
  if (bedingung) { ok++; console.log('✓ ' + name); } else { fehler++; console.log('✗ ' + name + (info !== undefined ? ' – ' + info : '')); }
}
function ende() { console.log(`\n${ok} bestanden, ${fehler} fehlgeschlagen`); process.exit(fehler ? 1 : 0); }
module.exports = { THREE: global.THREE, SF: global.SF, DATEN: global.SF_DATEN, pruefe, ende };
