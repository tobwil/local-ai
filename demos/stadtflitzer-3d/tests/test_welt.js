// Abnahmetest für js/world.js – Aufruf: node tests/test_welt.js
const { THREE, SF, DATEN, pruefe, ende } = require('./umgebung');
pruefe('SF.baueWelt existiert', typeof SF.baueWelt === 'function');
for (const stadt of ['muenchen', 'hamburg', 'berlin', 'koeln']) {
  const scene = new THREE.Scene();
  const t0 = Date.now(); let r;
  try { r = SF.baueWelt(scene, DATEN[stadt]); } catch (e) { pruefe(stadt + ': baueWelt ohne Fehler', false, e.message); continue; }
  const ms = Date.now() - t0;
  pruefe(stadt + ': schnell genug (< 1500 ms)', ms < 1500, ms + ' ms');
  pruefe(stadt + ': gibt { kurve, breite: 14 } zurück', r && r.kurve && r.kurve.getPointAt && r.breite === 14, r && Object.keys(r));
  let nan = 0, maxY = 0, dreiecke = 0, indexFehler = 0;
  scene.traverse(o => {
    if (!o.isMesh || !o.geometry || !o.geometry.attributes.position) return;
    const pos = o.geometry.attributes.position.array;
    for (let i = 0; i < pos.length; i++) { if (!isFinite(pos[i])) nan++; if (i % 3 === 1 && pos[i] > maxY) maxY = pos[i]; }
    const idx = o.geometry.index;
    if (idx) { const n = pos.length / 3; for (let i = 0; i < idx.count; i++) if (idx.array[i] >= n) { indexFehler++; break; } dreiecke += idx.count / 3; }
    else dreiecke += pos.length / 9;
  });
  pruefe(stadt + ': keine NaN-Koordinaten', nan === 0, nan + ' ungültige Werte');
  pruefe(stadt + ': keine Indizes hinter dem Ende', indexFehler === 0, indexFehler + ' Geometrien');
  const n = DATEN[stadt].gebaeude.length;
  pruefe(stadt + ': Gebäude haben Wände und Dächer (≥ 10 Dreiecke je Gebäude)', dreiecke >= n * 10, Math.round(dreiecke) + ' Dreiecke für ' + n + ' Gebäude');
  pruefe(stadt + ': Gebäude sind hoch (höchster Punkt > 15 m)', maxY > 15, Math.round(maxY) + ' m');
  // Straße (texturiertes Band knapp über dem Boden) muss nach oben zeigen, sonst ist sie von oben unsichtbar
  let strasse = null;
  scene.traverse(o => { if (o.isMesh && o.material && o.material.map && o.geometry.attributes.uv && !o.geometry.attributes.color && o.geometry.attributes.position.array[1] > 0.04 && o.geometry.attributes.position.array[1] < 0.1) strasse = o; });
  let oben = 0, alle = 1;
  if (strasse) { const n = strasse.geometry.attributes.normal.array; alle = n.length / 3; for (let i = 1; i < n.length; i += 3) if (n[i] > 0.5) oben++; }
  pruefe(stadt + ': Straße sichtbar von oben (Normalen nach oben)', strasse && oben / alle > 0.95, strasse ? oben + '/' + alle : 'Straße nicht gefunden');
}
const fs = require('fs'), src = fs.readFileSync(__dirname + '/../js/world.js', 'utf8');
pruefe('Gebäude-Funktion höchstens einmal definiert', (src.match(/function buildBuildings/g) || []).length <= 1, (src.match(/function buildBuildings/g) || []).length + '×');
ende();
