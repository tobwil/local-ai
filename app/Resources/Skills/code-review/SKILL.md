---
name: code-review
description: Prüft Code auf Fehler, Sicherheitslücken und Unklarheiten. Nutzen bei "review", "prüf meinen Code", "findest du Bugs" oder vor einem Commit.
---

# Code-Review

1. **Überblick holen.** Mit `find_files` und `list_directory` die Struktur verstehen. Bei Git-Projekten
   mit `run_shell` `git status` und `git diff` ansehen, um nur die Änderungen zu prüfen.
2. **Gezielt lesen.** Die betroffenen Dateien mit `read_file` lesen; Aufrufer und Verwendungen mit `search_files` finden.
3. **Prüfen auf:**
   - Logikfehler, falsche Randfälle (leer, null, sehr groß, Unicode, Zeitzonen)
   - Fehlerbehandlung, Ressourcen-Lecks, Nebenläufigkeit
   - Sicherheit: Injection, Pfade aus Nutzereingaben, Geheimnisse im Code, fehlende Prüfungen
   - Lesbarkeit und Abweichungen von den Konventionen des Projekts
4. **Nur melden, was wirklich zählt.** Jeder Befund mit Datei:Zeile, einem Satz zum Problem,
   einem konkreten Szenario, in dem es schiefgeht, und einem Vorschlag. Nach Schwere sortieren.
5. Änderungen nur vornehmen, wenn der Nutzer darum bittet – dann mit `edit_file`.
