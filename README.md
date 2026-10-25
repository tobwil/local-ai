# local-ai

Nahezu Frontier-Modelle lokal auf einem Mac mit Apple Silicon – schnell genug für den Alltag (Ziel: ≥ 40 tok/s).
Inspiriert von [Strata](https://github.com/Niko1221/Strata), aber für Macs mit wenig Speicher gebaut.

Ziel ist eine Mac-App, mit der jeder ohne Terminal ein passendes Modell auswählen, laden und benutzen kann.
Dieser Stand enthält die Werkzeuge und Messungen, auf denen die App aufbaut.

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

## Mac-App „Local AI“ (`app/`)

SwiftUI-App für macOS 15+, die oMLX im Hintergrund steuert.

| Bereich | Was er kann |
|---|---|
| **Übersicht** | erkennt Chip, RAM, GPU-Limit, Bandbreite und SSD, empfiehlt das passende Modell, zeigt erwartete tok/s |
| **Agent** | Chat mit Streaming und Live-tok/s, Bilder anhängen (Vision), Slash-Befehle, Verlauf; Werkzeuge mit Freigabe für Schreiben/Shell/MCP/Cloud |
| **Modelle** | Katalog (Ornith, Qwen 3.6 Vision, Gemma 4, LFM2.5, Mellum), lokal gefundene Modelle, Cloud-Modelle; **Hugging-Face-Browser** mit Bewertung „läuft gut / langsam / knapp / zu groß“, tok/s-Schätzung und Prüfung, ob die installierte Engine die Architektur kennt |
| **Vergleich** | Benchmarks der lokalen Modelle gegen Claude Opus 5/5.5, GPT-5.5, Gemini (Herstellerangaben, Stand 25.10.2026, mit Quellen) |
| **Skills & Plugins** | Claude-Code-Format: Skills (`SKILL.md`), Plugins mit Befehlen, Sub-Agenten und MCP; Katalog aus Marketplaces (offizieller Anthropic-Katalog, eigene per Git), Installation per Klick |
| **Werkzeuge & MCP** | MCP-Client für stdio- und HTTP-Server (Format wie Claude Desktop, Import, Vorlagen, `${VAR}`-Ersetzung) |
| **Verbinden** | Claude Code / Claude Desktop / OpenAI-kompatible Clients; die App selbst als MCP-Server (`--mcp-server`) |
| **Einstellungen** | YOLO-Modus + Notbremse, Browser-Steuerung, Websuche (DuckDuckGo, SearXNG, Brave), Modell-Router nach Thema, Cloud-Anbieter (Anthropic, OpenAI-kompatibel), Experte für `ask_expert`, eigene Anweisungen |

**Werkzeuge des Agenten:**

| Gruppe | Werkzeuge |
|---|---|
| Dateien & Shell | `list_directory`, `read_file` (auch PDF), `find_files`, `search_files`, `write_file`, `edit_file`, `run_shell` |
| Web | `web_search`, `fetch_url`, `http_request` (GET/POST/PUT/PATCH/DELETE) |
| Dein Browser | `browser_tabs`, `browser_open`, `browser_read`, `browser_click`, `browser_type`, `browser_scroll`, `browser_back` – Brave, Chrome, Edge, Arc, Safari über JavaScript for Automation |
| Mac | `clipboard_read`, `clipboard_write`, `notify` |
| Gedächtnis | `remember`, `forget` – gilt in allen Gesprächen (`~/.strata-lite/memory.md`) |
| Agenten | `use_skill`, `run_agent` (Sub-Agenten aus Plugins), `ask_expert` (Cloud-Briefing) |
| MCP | alle Werkzeuge verbundener MCP-Server, Vorlagen u. a. Playwright und Chrome DevTools |

**Freigaben & YOLO:** Schreiben, Shell, Browser-Aktionen, HTTP, MCP und Cloud brauchen eine Freigabe im Chat. Der **YOLO-Modus** (🔥 im Chat)
führt alles ohne Nachfrage aus. Die abschaltbare **Notbremse** fragt trotzdem bei `sudo`, `rm -rf`, `git push --force`, `git reset --hard`,
`curl … | sh`, Systembefehlen und beim Schreiben außerhalb des Benutzerordners.

**Browser einrichten:** im Browser „JavaScript von Apple Events erlauben“ einschalten (Chrome/Brave/Edge: Ansicht → Entwickler;
Safari: Entwickler-Menü), in Local AI unter Einstellungen → Browser-Steuerung einschalten; macOS fragt beim ersten Zugriff nach der Automation-Erlaubnis.
Mitgelieferte Skills: `web-recherche`, `code-review`, `dokumente-zusammenfassen`, `mac-helfer`, `skill-ersteller`.

**Cloud ist optional:** Ohne API-Schlüssel bleibt alles auf dem Mac. Claude läuft über die Messages-API (`anthropic-version 2026-10-21`,
adaptives Thinking, Thinking-Blöcke werden unverändert zurückgegeben, serverseitige Fallbacks bei Ablehnungen eingeschaltet).

```bash
app/Scripts/build.sh --run          # braucht Xcode und xcodegen (brew install xcodegen)
"app/build/Local AI.app/Contents/MacOS/Local AI" --selftest   # ~19 Prüfungen, LOCALAI_TEST_VISION=1 zusätzlich Vision
```

Die App erwartet oMLX unter `~/.strata-lite/omlx-venv` (siehe Einrichtung oben) und legt Modelle, Skills, Plugins und Gespräche unter `~/.strata-lite/` ab.

## Nächste Schritte

1. MTP pro Anfrage statt pro Modell (Patch für oMLX): 43 tok/s im Chat **und** ~78 tok/s bei Code ohne Neustart.
2. oMLX in die App einbetten (wie dessen eigene App über venvstacks), signieren, als DMG verteilen.
3. Sprache: Diktat und Vorlesen über mlx-audio (in oMLX schon enthalten).
4. Langer Kontext (32k–64k) mit angehobenem GPU-Limit und KV-Quantisierung; Dauerlast-Test.
