# Stadtflitzer 3D – Design

Rennspiel mit ferngesteuerten Spielzeugautos (wie der Klassiker Re-Volt) durch **echte Innenstädte**: München, Hamburg,
Berlin. Echte Straßenführung, echte Gebäudeumrisse aus OpenStreetMap, Wahrzeichen. Die Autos sind klein, die Stadt riesig.

## Grundregeln

- **Läuft per Doppelklick auf `index.html`** (auch aus dem Finder, ohne Server): nur klassische `<script src>`-Dateien,
  **keine ES-Module, kein `fetch`, kein `import`**. three.js liegt als `lib/three.min.js` (r149, globales `THREE`).
- Keine externen Downloads im Spiel. Alles Deutsch.
- Gemeinsamer Namensraum: `window.SF = window.SF || {};` in jeder Datei.
- Jede JS-Datei höchstens ~350 Zeilen. Klare Funktionen, kurze Kommentare auf Deutsch.

## Dateien

| Datei | Inhalt |
|---|---|
| `index.html` | Vollbild-Canvas, Overlays (Menü, HUD, Countdown, Ziel), lädt Skripte in dieser Reihenfolge: `lib/three.min.js`, `data/muenchen.js`, `data/hamburg.js`, `data/berlin.js`, `js/world.js`, `js/car.js`, `js/race.js`, `js/ui.js`, `js/main.js` |
| `tools/cities.json` | Strecken (Breite/Länge), Wahrzeichen, Farben, Ausschnitt (bbox), Maßstab je Stadt – **vorgegeben** |
| `tools/osm_daten.py` | holt Gebäude/Wasser/Parks per Overpass-API, rechnet in Meter um, schreibt `data/<stadt>.js` |
| `data/<stadt>.js` | `SF_DATEN.<stadt> = {...}` (Format unten) |
| `js/world.js` | `SF.baueWelt(scene, daten)` – Boden, Straße, Gebäude, Wasser, Parks, Wahrzeichen, Start/Ziel |
| `js/car.js` | `SF.Auto` – Modell, Fahrphysik, Spieler- und KI-Steuerung, Straßenrand |
| `js/race.js` | Runden, Platzierung, Countdown, Power-ups, Zeiten |
| `js/ui.js` | HUD, Minimap, Menü (Stadtwahl), Ziel-Bildschirm |
| `js/main.js` | Renderer, Licht, Kamera, Spielschleife, Tastatur, Start |

## Datenformat `data/<stadt>.js`

```js
window.SF_DATEN = window.SF_DATEN || {};
SF_DATEN.muenchen = {
  name: "München", untertitel: "…", farben: { himmel, boden, strasse, gebaeude, akzent },
  strecke: [[x, z], …],              // Meter, geschlossene Runde, Ursprung = Mittelpunkt der Strecke
  gebaeude: [{ p: [[x, z], …], h: 18 }, …],   // Grundriss (Meter) + Höhe (Meter)
  wasser: [[[x, z], …], …], parks: [[[x, z], …], …],
  wahrzeichen: [{ name, x, z, hoehe, form }, …]
};
```
Koordinaten: x = Osten, z = Süden (three.js: y nach oben). Umrechnung von Breite/Länge um den Mittelpunkt (lat0, lon0):
`x = (lon - lon0) * cos(lat0) * 111320 * massstab`, `z = -(lat - lat0) * 110540 * massstab`, Höhen ebenfalls × massstab.

## Welt

- Straße: Band entlang einer geglätteten, geschlossenen Kurve (`THREE.CatmullRomCurve3`, closed, ~600 Punkte),
  **14 m breit**, dunkelgrau, gestrichelte gelbe Mittellinie, rot-weiße Randsteine. Start/Ziel: Schachbrett-Streifen.
- Gebäude: **eine einzige zusammengefügte Geometrie** (Wände + flache Dächer, `THREE.ShapeUtils.triangulateShape`),
  Farbe aus `farben.gebaeude` mit leichter Helligkeitsvariation pro Gebäude (Vertex-Farben). Keine Gebäude auf der Straße
  (das Datenskript lässt alles weg, was der Mittellinie näher als 11 m kommt).
