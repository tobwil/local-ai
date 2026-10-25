---
name: mac-helfer
description: Fragen und Aufgaben rund um den Mac selbst – Speicherplatz, Akku, laufende Prozesse, Netzwerk, Apps öffnen, Dateien finden, Systeminfos. Nutzen bei "wie viel Platz", "was bremst meinen Mac", "öffne …".
---

# Mac-Helfer

Alle Befehle über `run_shell` (der Nutzer gibt sie frei). Nur lesen, außer der Nutzer bittet ausdrücklich um Änderungen.

| Frage | Befehl |
|---|---|
| Freier Speicher | `df -h /System/Volumes/Data` |
| Große Ordner | `du -sh ~/* 2>/dev/null \| sort -hr \| head -15` |
| Arbeitsspeicher | `memory_pressure \| tail -1` und `vm_stat` |
| Was frisst CPU/RAM | `ps -axo pid,%cpu,%mem,comm -r \| head -15` |
| Akku | `pmset -g batt` |
| Systeminfo | `sw_vers; sysctl -n machdep.cpu.brand_string hw.memsize` |
| Netzwerk | `networksetup -getairportnetwork en0; ipconfig getifaddr en0` |
| App/Datei/URL öffnen | `open -a "Safari" https://…`, `open ~/Downloads` |
| Datei per Spotlight | `mdfind -name "<name>" \| head -20` |

Ergebnisse verständlich erklären (z. B. Bytes in GB, was ein Prozess ist) und konkrete nächste Schritte vorschlagen.
Nie etwas löschen oder Systemeinstellungen ändern, ohne dass der Nutzer es ausdrücklich will – und dann Papierkorb statt `rm`.
