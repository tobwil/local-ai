import Foundation

/// Hilfen für lange Aufträge: Plan des Agenten und Wiederaufnahme eines Verlaufs, der mitten im Schritt abbrach.
enum Checkpoint {
    /// Abschnitt für den Systemprompt. Er wird nur beim Verdichten oder Fortsetzen erneuert (dann ist der
    /// Prompt-Cache ohnehin neu) – sonst bliebe der Anfang des Verlaufs nicht stabil.
    static func planSection(_ plan: String) -> String {
        let p = plan.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return "" }
        return "\n\n## Dein Plan für diesen Auftrag (Stand beim letzten Verdichten – mit update_plan aktuell halten)\n" + String(p.prefix(3_000))
    }

    /// „3/7 erledigt“ aus einer Markdown-Checkliste.
    static func progress(_ plan: String) -> (done: Int, total: Int) {
        var done = 0, total = 0
        for line in plan.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces).lowercased()
            if t.hasPrefix("- [x]") || t.hasPrefix("* [x]") || t.hasPrefix("- [✓]") { done += 1; total += 1 }
            else if t.hasPrefix("- [ ]") || t.hasPrefix("* [ ]") { total += 1 }
        }
        return (done, total)
    }

    /// Ein abgebrochener Lauf kann Werkzeug-Aufrufe ohne Ergebnis hinterlassen. Die APIs verlangen zu jedem Aufruf
    /// eine Antwort – fehlende werden direkt hinter den vorhandenen Ergebnissen ergänzt.
    static func repairToolCalls(_ history: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var i = 0
        while i < history.count {
            let m = history[i]
            out.append(m)
            i += 1
            guard m["role"] as? String == "assistant", let calls = m["tool_calls"] as? [[String: Any]], !calls.isEmpty else { continue }
            var answered = Set<String>()
            while i < history.count, history[i]["role"] as? String == "tool" {
                if let id = history[i]["tool_call_id"] as? String { answered.insert(id) }
                out.append(history[i])
                i += 1
            }
            for c in calls {
                guard let id = c["id"] as? String, !answered.contains(id) else { continue }
                out.append(["role": "tool", "tool_call_id": id,
                            "content": "(Abgebrochen: Die App wurde während dieses Aufrufs beendet – Ergebnis unbekannt, bei Bedarf erneut prüfen.)"])
            }
        }
        return out
    }

    /// Nachrichten, mit denen die App selbst einen Auftrag fortsetzt (zählen nicht als neuer Auftrag).
    static let continuePrefix = "Mach weiter"
}
