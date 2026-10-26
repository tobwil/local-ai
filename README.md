# KI/lokal

**KI für alle – direkt auf deinem Mac.** Ein Tool von [KIsruptiv](https://kisruptiv.de).

KI/lokal holt starke offene Modelle auf Macs mit Apple Silicon – privat, offline, ohne Abo und schnell genug
für den Alltag (≥ 40 tok/s). Gebaut für Macs mit wenig Speicher (ab 24 GB): Die App erkennt die Hardware, empfiehlt das passende Modell, richtet die Engine ein und bringt einen
Agenten mit Werkzeugen, Skills, Plugins, MCP, Browser-Steuerung, Sprache und Vision mit.

⚖️ **[Ehrliche Einordnung](docs/EINORDNUNG.md)** – Vor- und Nachteile, reale Anwendungsszenarien und der Vergleich mit
ChatGPT, Claude, Gemini und Microsoft Copilot. Kurz: für einen großen Teil der Alltagsarbeit eine echte Alternative,
für die schwersten Aufgaben nicht – am besten hybrid.

Das Logo „KI/sruptiv“ ist eine Marke von KIsruptiv. Engine: [oMLX](https://github.com/jundot/omlx) (Apache 2.0).

## Ergebnis auf dem MacBook Air M4 (24 GB, 120 GB/s)

**Ornith-1.5-35B-A3B** ([`mlx-works/Ornith-1.5-35B-A3B-oQ3e-mtp`](https://huggingface.co/mlx-works/Ornith-1.5-35B-A3B-oQ3e-mtp), 16,6 GB) in [oMLX](https://github.com/jundot/omlx):

| Aufgabe | ohne Beschleuniger | mit Lightning MTP |
|---|---|---|
| Chat | **43,1** tok/s | 38,6 |
| Code-Edit (2,7k Prompt) | 41,2 | **77,0** |
| 1k / 4k / 8k Kontext | 42,4 / 40,6 / 40,2 | 38,8 / 37,2 / 36,1 |
| 14k Kontext | 36,0 (TTFT 38 s) | – |
| 32k Kontext | bricht am Speicherlimit ab | – |

Zum Vergleich Qwen3.6-35B-A3B (Unsloth 3 Bit, 17,4 GB): 36 tok/s im Chat, in oMLX Speicherfehler ab ~3k Kontext.
DFlash war in jeder Aufgabe langsamer als MTP. Alle Rohdaten liegen in [`benchmarks/results`](benchmarks/results).

### Warum nicht schneller / länger?

- **Bandbreite:** Pro Token müssen die aktiven Gewichte (~1,1–1,4 GB bei 3 Bit) einmal durch den Speicher.
  Bei 120 GB/s sind ~40–45 tok/s das Dach ohne Spekulation.
- **Kontext:** Ornith hat nur 10 von 40 Schichten mit klassischem KV-Cache – ~20 KB pro Token, 128k wären ~2,7 GB.
  Das Limit ist der Spitzenspeicher beim Einlesen des Prompts: Gewichte (16,6 GB) + Zwischenwerte müssen unter
  das Metal-Limit von 17,76 GiB passen. Mehr Kontext gibt es mit `sudo sysctl iogpu.wired_limit_mb=20480`
  (bis zum Neustart) und einem quantisierten KV-Cache – noch nicht gemessen.
- **Kein Lüfter:** Nach mehreren Läufen am Stück sinkt die Geschwindigkeit um bis zu ~25 %.

## Einrichtung (so wurde es gemessen)

```bash
# Python-Umgebung für Benchmarks (mlx-lm 0.31.3 ist für dflash-mlx 0.1.8 nötig)
~/.local/bin/python3.12 -m venv ~/.kilokal/venv
~/.kilokal/venv/bin/pip install mlx-lm==0.31.3 dflash-mlx

# oMLX aus dem Quellcode (die Homebrew-Formel scheitert an einem spaCy-Selbsttest)
git clone --depth 1 https://github.com/jundot/omlx.git ~/.kilokal/src-omlx
~/.local/bin/python3.12 -m venv ~/.kilokal/omlx-venv
~/.kilokal/omlx-venv/bin/pip install cmake
PATH=~/.kilokal/omlx-venv/bin:$PATH make -C ~/.kilokal/src-omlx install PYTHON=~/.kilokal/omlx-venv/bin/python

# Modell
~/.kilokal/venv/bin/hf download mlx-works/Ornith-1.5-35B-A3B-oQ3e-mtp --local-dir ~/.kilokal/models/Ornith-1.5-35B-A3B-oQ3e-mtp
```

## Werkzeuge

| Datei | Zweck |
|---|---|
| [`tools/serve.sh`](tools/serve.sh) | startet oMLX (oder dflash-mlx) auf `:8000`, OpenAI- und Anthropic-kompatibel; Speichergrenze über `OMLX_GUARD_GB` (Standard 17,7 GiB) |
| [`tools/mode.py`](tools/mode.py) | schaltet pro Modell `plain` / `mtp` / `dflash` (danach Server neu starten) |
| [`tools/bench.py`](tools/bench.py) | misst Chat, Code-Edit und Kontextlängen über MLX direkt oder jeden OpenAI-Server; `report` vergleicht alle Läufe |

```bash
python3 tools/mode.py Ornith-1.5-35B-A3B-oQ3e-mtp plain
tools/serve.sh
~/.kilokal/venv/bin/python tools/bench.py http --no-think --tag mein-lauf
~/.kilokal/venv/bin/python tools/bench.py report
```

## Mac-App „KI/lokal“ (`app/`)

📖 **[Anleitung mit Screenshots](docs/ANLEITUNG.md)** – jeder Bereich der App erklärt.

![KI/lokal – Agent mit Projekt-Leiste](docs/bilder/agent-projekt.png)

SwiftUI-App für macOS 15+ im KIsruptiv-Design (Dunkelblau `#274060`, Hellblau `#7590BF`, Gold `#FCC419`),
die oMLX im Hintergrund steuert. Bundle-ID `de.kisruptiv.kilokal`.

| Bereich | Was er kann |
|---|---|
| **Übersicht** | erkennt Chip, RAM, GPU-Limit, Bandbreite und SSD, empfiehlt das passende Modell, zeigt erwartete tok/s; richtet die Engine per Klick ein; **Nutzung & Mac**: Tokens, Anfragen, Tempo, Cache-Treffer, Speicher und **Chip-Temperatur** live |
| **Wissen** | eigene Ordner indexieren (Text, Markdown, PDF, Word, RTF, HTML, Code), Hybrid-Suche aus Stichwörtern und Bedeutung (Embeddings von macOS, auf dem Gerät), Quellenangabe |
| **Automationen** | Aufträge nach Zeitplan (Uhrzeit + Wochentage oder Intervall), Vorlage **Morgen-Briefing**, Ergebnis als Mitteilung, vorgelesen oder Datei; **Überwachen ohne Modell**: Prüfbefehl im Takt, der Agent arbeitet nur, wenn sich etwas ändert, fehlschlägt oder gemeldet wird; Start bei Anmeldung |
| **Agent** | ein Eingabefeld für alles; **Projekte** (Gespräche + Ordner + Anweisungen, Code-Projekte automatisch erkannt); **Gesprächsliste mit Volltextsuche**, Umbenennen; **Vorschau** (Seiten und Spiele live) und **formatierter Canvas**; Dateien anhängen (PDF, Word, Excel, PowerPoint, ZIP, Audio …); Dokumente erzeugen (PDF, Word, Excel); Arbeitsschritte kompakt in Klartext; **Gesprächsmodus**, Diktat, Vorlesen, Bildschirmfotos; Freigaben in Klartext oder YOLO |
| **Assistenten** | Galerie fertiger Funktionen: **Transkribieren** (lokal), Meeting-Protokoll, Dokument zusammenfassen, Excel auswerten, Übersetzen, E-Mail beantworten, Recherche-Bericht …; eigene aus Gesprächen; als Automation nach Zeitplan |
| **Modelle** | Katalog (Ornith, Qwen 3.6 Vision, Gemma 4, LFM2.5, Mellum), lokal gefundene Modelle, Cloud-Modelle; **Hugging-Face-Browser** mit Bewertung „läuft gut / langsam / knapp / zu groß“, tok/s-Schätzung und Prüfung, ob die installierte Engine die Architektur kennt |
| **Vergleich** | lokale Modelle gegen GPT-6 Astra, GPT-6.1 Sol, GPT-5.5/5.6, Claude Opus 5/5.5, Fable 5.1, Mythos 5, Gemini 3.1 – SWE-bench Verified/Pro, Terminal-Bench, GPQA, HLE, ARC-AGI-2 (Stand 25.10.2026, mit Quellen) |
| **Skills & Plugins** | Claude-Code-Format: Skills (`SKILL.md`), Plugins mit Befehlen, Sub-Agenten und MCP; Katalog aus Marketplaces (offizieller Anthropic-Katalog, eigene per Git), Installation per Klick |
| **Werkzeuge & MCP** | MCP-Client für stdio- und HTTP-Server (Format wie Claude Desktop, Import, Vorlagen, `${VAR}`-Ersetzung) |
| **Verbinden** | Claude Code / Claude Desktop / OpenAI-kompatible Clients; **KiroCrew** über OpenCode oder Pi (fertige Konfiguration); die App selbst als MCP-Server (`--mcp-server`) |
| **Protokoll** | jede Werkzeug-Aktion des Agenten (Freigabe, YOLO, unbeaufsichtigt) in `~/.kilokal/logs/actions.jsonl`, dazu Engine- und MCP-Log |
| **Einstellungen** | Heimnetz-Freigabe (iPhone per QR-Code), YOLO-Modus + Notbremse, Browser-Steuerung, Kalender/Erinnerungen/Kontakte/Mail, GPU-Speicher erhöhen, Engine einrichten, Websuche (DuckDuckGo, SearXNG, Brave), Modell-Router nach Thema, Cloud-Anbieter (Anthropic, OpenAI-kompatibel), Experte für `ask_expert`, eigene Anweisungen |

**Werkzeuge des Agenten:**

| Gruppe | Werkzeuge |
|---|---|
| Dateien & Shell | `list_directory`, `read_file` (auch PDF), `find_files`, `search_files`, `write_file`, `edit_file`, `run_shell` |
| Web | `web_search`, `fetch_url`, `http_request` (GET/POST/PUT/PATCH/DELETE) |
| Dein Browser | `browser_tabs`, `browser_open`, `browser_read`, `browser_click`, `browser_type`, `browser_scroll`, `browser_back` – Brave, Chrome, Edge, Arc, Safari über JavaScript for Automation |
| Mac | `clipboard_read`, `clipboard_write`, `notify`, `look_at_screen` (Bildschirmfoto → Vision-Modell) |
| Dokumente | `create_document` (PDF, Word, Excel, CSV, RTF, HTML aus Markdown), `open_canvas` (bearbeitbarer Canvas), `transcribe` (Audio/Video → Text, lokal) |
| Kalender & Co. | `calendar_events`, `calendar_create`, `reminders_list`, `reminders_create`, `contacts_search`, `mail_recent`, `mail_draft` (nur Entwürfe, nie selbst senden) |
| Gedächtnis & Wissen | `remember`, `forget` (`~/.kilokal/memory.md`), `learn_lesson` (Lektionen, `~/.kilokal/lessons.json`), `search_documents` (eigene Ordner) |
| Lange Aufträge | `update_plan` (Checkliste, bleibt beim Verdichten erhalten) |
| Agenten | `use_skill`, `run_agent` (Sub-Agenten aus Plugins), `ask_expert` (Cloud-Briefing) |
| MCP | alle Werkzeuge verbundener MCP-Server, Vorlagen u. a. Playwright und Chrome DevTools |

**Projekte statt Modi:** Ein Projekt bündelt Gespräche, einen Ordner und eigene Anweisungen. Liegt im Ordner Code
(`.git`, `package.json`, `index.html` …), arbeitet der Agent automatisch als Coding-Agent (Code-Werkzeuge, Prüfung nach
jeder Änderung, MTP ~80 tok/s); sonst stehen alle Werkzeuge bereit. Pro Projekt fest einstellbar (Automatisch · Nur Chat ·
Arbeiten · Code).

**Qualität trotz kleinem Modell:** KI/lokal ergänzt das Modell um das, was ihm fehlt:
- **Umgebung:** Die App ermittelt beim Start node, python3, git, npm, swift (Pfad + Version, kaputte Installationen
  übersprungen) und nennt sie im Systemprompt.
- **Automatische Prüfung** nach jedem `write_file`/`edit_file`: JS/JSON/Python/Shell auf Syntax; HTML-Skripte mit
  Zeilennummern bezogen auf die HTML-Datei; die Seite wird **unsichtbar in WebKit geladen** und auf Laufzeitfehler,
  `console.error` und fehlende Dateien geprüft. Der Befund steht in der Werkzeug-Antwort.
- **Qualitäts-Check vor „fertig“:** Hat der Agent Dateien geändert, bekommt er einmal alle Prüfergebnisse und den
  ursprünglichen Auftrag zurück und muss Fehler, fehlende Punkte und Tippfehler beheben.
- **Längen- und Schrittlimit:** abgeschnittene Antworten werden in Teilen fortgesetzt; kurz vor dem Limit eine Erinnerung,
  danach „Weitermachen“.
- **Lektionen:** Korrekturen des Nutzers und im Qualitäts-Check behobene Fehler werden mit `learn_lesson` zu dauerhaften
  Regeln (global oder pro Projekt), die ab dann im Systemprompt stehen. Wiederholt sich ein Auftrag zum dritten Mal,
  schlägt der Chat vor, aus allen passenden Gesprächen einen Skill zu machen.
- **Lange Aufträge:** Zwischenstand nach jedem Schritt; nach Absturz oder Beenden *Fortsetzen* (offene Werkzeug-Aufrufe
  werden ergänzt); Plan per `update_plan`, der beim Verdichten wieder eingespielt wird; am Schrittlimit bis zu N× von selbst
  weiter, Mac bleibt wach.
- **Projekttests:** Gibt es `tests/test_*.js|py`, führt der Qualitäts-Check sie vor „fertig“ aus – bei Rot bis zu dreimal.
- **Typische Ausrutscher abgefangen:** bloße Ankündigungen ohne Werkzeug („Ich starte …“) und Rückfragen nach Inhalten, die
  der Agent selbst lesen kann, lösen eine Erinnerung aus; `replace_lines` ersetzt ganze Blöcke per Zeilennummer;
  `edit_file` gleicht abweichende Einrückung aus und zeigt sonst die ähnlichste Stelle; `write_file` warnt, wenn beim
  Überschreiben Funktionen verloren gehen; die Browser-Prüfung erkennt auch hängende Seiten.
- **Speicher (24 GB):** Werkzeug-Ergebnisse und selbst geschriebene Dateiinhalte werden beim Eintragen in den Verlauf
  gekürzt (Prompt-Cache bleibt gültig), der Verlauf wird früh verdichtet, bei „memory guard“ automatisch stärker gekürzt und
  wiederholt; im Code-Projekt schlanker Systemprompt ohne fremde MCP-Werkzeuge.

**Vorschau und Canvas:** Rechts neben dem Chat zeigt ein Panel, was der Agent schreibt – HTML und Spiele laufen live
(WebKit, mit Web-Inspektor, auf Panelbreite skaliert), Markdown gerendert, Bilder/PDF/Office per QuickLook, Code mit
Zeilennummern. Markdown lässt sich als **formatierter Canvas** bearbeiten (Werkzeugleiste, ⌘B/⌘I, automatisch gespeichert,
Export als PDF/Word/HTML); der Agent öffnet Entwürfe selbst mit `open_canvas`. Ändert der Agent
ein Skript oder Stylesheet der gezeigten Seite, lädt sie neu. Fehler aus der Browser-Konsole erscheinen unter der Vorschau
und gehen mit „An Agent schicken“ zurück an den Agenten. HTML-/SVG-/Markdown-Blöcke im Chat haben einen „Vorschau“-Knopf.

**Aufträge aus dem Terminal:** `KI lokal --agent "…" [--workspace <ordner>] [--attach <datei>] [--mode chat|work|code] [--yolo]` übergibt den Auftrag an
die laufende App – er erscheint live im Agent-Tab, Freigaben erteilst du dort, das Terminal zeigt den Verlauf mit. Läuft die App
nicht (oder mit `--headless`), arbeitet der Agent ohne Oberfläche; die Notbremse lehnt gefährliche Aktionen dann automatisch ab.

**Freigaben & YOLO:** Schreiben, Shell, Browser-Aktionen, HTTP, MCP und Cloud brauchen eine Freigabe im Chat. Der **YOLO-Modus** (🔥 im Chat)
führt alles ohne Nachfrage aus. Die abschaltbare **Notbremse** fragt trotzdem bei `sudo`, `rm -rf`, `git push --force`, `git reset --hard`,
`curl … | sh`, Systembefehlen, beim Schreiben außerhalb des Benutzerordners und bei jedem Zugriff auf Zugangsdaten (`~/.ssh`,
`~/.aws`, Schlüsselbund …). Shell-Befehle ohne Freigabe (YOLO, Automationen) laufen in einer **macOS-Sandbox**
(`sandbox-exec`: Schreiben nur im Arbeitsordner, `/tmp` und Caches; Zugangsdaten gesperrt). API-Schlüssel und private
Schlüssel in Werkzeug-Ergebnissen werden ausgeblendet, bevor sie in den Verlauf oder ins Protokoll gelangen.

**Browser einrichten:** im Browser „JavaScript von Apple Events erlauben“ einschalten (Chrome/Brave/Edge: Ansicht → Entwickler;
Safari: Entwickler-Menü), in KI/lokal unter Einstellungen → Browser-Steuerung einschalten; macOS fragt beim ersten Zugriff nach der Automation-Erlaubnis.
Mitgelieferte Skills: `web-recherche`, `code-review`, `dokumente-zusammenfassen`, `mac-helfer`, `skill-ersteller`.

**Cloud ist optional:** Ohne API-Schlüssel bleibt alles auf dem Mac. Claude läuft über die Messages-API (`anthropic-version 2026-10-21`,
adaptives Thinking, Thinking-Blöcke werden unverändert zurückgegeben, serverseitige Fallbacks bei Ablehnungen eingeschaltet).

**Gesprächsmodus** (Wellen-Symbol im Chat): sprechen – nach ~1,4 s Pause wird abgeschickt – die Antwort wird vorgelesen –
danach hört KI/lokal wieder zu. „Schau auf meinen Bildschirm“ hängt automatisch ein Bildschirmfoto an. Antworten sind im
Gesprächsmodus kurz und vorlesbar. **Bildschirmfotos** (ganzer Bildschirm, Bereich, Fenster) gehen per Kamera-Symbol an das Vision-Modell.

**Sprache:** Diktat über die Spracherkennung von macOS (auf dem Gerät, wenn verfügbar), Vorlesen mit der besten
installierten Systemstimme – ohne zusätzliches Modell im knappen Speicher.

**Tempo-Modus „Automatisch“:** MTP nur für Code-Aufgaben. Gemessen auf dem M4 Air: Chat 39 tok/s (ohne Spekulation),
Code-Edit 82 tok/s (mit MTP) – pro Anfrage, ohne Neustart. Möglich durch den oMLX-Patch
[`engine/patches/omlx-mtp-per-request.patch`](engine/patches/omlx-mtp-per-request.patch) (Header `X-oMLX-MTP: off`),
eingereicht als [jundot/omlx#4851](https://github.com/jundot/omlx/pull/4851).

**Heimnetz:** Ein Schalter gibt KI/lokal im WLAN frei – mit zufälligem API-Schlüssel (Schlüsselbund). Das iPhone scannt den
QR-Code und nutzt den Web-Chat von oMLX (`http://<Mac>.local:8000/admin/chat`), andere Apps die OpenAI-API. Ohne Freigabe lauscht
der Server ausdrücklich nur auf `127.0.0.1` (oMLX merkt sich `--host` sonst dauerhaft). Die Freigabe greift nur, wenn die App
die Engine selbst startet; eine per `tools/serve.sh` gestartete Engine übernimmt sie mit „In der App neu starten“.

**Absturzberichte:** Nach einem Absturz zeigt die Übersicht einen Hinweis; „Melden“ öffnet ein vorausgefülltes GitHub-Issue
(Version, macOS, Chip, Stack-Frames – keine persönlichen Daten), das du selbst abschickst.

**Dauerlast:** 10 Minuten ununterbrochen auf dem lüfterlosen MacBook Air M4: Start 40 tok/s, nach ~5 Minuten stabil
~30 tok/s (−24 % durch Wärme). Normales Chatten mit Pausen bleibt bei ~40 tok/s; lange Agenten-Läufe am Stück eher bei ~30.

**Langer Kontext:** KV-Kompression (TurboQuant, 4 Bit) pro Modell + angepasste Speicherwächter: auf 24 GB ~29k Tokens
bei 32,7 tok/s statt Abbruch bei 32k. Mit „GPU-Speicher erhöhen“ (Passwortabfrage, gilt bis zum Neustart) mehr.
Im Agenten wächst der Verlauf bis ~24k Tokens, bevor die App ältere Schritte kürzt: Weil er nur angehängt wird, liest die
Engine pro Schritt nur das Neue ein (gemessen bis 29,5k, 11–32 s pro Schritt). Ohne Cache – ein altes Gespräch neu
geöffnet – passen ~20k am Stück (2,5 min); lehnt der Speicherwächter ab, kürzt die App und macht weiter.

```bash
app/Scripts/build.sh --run                 # braucht Xcode und xcodegen (brew install xcodegen)
app/Scripts/build.sh --install             # bauen, nach /Applications installieren und starten
app/Scripts/make-dmg.sh                    # signierte DMG (Developer ID, Hardened Runtime); NOTARY_PROFILE=… notarisiert
"app/build/KI lokal.app/Contents/MacOS/KI lokal" --selftest        # Engine, Werkzeuge, MCP, Web, Router, Browser-Skripte …
"app/build/KI lokal.app/Contents/MacOS/KI lokal" --install-engine  # oMLX ohne Oberfläche einrichten
"app/build/KI lokal.app/Contents/MacOS/KI lokal" --mcp-server      # lokales Modell als MCP-Server
"app/build/KI lokal.app/Contents/MacOS/KI lokal" --agent "…" --mode code --workspace demos/x   # Auftrag an die laufende App
```

Daten liegen unter `~/.kilokal/` (Engine, Modelle, Skills, Plugins, Gespräche, Gedächtnis, Wissensindex, Automationen, Protokoll).

## Demo: Stadtflitzer 3D

Ferngesteuerte Spielzeugautos (wie Re-Volt) durch **echte Innenstädte** – München, Hamburg, Berlin, Köln – mit Gebäuden aus
OpenStreetMap, Wahrzeichen, Power-ups und drei Computer-Gegnern. `demos/stadtflitzer-3d/index.html` per Doppelklick öffnen
(ohne Server, ohne Internet). Entstanden in einer Nacht mit dem lokalen Agenten und Claude – wer was gebaut hat und was
KI/lokal dabei gelernt hat: [demos/stadtflitzer-3d/README.md](demos/stadtflitzer-3d/README.md).

![Stadtflitzer 3D](docs/bilder/spiel-rennen.png)

## Nächste Schritte

1. Review von [jundot/omlx#4851](https://github.com/jundot/omlx/pull/4851) begleiten; nach dem Merge den eigenen Patch entfernen.
2. Notarisierung einrichten (`xcrun notarytool store-credentials`) und DMG veröffentlichen; Einrichtungs-Assistent beim ersten Start.
3. 64k Kontext mit angehobenem GPU-Limit messen (Knopf in den Einstellungen, braucht dein Passwort).
