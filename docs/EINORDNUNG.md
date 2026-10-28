# KI/lokal – ehrliche Einordnung

Was kann eine KI, die komplett auf einem MacBook läuft, im Vergleich zu ChatGPT, Claude, Gemini oder Microsoft Copilot?
Gemessen und erprobt auf einem **MacBook Air M4 mit 24 GB** (lüfterlos) mit **Ornith 1.5 35B** (3 Bit) – dem kleinsten
Mac, auf dem KI/lokal sinnvoll läuft.

![Agent mit Projekt-Leiste](bilder/agent-projekt.png)

## Kurzfassung

- **Für einen großen Teil der Alltagsarbeit ist KI/lokal eine echte Alternative**: Texte, E-Mails, Zusammenfassungen,
  Protokolle, Transkription, Tabellen, kleine Werkzeuge und Webseiten – privat, offline, ohne laufende Kosten.
- **Kein vollständiger Ersatz für die besten Cloud-Modelle**: Bei schwierigem Denken, großen Programmierprojekten und
  sehr langen Dokumenten sind Claude, GPT oder Gemini spürbar besser.
- **Empfehlung: hybrid.** Lokal als Standard – vor allem für alles Vertrauliche –, Cloud gezielt für die schweren Fälle.
  KI/lokal kann beides: Cloud-Modelle sind wählbar, und der lokale Agent kann einen **Cloud-Experten** nur für eine
  schwierige Teilfrage hinzuziehen.

## Der Zuschnitt: kurze Aufgaben, „das Modell versteht, die App rechnet“

Beim Bau der [Alltags-Demos](../demos/README.md) zeigte sich, wo ein 35B-Modell in 3 Bit auf 24 GB verlässlich ist und wo
nicht:

| Verlässlich | Nicht verlässlich |
|---|---|
| Inhalte lesen und verstehen (Rechnungsdaten, Vertragsklauseln, Gesprächsinhalte) | Rechnen – Summen weichen um Cent-Beträge ab, auch nach richtiger Rechnung im Werkzeug |
| Texte formulieren, zusammenfassen, übersetzen | Lange Ketten über 15+ Schritte – der Speicher wird knapp, das Modell verzettelt sich |
| Kurze Aufträge mit einem klaren Ergebnis (2–4 Minuten) | Eigene Ergebnisse kontrollieren – es „verbessert“ fertige Dateien und macht sie schlechter |

Deshalb übernimmt KI/lokal alles, was exakt sein muss: Der Agent schreibt in Tabellen Formeln (=C2*D2, =SUM(E2:E6)),
die App rechnet sie aus – in Excel bleiben sie Formeln, in Word und PDF stehen die Zahlen – und meldet die Werte zurück,
damit Chat und Dokument übereinstimmen. Dateien ändert der Agent nur über eigene Werkzeuge, mit Freigabe. Veröffentlicht sind nur
Demos, die drei von drei Läufen richtig bestanden haben (Rechnungen, Angebot); was das nicht schaffte – Meeting mit
Fristen, Umsatz-Auswertung, Vertragsprüfung, Handbuch-Fragen –, steht mit Grund in der [Demo-Übersicht](../demos/README.md).

## Gemessen, nicht geschätzt

| | MacBook Air M4, 24 GB |
|---|---|
| Antworttempo im Chat | **43 tok/s** (schneller als man liest) |
| Code bearbeiten (mit Lightning MTP) | **77 tok/s** |
| Dauerlast 10 Minuten, lüfterlos | ~30 tok/s (−24 % durch Wärme) |
| Kontextfenster | **32k Tokens** (≈ 80 Seiten Text); im Agenten bis 29,5k gemessen |
| Langes Dokument neu einlesen | ~20k Tokens in 2,5 Minuten |
| Speicherbedarf des Modells | 16,6 GB – daneben bleibt Platz für Browser, Mail, Office |

Rohdaten: [`benchmarks/results`](../benchmarks/results).

![Übersicht mit Nutzung, Speicher und Temperatur](bilder/uebersicht.png)

## Vorteile

