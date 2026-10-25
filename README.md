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

SwiftUI-App für macOS 15+, die oMLX im Hintergrund steuert:

- **Übersicht:** erkennt Chip, RAM, GPU-Limit, Bandbreite und SSD, empfiehlt das passende Modell, zeigt erwartete tok/s.
- **Modelle:** laden direkt von Hugging Face (mit Fortschritt, fortsetzbar), auswählen, MTP ein/aus, in den Papierkorb.
- **Agent:** Chat mit Streaming und Live-tok/s; das Modell kann Werkzeuge aufrufen (Ordner auflisten, Dateien lesen/schreiben,
  Shell, Web abrufen). Schreiben, Shell und MCP-Aufrufe brauchen eine Freigabe im Chat.
- **Werkzeuge & MCP:** MCP-Client für beliebige stdio-Server (Format wie Claude Desktop, Import aus dessen Konfiguration, Vorlagen).
- **MCP-Server:** `"Local AI.app/Contents/MacOS/Local AI" --mcp-server` stellt `local_chat` und `local_models` bereit,
  z. B. `claude mcp add local-ai -- "<Pfad>/Local AI" --mcp-server`.
- **Verbinden:** fertige Befehle für Claude Code (Anthropic-API von oMLX), OpenAI-kompatible Clients und Claude Desktop.
- **Menüleiste:** Status, Server starten/stoppen.

```bash
app/Scripts/build.sh --run          # braucht Xcode und xcodegen (brew install xcodegen)
"app/build/Local AI.app/Contents/MacOS/Local AI" --selftest   # Engine, Tool-Calls, Werkzeuge, MCP, Download
```

Die App erwartet oMLX unter `~/.strata-lite/omlx-venv` (siehe Einrichtung oben) und legt Modelle unter `~/.strata-lite/models` ab.

## Nächste Schritte

1. MTP pro Anfrage statt pro Modell (Patch für oMLX): 43 tok/s im Chat **und** ~78 tok/s bei Code ohne Neustart.
2. oMLX in die App einbetten (wie dessen eigene App über venvstacks), damit keine Einrichtung im Terminal nötig ist.
3. Langer Kontext (32k–64k) mit angehobenem GPU-Limit und KV-Quantisierung; Dauerlast-Test.
