---
name: fuenf-warum
description: Geführtes Tiefbohren mit der 5-Warum-Methode – eine kurze Frage und Antwort nach der anderen, der Nutzer lenkt die Richtung. Nutzen bei "5 Warum", "fünf Warum", "bohr mal tiefer", "warum genau", "Ursache finden", "ich will das wirklich verstehen" – für Fehler, Vorfälle, Systeme, Begriffe oder Entscheidungen.
---

# Fünf Warum – geführt in die Tiefe

Das ist ein **Modus über mehrere Antworten**, keine einmalige Antwort. Bleib darin, bis der Nutzer zufrieden ist
oder „Ende“/„Bericht“ sagt.

## Jede Runde genau so – dann warten

1. **Die aktuelle Frage beantworten** – kurz und direkt (2–5 Sätze). Fakten mit Werkzeugen prüfen
   (`read_file`, `search_files`, `web_search`, `fetch_url`), nicht raten. Unsicheres als unsicher kennzeichnen.
2. **2–4 nächste Fragen vorschlagen**, nummeriert, jede ein einzelnes „Warum …?“, „Wie …?“ oder „Was verursacht …?“
   zu deiner Antwort.
3. **Der Nutzer wählt** eine Nummer, mehrere (werden nacheinander zu Zweigen) oder stellt eine eigene Frage –
   die eigene Frage gewinnt immer.

## Roter Faden

Ordne Antworten und Vorschläge nach dieser Kette, vom Verstehen zum Beurteilen:
**Was ist es? → Ein konkretes Beispiel → Warum nicht die Alternativen? → Nutzen → Kosten und Risiken.**
Bei Fehlern: **Was ist passiert? → Warum? → Warum hat das nicht gegriffen? → … bis zu einer Ursache, die sich ändern lässt.**

## Den Überblick behalten

- Führe den Baum als Checkliste mit `update_plan` (offene Zweige `- [ ]`, beantwortete `- [x]`), damit nichts verloren geht,
  auch wenn das Gespräch lang wird.
- Auf „Wo stehen wir?“: kurze Übersicht der Zweige und der aktuellen Frage.

## Abschluss

Bei „Ende“ oder „Bericht“: ein knapper Bericht – Ausgangsfrage, die Kette bis zur Ursache, offene Zweige, empfohlene
nächste Schritte. Auf Wunsch als Dokument mit `create_document` oder bearbeitbar mit `open_canvas`.
Ist eine Ursache gefunden, die sich wiederholen kann, biete an, sie mit `learn_lesson` als Regel festzuhalten.

*Angelehnt an den Skill „five-whys“ aus [KiroCrew](https://github.com/kirodotdev/KiroCrew) (Apache 2.0), übersetzt, vereinfacht und für KI/lokal angepasst.*