- **Datenschutz ohne Kompromiss.** Gespräche, Dateien, Aufnahmen und Ergebnisse bleiben auf dem Mac. Kein
  Auftragsverarbeitungsvertrag, keine Datenübermittlung in Drittländer, kein Training mit deinen Daten. Ins Netz geht
  nur, was du ausdrücklich erlaubst (Websuche, Browser, Cloud-Experte).
- **Keine laufenden Kosten, keine Limits.** Kein Abo, keine Nachrichtengrenzen, keine Drosselung zur Stoßzeit.
- **Offline.** Im Zug, im Flugzeug, beim Kunden ohne WLAN.
- **Gehört dir.** Das Modell ändert sich nicht über Nacht, Ergebnisse bleiben reproduzierbar, kein Anbieter kann
  Funktionen streichen oder Preise erhöhen.
- **Tief im Mac.** Dateien und Projektordner, Kalender, Erinnerungen, Mail-Entwürfe, Bildschirm, Browser,
  Spracheingabe und Transkription – alles lokal.
- **Fertige Assistenten und Automationen.** Ein Klick für Meeting-Protokoll, Excel-Auswertung oder „Mein Tag“; eigene
  Assistenten entstehen aus jedem Gespräch.
- **Fürs Team.** Ein Mac im Büro kann das Modell im Heimnetz freigeben – für Kolleginnen, iPhone und andere Programme.
- **Durchschaubar.** Jeder Arbeitsschritt, Tokens, Tempo, Speicher und Chip-Temperatur sind sichtbar.

## Nachteile und Grenzen

- **Weniger klug als die Spitzenmodelle.** Ein 35B-Modell in 3 Bit macht bei kniffligen Aufgaben mehr Fehler,
  übersieht eher etwas und braucht Aufträge in kleineren Schritten. Ein Beispiel ist [Stadtflitzer 3D](../demos/stadtflitzer-3d/README.md):
  Die Datenpipeline und die vierte Stadt hat der lokale Agent gebaut, die 3D-Engine musste ein großes Modell übernehmen.
- **Kürzeres Gedächtnis.** 32k Tokens statt 200k bis 1 Mio. in der Cloud. Ein 300-Seiten-Vertrag passt nicht am
  Stück hinein; die App kürzt ältere Schritte automatisch, Dateien werden abschnittsweise gelesen.
- **Lange Eingaben brauchen Zeit.** Ein langes Dokument einzulesen dauert Minuten statt Sekunden.
- **Hardware nötig.** Apple Silicon mit mindestens 24 GB. Das Modell belegt 16,6 GB – bei vielen offenen Programmen wird
  es eng. Bei Dauerlast wird das MacBook Air warm und langsamer, der Akku hält kürzer.
- **Kein Bild- oder Videogenerator**, Bildverständnis nur mit zusätzlichem Vision-Modell.
- **Recherche einfacher.** Websuche und Seitenlesen funktionieren, aber nicht auf dem Niveau der „Deep Research“-Funktionen
  der Cloud-Anbieter.
- **Selbst betreiben.** Updates, 17-GB-Modell-Downloads, kein Support-Vertrag. Die App nimmt das meiste ab, ein Rest
  bleibt.

## Reale Anwendungsszenarien

| Szenario | Wie | Eignung lokal |
|---|---|---|
| **Meeting-Protokoll** aus Teams-/Zoom-Aufnahme | Assistent „Meeting-Protokoll“: Transkript, Entscheidungen, Aufgaben als Word-Datei | ●●● ideal, vertraulich |
| **Sprachnachrichten** (WhatsApp, Diktat) in Text | Assistent „Transkribieren“, auch `.ogg` | ●●● ideal |
| **Verträge, Angebote, Personalunterlagen** zusammenfassen | Datei anhängen → „Dokument zusammenfassen“ | ●●● ideal bis ~80 Seiten |
| **E-Mails beantworten**, Texte überarbeiten, LinkedIn-Beiträge | Assistenten mit editierbarem Canvas | ●●● sehr gut |
| **Excel auswerten** (Umsätze, Listen, Auffälligkeiten) | „Excel auswerten“ → Bericht als PDF | ●●○ gut für Überblick, Zahlen gegenprüfen |
| **Eigenes Wissen durchsuchen** (Handbücher, Richtlinien, Projektordner) | Bereich „Wissen“, Antworten mit Quelle | ●●○ gut |
| **Tagesstart**: Termine, Erinnerungen, wichtigste Mails | Assistent „Mein Tag“, als Automation jeden Morgen | ●●● sehr gut |
| **Kleine Werkzeuge und Webseiten** (Rechner, Formular, Landingpage, Skript) | Agent im Code-Projekt, Vorschau und Prüfung eingebaut | ●●○ gut in kleinen Schritten |
| **Workshops und Schulungen beim Kunden** | Offline-Demo auf dem eigenen Laptop, ohne Konten und Datenfreigabe | ●●● ideal |
| **Team-KI im Büro** | Ein Mac gibt das Modell im Netzwerk frei | ●●○ für kleine Teams |
| Großes Software-Projekt, Architektur, Refactoring über viele Dateien | | ●○○ besser Cloud (oder Cloud-Experte) |
| Ausführliche Recherche mit vielen Quellen | | ●○○ besser Cloud |
| Sehr lange Dokumente am Stück (> 100 Seiten) | | ●○○ besser Cloud |

