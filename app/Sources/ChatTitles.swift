import Foundation

/// Kurze Gesprächstitel („Pomodoro-Uhr als Webseite“) statt des abgeschnittenen ersten Satzes. Das Modell schlägt sie vor,
/// sobald ein Gespräch eine Antwort hat; bis dahin (oder ohne Engine) steht der bereinigte Anfang der ersten Nachricht da.
@MainActor
enum ChatTitles {
    private static var backfilling = false

    /// Erste Zeile der Nachricht (ohne Anhänge), bei langem Text nur der erste Satz, höchstens 60 Zeichen.
    static func fallback(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var t = lines.first { !$0.isEmpty && !$0.hasPrefix("📎") && !$0.hasPrefix("<") } ?? "Neues Gespräch"
        if let r = t.range(of: #"[.!?:](\s|$)"#, options: .regularExpression), t.distance(from: t.startIndex, to: r.lowerBound) >= 12 {
            t = String(t[..<r.lowerBound])
        }
        // Kurz genug für die Seitenleiste; an einer Wortgrenze kürzen statt mitten im Wort.
        guard t.count > 40 else { return t }
        let cut = String(t.prefix(40))
        let words = cut.split(separator: " ").dropLast()
        return (words.count >= 2 ? words.joined(separator: " ") : cut).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) + " …"
    }

    /// Titelvorschlag des Modells (2–5 Wörter) oder nil, wenn nichts Brauchbares kommt.
    static func suggest(user: String, answer: String, model: String) async -> String? {
        let system = "Du benennst Gespräche. Antworte nur mit einem kurzen Titel aus 2 bis 5 Wörtern in der Sprache des Gesprächs – ohne Anführungszeichen, ohne Punkt, ohne Erklärung."
        let prompt = "Nachricht:\n\(user.prefix(800))\n\nAnfang der Antwort:\n\(answer.prefix(400))\n\nTitel:"
        guard let raw = try? await LLMClient.collect(model: model, system: system, prompt: prompt, maxTokens: 24) else { return nil }
        return clean(raw)
    }

    static func clean(_ raw: String) -> String? {
        var text = raw
        if let r = text.range(of: "</think>") { text = String(text[r.upperBound...]) }
        var t = text.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        if t.lowercased().hasPrefix("titel:") { t = String(t.dropFirst(6)) }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"„“”'`*#.:«»").union(.whitespaces))
        let cjk = t.unicodeScalars.contains { (0x3000...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
        guard !t.isEmpty, t.count <= 60, !cjk else { return nil }
        return t
    }

    /// Erste Nachricht und erste Antwort eines gespeicherten Gesprächs.
    static func firstExchange(_ json: [String: Any]) -> (user: String, answer: String)? {
        let items = json["items"] as? [[String: Any]] ?? []
        guard let user = items.first(where: { $0["k"] as? String == "user" })?["text"] as? String else { return nil }
        let answer = items.first(where: { $0["k"] as? String == "assistant" && !($0["text"] as? String ?? "").isEmpty })?["text"] as? String
        guard let answer else { return nil }
        return (user, answer)
    }

    /// Ältere Gespräche ohne Kurztitel nachträglich benennen (neueste zuerst) – nur mit lokalem Modell und solange
    /// der Agent nicht arbeitet. Einmal pro Gespräch: Klappt es nicht, bleibt der Anfang der ersten Nachricht.
    static func backfill(_ app: AppState) {
        guard !backfilling, !app.selectedIsCloud else { return }
        backfilling = true
        Task {
            defer { backfilling = false }
            for entry in ChatStore.list().filter({ !$0.hasShortTitle }).prefix(40) {
                guard !app.session.isRunning, app.server.state.isUp, !app.selectedIsCloud else { return }
                guard let json = ChatStore.load(id: entry.id), let first = firstExchange(json) else { continue }
                let title = await suggest(user: first.user, answer: first.answer, model: app.selectedModelID)
                ChatStore.setAutoTitle(id: entry.id, title ?? "")
                app.session.storeChanged()
            }
        }
    }
}
