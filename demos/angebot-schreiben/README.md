# Angebot schreiben

**Eingabe:** Eine Kundenanfrage per Mail ([`anfrage.txt`](eingabe/anfrage.txt)) und eine Preisliste
([`preisliste.csv`](eingabe/preisliste.csv)). Alles frei erfunden.

**Auftrag:**

> Schreib aus der Kundenanfrage (anfrage.txt) und unserer Preisliste (preisliste.csv) ein Angebot als Word-Datei.

## So läuft es

1. Der Agent lädt den Skill [`angebot-erstellen`](../../app/Resources/Skills/angebot-erstellen/SKILL.md), liest Anfrage
   und Preisliste und legt die Positionen fest – **das Modell versteht**: halber Workshop, 8 Teilnehmende bei
   „bis 6 inklusive“ → 2 zusätzliche, Einrichtung auf 4 Macs, Support, Anfahrt 95 km hin und zurück.
2. Er schreibt das Angebot mit Anschreiben und der Positionstabelle und sagt der App, wie gerechnet wird
   (`totals`: Zeilenbetrag = Menge × Einzelpreis, Summe, 5 % Paketrabatt, 19 % USt). **Die App rechnet** Zeilen,
   Zwischensumme, Rabatt, Netto, USt und Brutto aus und meldet die Werte zurück.
3. Im Chat: Summen, Abgleich mit dem Budget, höchstens zwei offene Fragen an die Kundin.

## Ergebnis

Gemessen auf einem MacBook Air M4 mit 24 GB, Ornith 1.5 35B (3 Bit), offline:

| Lauf | Dauer | Ergebnis |
|---|---|---|
| 1 | 276 s | ✅ Netto 3.054,25 € · Brutto 3.634,56 € (Modell beim Start neu geladen) |
| 2 | 99 s | ✅ dieselben Summen |
| 3 | 83 s | ✅ dieselben Summen |

Ergebnis von Lauf 3: [`ergebnis/Angebot_Physiotherapie_Keller.docx`](ergebnis/Angebot_Physiotherapie_Keller.docx) und
die [Antwort im Chat](ergebnis/antwort-im-chat.md).

Geprüft wurde automatisch: Netto und Brutto im Word-Dokument und im Chat.

## Ausprobieren

```bash
cp -R demos/angebot-schreiben/eingabe ~/Desktop/angebot
"/Applications/KI lokal.app/Contents/MacOS/KI lokal" --agent "Schreib aus der Kundenanfrage (anfrage.txt) und unserer Preisliste (preisliste.csv) ein Angebot als Word-Datei." --workspace ~/Desktop/angebot
```

Oder in der App: *Neues Projekt* mit dem kopierten Ordner, dann den Auftrag einfügen. Braucht KI/lokal 0.7.1 oder neuer.
Für eigene Angebote: Preisliste austauschen und in den Projektanweisungen Absender und Bankverbindung hinterlegen.