- Wasser: blaue Flächen knapp über dem Boden; Parks: grün.
- Wahrzeichen als einfache, gut erkennbare Formen nach `form` (turm, zwei_tuerme, tor, welle, kuppel, fernsehturm,
  speicher) in `farben.akzent`/hellen Tönen, darüber ein Namensschild (Sprite mit Canvas-Text).
- Licht: Halbkugellicht + Sonne (Schatten nur für die Autos), Nebel in Himmelsfarbe.

## Autos und Fahren

- Spielzeug-RC-Auto: flacher Körper (≈ 3,6 × 1,8 m), vier dicke Räder, Spoiler, Antenne mit Fähnchen. Spieler gelb
  (#FCC419), Gegner blau, rot, grün.
- Arcade-Physik: Gas/Bremse, Lenken abhängig vom Tempo, Höchstgeschwindigkeit ~38 m/s, **leichtes Driften**
  (Querhaftung < 1), Bremse/Rückwärts.
- Straßenrand: Abstand zur Mittellinie > 7 m → zurückschieben, abprallen, Tempo stark verringern.
- KI: folgt Punkten auf der Kurve mit Vorausschau, etwas Zufall, unterschiedlich schnell (88–97 % des Spielers).

## Rennen

- 3 Runden, Fortschritt über die Kurvenposition (0…1), Platzierung nach (Runde, Fortschritt).
- Countdown 3 – 2 – 1 – LOS!, Rundenzeiten, beste Runde, Zielreihenfolge.
- Power-ups (schwebende, drehende Würfel auf der Strecke, alle ~400 m): **Batterie-Turbo** (3 s schneller),
  **Wasserbombe** (trifft das Auto vor dir, bremst es), **Öllache** (hinter dir, wer drüberfährt, schleudert).
- Tasten: Pfeile oder WASD fahren, **Leertaste** Power-up, **R** zurück auf die Straße, **M** Menü.

## Oberfläche (KIsruptiv-Stil)

- Farben: Dunkelblau #274060, Gold #FCC419, Hellblau #7590BF. Schrift: -apple-system. Abgerundete Karten, leichte Schatten.
- Menü: Titel „Stadtflitzer“, drei Karten (Stadt, Untertitel, Mini-Streckenbild) – Klick startet.
- HUD: oben links Runde 1/3 und Zeit, oben rechts Platz (groß), unten Power-up, rechts unten Minimap (Strecke + Punkte).
- Ziel: Platz, Zeiten, „Nochmal“ und „Andere Stadt“.
- Kamera: hinter dem Auto, tief und dynamisch (sieht die Häuser riesig wirken), sanft nachgeführt.

## Schnittstellen (verbindlich, durch Tests in `tests/` geprüft)

```js
// world.js
SF.baueWelt(scene, daten) → { kurve: THREE.CatmullRomCurve3, breite: 14 }

// car.js
const a = new SF.Auto({ farbe: 0xFCC419, name: 'Du' });   // a.mesh: THREE.Group (Körper, 4 Räder, Spoiler, Antenne)
a.setzeAufStrecke(kurve, t, versatz);   // t 0…1 auf der Kurve, versatz in Metern quer, Blick in Fahrtrichtung
a.update(dt, { gas, bremse, lenkung }, { kurve, breite });   // Physik + Straßenrand; setzt a.mesh.position/rotation
a.position (Vector3), a.richtung (Radiant um y), a.tempo (m/s), a.fortschritt (0…1), a.powerup (null | 'turbo' | 'wasserbombe' | 'oel')
a.kiEingabe({ kurve, breite }) → { gas, bremse, lenkung }   // Computer-Gegner

// race.js
const r = new SF.Rennen({ strecke: { kurve, breite }, autos: [spieler, ki1, ki2, ki3], runden: 3, scene });
r.status ('countdown' | 'laeuft' | 'ziel'), r.countdown (s), r.zeit (s)
r.update(dt, eingabeSpieler)   // Countdown, alle Autos fahren (Gegner mit kiEingabe), Runden, Plätze, Power-ups
r.runde(auto), r.platz(auto), r.rundenzeiten(auto), r.powerups [{ position, art, aktiv }], r.benutze(auto)
```

Tests: `node tests/test_welt.js`, später `tests/test_auto.js` und `tests/test_rennen.js` – alle müssen grün sein.
