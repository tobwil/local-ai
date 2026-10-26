// Abnahmetest für js/car.js (SF.Auto) – Aufruf: node tests/test_auto.js
// Schnittstelle (siehe DESIGN.md, Abschnitt „Schnittstellen“):
//   const a = new SF.Auto({ farbe: 0xFCC419, name: 'Du' });  a.mesh (THREE.Group)
//   a.setzeAufStrecke(kurve, t, versatz)   – an Kurvenposition t (0…1), seitlich um versatz Meter, Blick in Fahrtrichtung
//   a.update(dt, eingabe, strecke)         – eingabe = { gas, bremse, lenkung } (0…1, 0…1, -1…1); strecke = { kurve, breite }
//   a.position (THREE.Vector3), a.richtung (Winkel um y, Radiant), a.tempo (m/s), a.fortschritt (0…1, nächster Kurvenpunkt)
//   a.kiEingabe(strecke)                   – Eingabe für einen Computer-Gegner
const { THREE, SF, DATEN, pruefe, ende } = require('./umgebung');
pruefe('SF.Auto existiert', typeof SF.Auto === 'function');
if (typeof SF.Auto !== 'function') ende();
const welt = SF.baueWelt(new THREE.Scene(), DATEN.muenchen);
const strecke = { kurve: welt.kurve, breite: welt.breite };
const dt = 1 / 60;
const fahre = (a, sek, eing) => { for (let i = 0; i < sek / dt; i++) a.update(dt, eing, strecke); };
const abstandMitte = a => { let best = 1e9; for (let i = 0; i < 400; i++) { const p = strecke.kurve.getPointAt(i / 400); best = Math.min(best, Math.hypot(p.x - a.position.x, p.z - a.position.z)); } return best; };

const a = new SF.Auto({ farbe: 0xFCC419, name: 'Du' });
let teile = 0; a.mesh && a.mesh.traverse(o => { if (o.isMesh) teile++; });
pruefe('Modell aus mindestens 6 Teilen (Körper, 4 Räder, Spoiler/Antenne)', teile >= 6, teile + ' Teile');
a.setzeAufStrecke(strecke.kurve, 0.1, 0);
pruefe('setzeAufStrecke setzt das Auto auf die Mittellinie', abstandMitte(a) < 1.5, abstandMitte(a).toFixed(1) + ' m');
const start = a.position.clone();
fahre(a, 3, { gas: 1, bremse: 0, lenkung: 0 });
pruefe('3 s Vollgas: 15–40 m/s', a.tempo > 15 && a.tempo <= 40, a.tempo.toFixed(1) + ' m/s');
pruefe('3 s Vollgas: mindestens 25 m gefahren', a.position.distanceTo(start) > 25, a.position.distanceTo(start).toFixed(1) + ' m');
pruefe('fortschritt wächst beim Fahren', a.fortschritt > 0.1 && a.fortschritt < 0.3, a.fortschritt);
fahre(a, 15, { gas: 1, bremse: 0, lenkung: 0 });
pruefe('Höchstgeschwindigkeit ≤ 40 m/s', a.tempo <= 40.5, a.tempo.toFixed(1));
const b = new SF.Auto({ farbe: 0x3366ff, name: 'Test' }); b.setzeAufStrecke(strecke.kurve, 0.3, 0);
fahre(b, 2, { gas: 1, bremse: 0, lenkung: 0 }); const r0 = b.richtung;
fahre(b, 0.6, { gas: 1, bremse: 0, lenkung: 1 });
pruefe('Lenken dreht das Auto', Math.abs(b.richtung - r0) > 0.15, (b.richtung - r0).toFixed(2) + ' rad');
fahre(b, 2.5, { gas: 0, bremse: 1, lenkung: 0 });
pruefe('Bremsen: nach 2,5 s fast stehend (< 5 m/s)', Math.abs(b.tempo) < 5, b.tempo.toFixed(1));
const c = new SF.Auto({ farbe: 0x33aa55, name: 'Rand' }); c.setzeAufStrecke(strecke.kurve, 0.5, 0);
c.richtung += Math.PI / 2;  // quer zur Straße
fahre(c, 3, { gas: 1, bremse: 0, lenkung: 0 });
pruefe('Straßenrand: Auto bleibt auf der Straße (≤ 9 m von der Mitte)', abstandMitte(c) <= 9, abstandMitte(c).toFixed(1) + ' m');
pruefe('Straßenrand bremst ab (< 25 m/s)', c.tempo < 25, c.tempo.toFixed(1));
pruefe('kiEingabe existiert', typeof SF.Auto.prototype.kiEingabe === 'function');
const k = new SF.Auto({ farbe: 0xdd3333, name: 'KI' }); k.setzeAufStrecke(strecke.kurve, 0, 0);
let maxAb = 0, weg = 0, letzter = k.fortschritt;
for (let i = 0; i < 60 / dt; i++) {
  k.update(dt, k.kiEingabe(strecke), strecke);
  if (i % 30 === 0) { maxAb = Math.max(maxAb, abstandMitte(k)); let d = k.fortschritt - letzter; if (d < -0.5) d += 1; if (d > 0) weg += d; letzter = k.fortschritt; }
}
pruefe('KI fährt in 60 s mindestens eine halbe Runde', weg > 0.5, (weg * 100).toFixed(0) + ' %');
pruefe('KI bleibt auf der Straße (≤ 9 m)', maxAb <= 9, maxAb.toFixed(1) + ' m');
ende();
