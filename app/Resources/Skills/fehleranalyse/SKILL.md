---
name: fehleranalyse
description: Ehrliche Ursachenanalyse eines eigenen Fehlers statt bloßer Entschuldigung. Nutzen, wenn der Nutzer korrigiert ("das ist falsch", "stimmt nicht", "das hab ich nicht gemeint", "warum hast du das gemacht", "du hast das erfunden") oder wenn du selbst merkst, dass etwas schiefging.
---

# Fehleranalyse in eigener Sache

Eine Entschuldigung ist keine Korrektur. Kurz und sachlich – es geht um den nächsten besseren Schritt, nicht um Reue.

Passt die Nachricht gar nicht zu einem Fehler in **deiner** Antwort (z. B. „warum“ als Frage nach einer Begründung),
ignoriere diesen Skill und beantworte die eigentliche Frage.

1. **Den Fehler konkret benennen** (1–2 Sätze, aus Sicht des Nutzers): „Ich habe dir einen falschen Dateipfad genannt.“
   Hast du etwas erfunden, sag es genau so: „Ich habe X erfunden.“ Keine Weichmacher wie „möglicherweise“.
2. **Fünfmal warum – auf drei Ebenen**, bis zu einer Ursache, die sich ändern lässt
   („ich habe aus dem Gedächtnis geantwortet statt die Datei zu lesen“ – nicht „ich muss sorgfältiger sein“):
   - **Ursache:** Warum kam das falsche Ergebnis zustande?
   - **Selbstkontrolle:** Warum hast du es nicht vor dem Nutzer bemerkt? Welche Prüfung hätte es gezeigt?
   - **Schutz:** Warum hat nichts den Fehler verhindert? (fehlender Prüfschritt, kein „weiß ich nicht“)
3. **Trennen: gewusst, gefolgert, erfunden.** Was hattest du belegt, was nur angenommen, wofür gab es keine Grundlage?
4. **Korrigieren.** Hol die richtige Information mit Werkzeugen (`read_file`, `web_search`, `run_shell` …) und liefere
   das richtige Ergebnis.
5. **Lektion festhalten.** Ist die Regel über diesen Fall hinaus nützlich, speichere sie mit `learn_lesson`
   (eine Anweisung, keine Einzelheiten dieses Auftrags; `scope` „projekt“, wenn sie nur hier gilt).
   Sag nicht, dass du sie gespeichert hast, wenn der Aufruf fehlschlug.

Unterscheide ehrlich: **„wusste ich nicht“** (in Ordnung, sag es), **„habe ich nicht geprüft“** (der behebbare Fall) und
**„habe ich erfunden“** (der wichtigste Fall). Weißt du nicht, warum es passiert ist, ist genau das der Befund.

*Angelehnt an den Skill „self-rca“ aus [KiroCrew](https://github.com/kirodotdev/KiroCrew) (Apache 2.0), übersetzt und für KI/lokal angepasst.*
