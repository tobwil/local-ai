---
name: rechnungen-ordnen
description: Rechnungen und Belege (PDF) auslesen – Übersicht mit Summen als Excel, auf Wunsch einheitlich benennen und nach Monat sortieren. Nutzen bei "Rechnungen sortieren", "Belege ordnen", "Übersicht der Rechnungen", "Buchhaltung vorbereiten".
---

# Rechnungen ordnen

Nur tun, was verlangt ist – nichts zusätzlich. Wenige Schritte, jede Datei einmal.

1. `list_directory`, dann jede PDF einmal mit `read_file` lesen. Merken: Datum, Firma, Rechnungsnummer, Netto, USt, Brutto.
   Fehlt ein Wert: „–“, nicht raten.
2. **Übersicht** (wenn verlangt): **ein** `create_document` als `rechnungen-uebersicht.xlsx` – nur die Rechnungen als Tabelle
   | Datum | Firma | Rechnungsnr. | Netto | USt | Brutto | (Datum TT.MM.JJJJ, Beträge als 1.234,56 €), **ohne** Summenzeilen,
   dazu `totals`: `{"sum": ["Netto", "USt", "Brutto"], "per_month": true}`. Die App sortiert, baut die Summen je Monat
   und gesamt und meldet die Werte zurück. Danach die Datei nicht mehr anfassen – kein Neuschreiben, keine Skripte.
3. Ohne Excel-Datei: Summen mit `calculate` ausrechnen (je Monat und gesamt).
4. **Umbenennen und sortieren** (nur wenn verlangt): ein einziges `run_shell` mit `mkdir -p` und `mv` nach
   `JJJJ-MM/JJJJ-MM-TT_Firma_Brutto.pdf` (Firma ohne Rechtsform, Umlaute ae/oe/ue, Leerzeichen → Bindestrich).
5. **Antwort im Chat**, kurz: Summen je Monat und gesamt genau so, wie die App sie gemeldet hat, Auffälligkeiten (fehlende Werte; ausländische Rechnung →
   „Reverse Charge mit der Steuerberatung klären“). Keine Steuerberatung.
