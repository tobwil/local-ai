---
name: skill-ersteller
description: Legt einen neuen Skill an oder verbessert einen bestehenden. Nutzen, wenn der Nutzer einen Ablauf dauerhaft speichern möchte ("merk dir, wie man …", "mach daraus einen Skill").
---

# Skill erstellen

Ein Skill ist ein Ordner unter `~/.kilokal/skills/<name>/` mit einer Datei `SKILL.md`:

```markdown
---
name: <kurzer-name-mit-bindestrichen>
description: <Was der Skill tut UND wann er benutzt werden soll – ein bis zwei Sätze, konkrete Auslöser>
---

# <Titel>

<Schritt-für-Schritt-Anleitung, Regeln, Beispiele>
```

Vorgehen:
1. Kläre kurz, was der Skill leisten soll und woran man erkennt, dass er passt.
2. Die `description` ist das Wichtigste: Danach entscheidet der Agent, ob er den Skill lädt.
3. Anleitung knapp und als nummerierte Schritte. Werkzeuge beim Namen nennen
   (read_file, web_search, run_shell …).
4. Zusatzmaterial (Vorlagen, Skripte, Referenzen) als weitere Dateien im selben Ordner ablegen
   und in SKILL.md erwähnen.
5. Mit `write_file` speichern. Der Skill steht ab dem nächsten neuen Gespräch zur Verfügung.
