---
name: vertrag-checken
description: Einen Vertrag (PDF, Word) lesen und Fristen, Kosten und auffällige Klauseln als kurze Checkliste aufbereiten – keine Rechtsberatung. Nutzen bei "Vertrag prüfen", "worauf muss ich achten", "Fristen im Vertrag", "Mietvertrag durchsehen".
---

# Vertrag durchsehen

Strukturierte Lesehilfe, **keine Rechtsberatung** – das steht in einem Satz am Ende. Wenige Schritte.

1. Den Vertrag einmal ganz lesen (`read_file`, lange Dateien abschnittsweise bis zum Ende).
2. **Rechnen mit Werkzeugen, nie im Kopf:** Kosten mit `calculate` (Monatsbelastung, Summe über die Laufzeit, Kaution),
   jede Frist mit `date_calc` (z. B. Laufzeitende minus 12 Monate).
3. **Antwort als Checkliste im Chat** (nur auf Wunsch zusätzlich `create_document` als PDF):
   - **Eckdaten:** Parteien, Gegenstand, Beginn, Laufzeit, Verlängerung – mit §
   - **Fristen mit Datum** (z. B. „Widerspruch gegen Verlängerung bis 31.12.2030“)
   - **Kosten:** monatlich, über die Laufzeit, zusätzlich mögliche Kosten (mit Obergrenze, falls genannt)
   - **Auffällige Klauseln:** je § ein Satz, was sie bedeutet, und eine Frage für die Verhandlung
