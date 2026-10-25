---
name: dokumente-zusammenfassen
description: Fasst Dokumente zusammen (PDF, Text, Markdown, Webseiten) – einzeln oder einen ganzen Ordner. Nutzen bei "fass zusammen", "was steht in", "TL;DR".
---

# Dokumente zusammenfassen

1. Dateien finden: `find_files` mit Mustern wie `*.pdf`, `*.md`, `*.txt`, `*.docx` (docx vorher mit
   `run_shell`: `textutil -convert txt -stdout <datei>`).
2. Jedes Dokument mit `read_file` lesen (PDFs werden automatisch als Text gelesen). Bei langen Dateien
   in Abschnitten über `start_line`/`end_line`.
3. Pro Dokument:
   - **Kernaussage** in einem Satz
   - **Wichtigste Punkte** (3–7 Stichpunkte, mit Zahlen/Daten, wenn vorhanden)
   - **Offene Fragen / To-dos**, falls erkennbar
4. Bei mehreren Dokumenten am Ende eine Gesamtübersicht: Gemeinsamkeiten, Widersprüche, was fehlt.
5. Auf Wunsch die Zusammenfassung mit `write_file` als `zusammenfassung.md` speichern.
