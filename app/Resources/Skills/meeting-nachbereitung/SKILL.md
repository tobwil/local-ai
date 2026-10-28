---
name: meeting-nachbereitung
description: Aus einer Besprechungsaufnahme (Audio/Video) oder einem Transkript ein Protokoll mit Entscheidungen und Aufgaben (wer, bis wann) machen – auf Wunsch mit Follow-up-Mail. Nutzen bei "Meeting nachbereiten", "Protokoll aus Aufnahme", "Aufgaben aus dem Meeting".
---

# Meeting nachbereiten

Wenige Schritte, jede Datei einmal. Nur was gesagt wurde – nichts erfinden.

1. Audio/Video: einmal `transcribe` (lokal). Das Transkript steht danach in der Antwort – nicht erneut lesen.
2. Datum: Fehlt das Jahr, gilt das aktuelle Jahr (heutiges Datum steht oben). Relative Fristen („bis Freitag“,
   „Ende der Woche“) mit `date_calc` in TT.MM.JJJJ umrechnen und den Wochentag prüfen – nie im Kopf.
3. **Ein** `create_document` als `Protokoll_<JJJJ-MM-TT>.docx`: Datum, Teilnehmende (Namen aus dem Gespräch), Themen
   in je 1–2 Sätzen, **Entscheidungen**, Tabelle | Aufgabe | Wer | Bis wann |, offene Fragen, nächster Termin.
   Fehlt etwas: „–“. Transkripte trennen die Sprecher nicht – nicht raten, wer was sagte, nur Namen aus dem Text.
4. Follow-up-Mail nur, wenn verlangt: als Text im Chat (oder `mail_draft`, wenn ausdrücklich gewünscht – nie senden).
5. **Im Chat** auf Deutsch: die Aufgaben-Tabelle und der Dateiname.
