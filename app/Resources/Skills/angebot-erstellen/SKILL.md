---
name: angebot-erstellen
description: Aus einer Kundenanfrage (Mail, Text, PDF) und einer Preisliste ein Angebot als Word-Datei schreiben – Positionen, Rabatte, Summen, kurzes Anschreiben. Nutzen bei "Angebot schreiben", "Kostenvoranschlag", "Angebot für die Anfrage".
---

# Angebot erstellen

Wenige Schritte, jede Datei einmal. Nichts im Web nachschlagen.

1. Anfrage und Preisliste je einmal mit `read_file` lesen. Nur Preise aus der Preisliste verwenden.
2. Positionen festlegen: Menge × Einzelpreis; Zuschläge (z. B. zusätzliche Teilnehmende); Anfahrt – steht
   „Hin- und Rückfahrt“, dann Kilometer × 2; Rabatte nur auf die Positionen, für die sie gelten.
3. **Nicht selbst rechnen:** **ein** `create_document` als `Angebot_<Kunde>.docx` mit Empfänger, Datum, Betreff, drei Sätzen
   Anschreiben zur Anfrage und der Positionstabelle | Pos. | Leistung | Menge | Einzelpreis | Gesamt | – **ohne** Summenzeilen,
   dazu `totals`: `{"line": ["Menge", "Einzelpreis", "Gesamt"], "sum": ["Gesamt"], "discount_percent": 5, "vat_percent": 19}`
   (Rabatt nur, wenn er laut Preisliste gilt). Die App rechnet Zeilen, Zwischensumme, Rabatt, Netto, USt und Brutto aus und
   meldet die Werte zurück. Danach Gültigkeit 30 Tage, Zahlung 14 Tage, Gruß. Datei nicht mehr anfassen.
4. Ohne Dokument: Beträge mit `calculate` rechnen.
5. **Im Chat:** Netto und Brutto genau so, wie die App sie gemeldet hat, Abgleich mit dem Budget (liegt es darüber: eine günstigere Variante in einem Satz nennen),
   höchstens zwei offene Fragen an den Kunden.
