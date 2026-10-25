# KI/lokal

**KI für alle – direkt auf deinem Mac.** Ein Tool von [KIsruptiv](https://kisruptiv.de).

KI/lokal holt nahezu Frontier-Modelle auf Macs mit Apple Silicon – privat, offline, ohne Abo und schnell genug
für den Alltag (≥ 40 tok/s). Inspiriert von [Strata](https://github.com/Niko1221/Strata), aber für Macs mit wenig
Speicher gebaut: Die App erkennt die Hardware, empfiehlt das passende Modell, richtet die Engine ein und bringt einen
Agenten mit Werkzeugen, Skills, Plugins, MCP, Browser-Steuerung, Sprache und Vision mit.

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
~/.local/bin/python3.12 -m venv ~/.strata-lite/venv
~/.strata-lite/venv/bin/pip install mlx-lm==0.31.3 dflash-mlx

# oMLX aus dem Quellcode (die Homebrew-Formel scheitert an einem spaCy-Selbsttest)
git clone --depth 1 https://github.com/jundot/omlx.git ~/.strata-lite/src-omlx
~/.local/bin/python3.12 -m venv ~/.strata-lite/omlx-venv
~/.strata-lite/omlx-venv/bin/pip install cmake
PATH=~/.strata-lite/omlx-venv/bin:$PATH make -C ~/.strata-lite/src-omlx install PYTHON=~/.strata-lite/omlx-venv/bin/python

# Modell
~/.strata-lite/venv/bin/hf download mlx-works/Ornith-1.5-35B-A3B-oQ3e-mtp --local-dir ~/.strata-lite/models/Ornith-1.5-35B-A3B-oQ3e-mtp
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
~/.strata-lite/venv/bin/python tools/bench.py http --no-think --tag mein-lauf
~/.strata-lite/venv/bin/python tools/bench.py report
```

## Mac-App „KI/lokal“ (`app/`)

SwiftUI-App für macOS 15+ im KIsruptiv-Design (Dunkelblau `#274060`, Hellblau `#7590BF`, Gold `#FCC419`),
die oMLX im Hintergrund steuert. Bundle-ID `de.kisruptiv.kilokal`.

| Bereich | Was er kann |
|---|---|
| **Übersicht** | erkennt Chip, RAM, GPU-Limit, Bandbreite und SSD, empfiehlt das passende Modell, zeigt erwartete tok/s; richtet die Engine per Klick ein |
| **Agent** | Chat mit Streaming und Live-tok/s, **Gesprächsmodus**, Diktat und Vorlesen, Bilder und Bildschirmfotos (Vision), Slash-Befehle, Verlauf; Werkzeuge mit Freigabe oder YOLO |
| **Modelle** | Katalog (Ornith, Qwen 3.6 Vision, Gemma 4, LFM2.5, Mellum), lokal gefundene Modelle, Cloud-Modelle; **Hugging-Face-Browser** mit Bewertung „läuft gut / langsam / knapp / zu groß“, tok/s-Schätzung und Prüfung, ob die installierte Engine die Architektur kennt |
| **Vergleich** | lokale Modelle gegen GPT-6 Astra, GPT-6.1 Sol, GPT-5.5/5.6, Claude Opus 5/5.5, Fable 5.1, Mythos 5, Gemini 3.1 – SWE-bench Verified/Pro, Terminal-Bench, GPQA, HLE, ARC-AGI-2 (Stand 25.10.2026, mit Quellen) |
| **Skills & Plugins** | Claude-Code-Format: Skills (`SKILL.md`), Plugins mit Befehlen, Sub-Agenten und MCP; Katalog aus Marketplaces (offizieller Anthropic-Katalog, eigene per Git), Installation per Klick |
| **Werkzeuge & MCP** | MCP-Client für stdio- und HTTP-Server (Format wie Claude Desktop, Import, Vorlagen, `${VAR}`-Ersetzung) |
| **Verbinden** | Claude Code / Claude Desktop / OpenAI-kompatible Clients; die App selbst als MCP-Server (`--mcp-server`) |
| **Einstellungen** | YOLO-Modus + Notbremse, Browser-Steuerung, Kalender/Erinnerungen/Kontakte/Mail, GPU-Speicher erhöhen, Engine einrichten, Websuche (DuckDuckGo, SearXNG, Brave), Modell-Router nach Thema, Cloud-Anbieter (Anthropic, OpenAI-kompatibel), Experte für `ask_expert`, eigene Anweisungen |

**Werkzeuge des Agenten:**

| Gruppe | Werkzeuge |
|---|---|
| Dateien & Shell | `list_directory`, `read_file` (auch PDF), `find_files`, `search_files`, `write_file`, `edit_file`, `run_shell` |
| Web | `web_search`, `fetch_url`, `http_request` (GET/POST/PUT/PATCH/DELETE) |
| Dein Browser | `browser_tabs`, `browser_open`, `browser_read`, `browser_click`, `browser_type`, `browser_scroll`, `browser_back` – Brave, Chrome, Edge, Arc, Safari über JavaScript for Automation |
| Mac | `clipboard_read`, `clipboard_write`, `notify`, `look_at_screen` (Bildschirmfoto → Vision-Modell) |
| Kalender & Co. | `calendar_events`, `calendar_create`, `reminders_list`, `reminders_create`, `contacts_search`, `mail_recent`, `mail_draft` (nur Entwürfe, nie selbst senden) |
| Gedächtnis | `remember`, `forget` – gilt in allen Gesprächen (`~/.strata-lite/memory.md`) |
| Agenten | `use_skill`, `run_agent` (Sub-Agenten aus Plugins), `ask_expert` (Cloud-Briefing) |
| MCP | alle Werkzeuge verbundener MCP-Server, Vorlagen u. a. Playwright und Chrome DevTools |

**Freigaben & YOLO:** Schreiben, Shell, Browser-Aktionen, HTTP, MCP und Cloud brauchen eine Freigabe im Chat. Der **YOLO-Modus** (🔥 im Chat)
führt alles ohne Nachfrage aus. Die abschaltbare **Notbremse** fragt trotzdem bei `sudo`, `rm -rf`, `git push --force`, `git reset --hard`,
`curl … | sh`, Systembefehlen und beim Schreiben außerhalb des Benutzerordners.

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
[`engine/patches/omlx-mtp-per-request.patch`](engine/patches/omlx-mtp-per-request.patch) (Header `X-oMLX-MTP: off`).

**Langer Kontext:** KV-Kompression (TurboQuant, 4 Bit) pro Modell + angepasste Speicherwächter: auf 24 GB ~29k Tokens
bei 32,7 tok/s statt Abbruch bei 32k. Mit „GPU-Speicher erhöhen“ (Passwortabfrage, gilt bis zum Neustart) mehr.

```bash
app/Scripts/build.sh --run                 # braucht Xcode und xcodegen (brew install xcodegen)
app/Scripts/make-dmg.sh                    # signierte DMG (Developer ID, Hardened Runtime); NOTARY_PROFILE=… notarisiert
"app/build/KI lokal.app/Contents/MacOS/KI lokal" --selftest        # Engine, Werkzeuge, MCP, Web, Router, Browser-Skripte …
"app/build/KI lokal.app/Contents/MacOS/KI lokal" --install-engine  # oMLX ohne Oberfläche einrichten
"app/build/KI lokal.app/Contents/MacOS/KI lokal" --mcp-server      # lokales Modell als MCP-Server
```

Daten liegen unter `~/.strata-lite/` (Engine, Modelle, Skills, Plugins, Gespräche, Gedächtnis).

## Nächste Schritte

1. MTP-Patch als Pull Request an oMLX geben, damit er ohne eigenen Patch funktioniert.
2. Notarisierung einrichten (`xcrun notarytool store-credentials`) und DMG veröffentlichen.
3. 64k Kontext mit angehobenem GPU-Limit messen; Dauerlast-Test auf dem lüfterlosen Air.
