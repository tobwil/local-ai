---
name: perspektiven-rat
description: Schwierige oder strittige Fragen aus mehreren Blickwinkeln beraten lassen – Befürworter, Kritiker, Pragmatiker – und daraus eine abgewogene Empfehlung machen. Nutzen bei "frag den Rat", "mehrere Meinungen", "Pro und Contra", "zweite Meinung", "abstimmen", "red team", "soll ich X oder Y".
---

# Perspektiven-Rat

Du führst den Vorsitz: Du holst mehrere Sichtweisen ein und fasst sie zu einer Empfehlung zusammen.
Nur für schwere, wichtige oder strittige Fragen – für einfache Fragen direkt antworten.

**Ehrlich bleiben:** Lokal spricht dasselbe Modell in mehreren Rollen. Das bringt Struktur und Gegenargumente, aber
keine wirklich unabhängigen Meinungen. Ist `ask_expert` verfügbar, biete an, ein Cloud-Modell als echtes zweites
Mitglied dazuzunehmen (Daten verlassen dabei den Mac – nur mit Zustimmung).

## Ablauf

1. **Frage schärfen.** Was genau ist zu entscheiden, welche Optionen gibt es, was zählt (Kosten, Zeit, Risiko …)?
   Fakten vorher mit Werkzeugen holen, damit alle Rollen vom selben Stand ausgehen.
2. **Modus wählen:**
   - **Abwägen** (Standard): jede Rolle antwortet für sich.
   - **Abstimmen**: bei festen Optionen gibt jede Rolle genau eine Stimme `STIMME: <Option>` mit einem Satz Begründung.
   - **Angreifen**: bei einem fertigen Plan oder Text – Kritiker und Verteidiger, Ergebnis FREIGEBEN / ÜBERARBEITEN / VERWERFEN.
3. **Rollen nacheinander, klar getrennt** (jede 4–8 Sätze, jede beginnt neu und ohne Rücksicht auf die anderen):
   - 🟢 **Befürworterin** – die stärksten Gründe dafür
   - 🔴 **Kritiker** – was schiefgehen kann, versteckte Kosten, schwächste Annahme
   - 🟡 **Pragmatikerin** – was realistisch umsetzbar ist, kleinster sinnvoller Schritt
   - optional ☁️ **Experte** über `ask_expert` (nur die Frage und Fakten mitgeben, nicht die anderen Rollen)
4. **Vorsitz: Ergebnis.**
   - Wo sind sich alle einig, wo nicht?
   - Empfehlung in einem Satz, dann die Begründung.
   - Was die Entscheidung kippen würde (Bedingung, unter der eine andere Option besser wäre).
   - Beim Abstimmen: Auszählung offen zeigen.

*Angelehnt an den Skill „llm-council“ aus [KiroCrew](https://github.com/kirodotdev/KiroCrew) (Apache 2.0), übersetzt und für ein lokales Modell angepasst.*
