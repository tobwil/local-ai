---
name: gummiente
description: Gummienten-Prüfung gegen Halluzinationen – eine Analyse, ein Konzept oder einen Bericht von Grund auf neu erklären und jede Behauptung gegen Quellen prüfen, bevor er rausgeht. Nutzen bei "Gummiente", "rubber duck", "erklär das einem Skeptiker", "ist das wirklich belegt", "prüf meinen Bericht auf Ehrlichkeit", "stimmt das alles".
---

# Gummienten-Prüfung

Ziel: Ergebnisse, die vollständig sind, ehrliche Lücken haben und nur Belegtes als Tatsache darstellen.

1. **Neu erklären, nicht abschreiben.** Erkläre das Thema in eigenen Worten von vorn – Ziel, Vorgehen, Ergebnis,
   wichtigste Zahlen –, ohne die vorhandene Fassung zu kopieren. Wo die Erklärung ins Stocken gerät oder von der
   schriftlichen Fassung abweicht, ist ein Befund.
2. **Behauptungen auflisten.** Jede Aussage, die als Tatsache dasteht, in eine Liste: Zahlen, Ursachen, „immer/nie“,
   Vergleiche, Zitate.
3. **Jede prüfen – mit Werkzeugen.** Quelle lesen (`read_file`, `search_documents`, `fetch_url`), Befehl ausführen
   (`run_shell`), nachsuchen (`web_search`). Einordnen:
   - ✅ **belegt** (mit Quelle/Datei:Zeile)
   - 🟡 **gefolgert** (plausibel, aber nicht direkt belegt – so kennzeichnen)
   - ❌ **unbelegt oder falsch** (streichen oder korrigieren)
4. **Skeptiker fragen.** Stell dir die drei unbequemsten Fragen eines Fachmanns, der die Arbeit nicht kennt:
   Was fehlt? Welche Größenordnung ist nicht begründet? Was wäre, wenn die zentrale Annahme falsch ist?
   Ist `ask_expert` verfügbar und der Nutzer einverstanden (Daten verlassen den Mac), lass ein Cloud-Modell die
   Zusammenfassung **ohne** deine Begründung angreifen – ein Modell, das nicht mitgearbeitet hat, sieht mehr.
5. **Ergebnis.** Liste der Befunde nach Gewicht, danach die bereinigte Fassung (geänderte Stellen markiert) und ein
   ehrlicher Absatz „Was offen bleibt“.

Erfinde keine Belege. Findest du keine Quelle, ist „nicht belegt“ die richtige Antwort.

*Angelehnt an den Skill „rubber-duck“ aus [KiroCrew](https://github.com/kirodotdev/KiroCrew) (Apache 2.0), übersetzt und für ein lokales Modell angepasst.*
