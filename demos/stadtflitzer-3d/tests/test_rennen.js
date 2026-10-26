// Abnahmetest für js/race.js (SF.Rennen) – Aufruf: node tests/test_rennen.js
// Schnittstelle:
//   const r = new SF.Rennen({ strecke, autos: [spieler, ...gegner], runden: 3, scene })
//   r.status: 'countdown' | 'laeuft' | 'ziel';  r.countdown (Sekunden bis LOS, beginnt bei 3)
//   r.update(dt, eingabeSpieler)  – Countdown, Fahren (Spieler mit eingabeSpieler, Gegner mit kiEingabe), Runden, Plätze, Power-ups
//   r.runde(auto) (1…runden), r.platz(auto) (1…n), r.zeit (Sekunden seit LOS), r.rundenzeiten(auto) (Array)
//   r.powerups: Array von { position: THREE.Vector3, art: 'turbo' | 'wasserbombe' | 'oel', aktiv: bool }
//   auto.powerup: null oder art;  r.benutze(auto)  – setzt das Power-up ein
const { THREE, SF, DATEN, pruefe, ende } = require('./umgebung');
pruefe('SF.Rennen existiert', typeof SF.Rennen === 'function');
if (typeof SF.Rennen !== 'function' || typeof SF.Auto !== 'function') ende();
const scene = new THREE.Scene();
const welt = SF.baueWelt(scene, DATEN.muenchen);
const strecke = { kurve: welt.kurve, breite: welt.breite };
const neu = () => {
  const autos = [0xFCC419, 0x3366ff, 0xdd3333, 0x33aa55].map((f, i) => new SF.Auto({ farbe: f, name: i ? 'KI ' + i : 'Du' }));
  return { autos, r: new SF.Rennen({ strecke, autos, runden: 3, scene }) };
};
const dt = 1 / 60, gas = { gas: 1, bremse: 0, lenkung: 0 };
let { autos, r } = neu();
pruefe('Start im Countdown (3 s)', r.status === 'countdown' && r.countdown > 2.5, r.status + ' ' + r.countdown);
const p0 = autos[0].position.clone();
for (let i = 0; i < 1.5 / dt; i++) r.update(dt, gas);
pruefe('Während des Countdowns fährt niemand', autos[0].position.distanceTo(p0) < 0.5, autos[0].position.distanceTo(p0).toFixed(2));
for (let i = 0; i < 2 / dt; i++) r.update(dt, gas);
pruefe('Nach 3 s: Rennen läuft', r.status === 'laeuft', r.status);
pruefe('Startaufstellung: Autos stehen nicht aufeinander', autos[0].position.distanceTo(autos[1].position) > 2.5, autos[0].position.distanceTo(autos[1].position).toFixed(1));
pruefe('Runde beginnt bei 1', r.runde(autos[0]) === 1, r.runde(autos[0]));
const plaetze = autos.map(a => r.platz(a)).sort();
pruefe('Plätze 1–4 je einmal vergeben', plaetze.join() === '1,2,3,4', plaetze.join());
pruefe('Mindestens 4 Power-ups auf der Strecke', Array.isArray(r.powerups) && r.powerups.length >= 4, r.powerups && r.powerups.length);
const pu = r.powerups[0]; autos[0].position.copy(pu.position); r.update(dt, { gas: 0, bremse: 0, lenkung: 0 });
pruefe('Power-up aufsammeln', autos[0].powerup !== null && autos[0].powerup !== undefined, autos[0].powerup);
const lenkt = () => Object.assign(autos[0].kiEingabe(strecke), { gas: 1, bremse: 0 });   // KI lenkt, Vollgas
let spitze = 0;
for (const t of [0.1, 0.3, 0.6]) {   // an drei Stellen probieren – vor einer engen Kurve bremst die Wand jeden aus
  autos[0].setzeAufStrecke(strecke.kurve, t, 0);
  for (let i = 0; i < 4 / dt; i++) autos[0].update(dt, lenkt(), strecke);   // erst auf Tempo
  autos[0].powerup = 'turbo'; r.benutze(autos[0]);
  for (let i = 0; i < 1.5 / dt; i++) { autos[0].update(dt, lenkt(), strecke); spitze = Math.max(spitze, autos[0].tempo); }
}
pruefe('Turbo macht schneller als normal möglich (> 40 m/s kurz nach Einsatz)', spitze > 40, spitze.toFixed(1));
({ autos, r } = neu());
let sek = 0; while (r.status !== 'ziel' && sek < 600) { r.update(dt, autos[0].kiEingabe(strecke)); sek += dt; }
pruefe('Rennen endet (Status ziel) nach 3 Runden', r.status === 'ziel', r.status + ' nach ' + sek.toFixed(0) + ' s');
pruefe('Spieler hat 3 Rundenzeiten', r.rundenzeiten(autos[0]).length === 3, JSON.stringify(r.rundenzeiten(autos[0])));
pruefe('Rennzeit plausibel (60–400 s)', r.zeit > 60 && r.zeit < 400, r.zeit && r.zeit.toFixed(0));
ende();
