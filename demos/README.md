# Demos für den Alltag

Echte Büroaufgaben mit Beispieldateien zum Ausprobieren – und dem Ergebnis, das KI/lokal auf einem
**MacBook Air M4 mit 24 GB** (Ornith 1.5 35B, 3 Bit, komplett offline) tatsächlich erzeugt hat.
**Hier steht nur, was in drei von drei Läufen richtig war** – automatisch gegen die richtigen Werte geprüft.
Alle Namen, Firmen und Beträge sind frei erfunden.

| Demo | Was passiert | Dauer (3 Läufe) | Skill |
|---|---|---|---|
| [Rechnungen ordnen](rechnungen-ordnen/) | 6 PDF-Rechnungen → Excel-Übersicht mit Summen je Monat und gesamt | 70 · 104 · 95 s | `rechnungen-ordnen` |
| [Angebot schreiben](angebot-schreiben/) | Kundenmail + Preisliste → Angebot als Word-Datei mit Rabatt, USt, Budget-Abgleich | 276 · 99 · 83 s | `angebot-erstellen` |

Beide brauchen KI/lokal **0.7.1** oder neuer.

## Das Prinzip: das Modell versteht, die App rechnet

Das lokale Modell liest Rechnungen, Mails und Preislisten zuverlässig richtig. Rechnen kann es nicht zuverlässig –
in unseren Tests lagen Summen um Cent-Beträge daneben, einmal 2.520 € statt 3.120 €. Deshalb rechnet in KI/lokal die
App: Der Agent sagt nur, **was** summiert wird (`totals` bei `create_document`), die App baut die Summenzeilen, rechnet
Formeln aus und meldet die Werte zurück. Für Rechnungen im Text gibt es `calculate`, für Fristen `date_calc`, für
Tabellen `table_summary` – und ein Rechen-Check verlangt eine Korrektur, wenn in der Antwort eine Rechnung nicht stimmt.

## Noch nicht zuverlässig (deshalb nicht veröffentlicht)

Diese Aufgaben haben wir ebenfalls gebaut und geprüft. Sie sind im letzten Prüflauf an mindestens einem Lauf
gescheitert und deshalb nicht dabei:

| Aufgabe | Ergebnis | Woran es lag |
|---|---|---|
| Meeting nachbereiten (Aufnahme → Protokoll mit Fristen) | 0 von 2 | Transkript und Aufgaben richtig, aber „bis Freitag“ wurde zum falschen Datum |
| Umsätze auswerten (Excel → Gewinn je Bereich) | 1 von 2 | ein Lauf scheiterte an einem Fehler in `table_summary` (inzwischen behoben, noch nicht erneut geprüft) |
| Vertrag durchsehen (Fristen, Kosten, Klauseln) | 1 von 2 | Kosten über die Laufzeit falsch zusammengesetzt |
| Fragen ans Handbuch (Antworten mit Quelle) | 1 von 2 | anteiliger Urlaub falsch gerechnet (16,8 Tage) |

Die Muster sind dieselben wie oben: Verstehen klappt, Rechnen und Datumsrechnung nicht immer. Je mehr davon die App
übernimmt, desto mehr Aufgaben schaffen die drei von drei.

## So probierst du eine Demo aus

**In der App:** Neues Projekt mit einer Kopie des Ordners `eingabe` der Demo anlegen (Seitenleiste → *Neues Projekt*),
dann den Auftrag aus der README der Demo einfügen.

**Im Terminal:** siehe die README der Demo – der Auftrag erscheint live in der App, Freigaben erteilst du dort.

Eigene Skills entstehen aus jedem gelungenen Gespräch: Rechtsklick → *Als Skill speichern*.

## Experiment

[Stadtflitzer 3D](stadtflitzer-3d/) – ein 3D-Rennspiel durch echte Innenstädte. Kein Alltagswerkzeug, sondern ein
Belastungstest: Er zeigt ehrlich, wo das lokale Modell an Grenzen stößt (die 3D-Engine musste ein großes Cloud-Modell
schreiben).
