# Rechnungen ordnen

**Eingabe:** Sechs Rechnungen als PDF – mit wenig hilfreichen Namen wie `scan_0042.pdf` oder `ticket.pdf`
([`eingabe/`](eingabe/)). Alle Firmen und Beträge sind frei erfunden.

**Auftrag:**

> Lies die Rechnungen in diesem Ordner und leg eine Excel-Übersicht an: Datum, Firma, Betrag, Summe je Monat und gesamt.

## So läuft es

1. Der Agent erkennt den Auftrag und lädt den Skill [`rechnungen-ordnen`](../../app/Resources/Skills/rechnungen-ordnen/SKILL.md).
2. Er liest jede PDF einmal und zieht Datum, Firma, Rechnungsnummer und Beträge heraus – **das Modell versteht**.
3. Er erstellt die Excel-Datei nur mit den Rechnungszeilen und sagt der App, was summiert werden soll
   (`totals: {"sum": ["Brutto"], "per_month": true}`). **Die App rechnet:** Sie sortiert nach Datum, baut die Zeilen
   „Summe September 2026“, „Summe Oktober 2026“ und „Gesamt“ als echte Excel-Formeln und meldet die Werte zurück.
4. Im Chat nennt der Agent genau diese Werte und weist auf die ausländische Rechnung hin (Reverse Charge mit der
   Steuerberatung klären).

## Ergebnis

Gemessen auf einem MacBook Air M4 mit 24 GB, Ornith 1.5 35B (3 Bit), offline:

| Lauf | Dauer | Ergebnis |
|---|---|---|
| 1 | 70 s | ✅ September 683,23 € · Oktober 216,39 € · gesamt 899,62 € |
| 2 | 104 s | ✅ dieselben Summen |
| 3 | 95 s | ✅ dieselben Summen |

Ergebnis von Lauf 3: [`ergebnis/rechnungen-uebersicht.xlsx`](ergebnis/rechnungen-uebersicht.xlsx) und die
[Antwort im Chat](ergebnis/antwort-im-chat.md).

Geprüft wurde automatisch: die Werte der Summenformeln in der Excel-Datei und die Summen im Chat.

## Ausprobieren

```bash
cp -R demos/rechnungen-ordnen/eingabe ~/Desktop/rechnungen
"/Applications/KI lokal.app/Contents/MacOS/KI lokal" --agent "Lies die Rechnungen in diesem Ordner und leg eine Excel-Übersicht an: Datum, Firma, Betrag, Summe je Monat und gesamt." --workspace ~/Desktop/rechnungen
```

Oder in der App: *Neues Projekt* mit dem kopierten Ordner, dann den Auftrag einfügen. Braucht KI/lokal 0.7.1 oder neuer.

**Grenze:** Umbenennen und in Monatsordner sortieren kann der Skill auch – in einem eigenen, zweiten Auftrag. Alles
in einem Auftrag war in unseren Tests nicht zuverlässig.