![Assistenten](bilder/assistenten.png)

## Abgrenzung zu den Bezahl-Diensten

| | **KI/lokal** | **ChatGPT Plus / Claude Pro / Google AI Pro** | **Microsoft 365 Copilot** |
|---|---|---|---|
| Kosten | 0 € laufend (Mac mit ≥ 24 GB vorausgesetzt) | rund 18–23 € pro Person und Monat; Profi-Stufen 100–250 € | rund 18–30 $ pro Person und Monat **zusätzlich** zur Microsoft-365-Lizenz |
| Datenschutz | alles auf dem Gerät | Daten beim Anbieter (USA), je nach Tarif Training abschaltbar | Daten im Microsoft-Tenant |
| Qualität bei schweren Aufgaben | solide, aber deutlich unter der Spitze | Spitzenklasse | Spitzenmodelle, auf Office zugeschnitten |
| Gedächtnis (Kontext) | 32k Tokens | 200k bis 1 Mio. | groß, über Office-Dokumente |
| Offline | ja | nein | nein |
| Nutzungsgrenzen | keine | Nachrichtenlimits je Zeitfenster | Kontingente |
| Integration | Mac: Dateien, Kalender, Mail, Bildschirm, Terminal | Web und Apps, Connectoren | Word, Excel, Outlook, Teams |
| Bilder/Video erzeugen | nein | ja | ja |

Preise: Listenpreise laut Anbietern bzw. Fachpresse, Stand Oktober 2026 – ohne Gewähr, vor einer Entscheidung auf den
Preisseiten prüfen.

**Rechenbeispiel:** Ein Team mit 10 Personen zahlt für Standard-Abos rund **2 200–2 800 € im Jahr**. Mit KI/lokal fallen
keine laufenden Kosten an, wenn Macs mit 24 GB oder mehr vorhanden sind. Für die schweren 10–20 % der Aufgaben reicht oft
ein Cloud-Zugang über die API, der nur nach Verbrauch abgerechnet wird, oder ein einzelnes Abo.

### So würden wir es einsetzen

1. **KI/lokal als Standard** für Schreiben, Zusammenfassen, Protokolle, Transkription, Mail, Tagesplanung und alles mit
   Kunden-, Personal- oder Geschäftsdaten.
2. **Cloud gezielt** für komplexe Programmierung, lange Recherchen und sehr große Dokumente – in KI/lokal als
   wählbares Modell oder als **Cloud-Experte**, den der lokale Agent nur für die eine schwere Teilfrage fragt
   (ohne die vertraulichen Dateien mitzuschicken).
3. **Ergebnisse prüfen** wie bei jeder KI: Zahlen, Zitate und rechtlich relevante Aussagen gegenlesen.

Quellen zu den Preisen: [Notebookcheck – Was KI-Abos 2026 kosten](https://www.notebookcheck.com/Was-KI-Abos-2026-kosten-und-welches-sich-lohnt.1334996.0.html),
[eWeek – AI Pricing Cheat Sheet](https://www.eweek.com/news/ai-pricing-cheat-sheet-2026/),
[eesel – Copilot pricing 2026](https://eesel.ai/blog/copilot-pricing).
