import Foundation

/// Merkt sich erfolgreiche Aufträge (Stichwörter + benutzte Werkzeuge), um Wiederholungen zu erkennen:
/// Erledigt der Agent zum dritten Mal etwas Ähnliches, schlägt die App vor, daraus einen Skill zu machen –
/// aus allen passenden Gesprächen zusammen, damit die Anleitung verallgemeinert statt einen Einzelfall nachzuerzählen.
struct TaskPattern: Codable, Hashable {
    var chatID: String
    var date = Date()
    var words: Set<String>
    var tools: Set<String>
}

enum TaskPatterns {
    static var file = Paths.base.appendingPathComponent("patterns.json")
    /// Ab dieser Ähnlichkeit gelten zwei Aufträge als „dasselbe noch einmal“.
    static let threshold = 0.4

    private static let stopwords: Set<String> = [
        "aber", "alle", "allem", "also", "auch", "auf", "aus", "bei", "bitte", "das", "dass", "dem", "den", "der", "des", "die",
        "dies", "diese", "diesen", "dieser", "doch", "ein", "eine", "einen", "einer", "eines", "für", "hier", "ich", "ihr", "im",
        "in", "ist", "kannst", "mach", "mache", "mal", "meine", "meinen", "meiner", "mich", "mir", "mit", "nach", "nicht", "noch",
        "nur", "oder", "sich", "sie", "sind", "und", "uns", "von", "vor", "was", "wie", "wir", "wird", "zum", "zur", "über",
        "the", "and", "for", "with", "this", "that", "please", "jetzt", "dann", "dazu", "einmal", "heute", "gerne",
    ]

    /// Kennzeichnende Wörter eines Auftrags (klein, ohne Füllwörter, Zahlen und angehängte Dateien).
    static func keywords(_ text: String) -> Set<String> {
        let body = text.components(separatedBy: "\n").filter { !$0.hasPrefix("📎") }.joined(separator: " ")
        return Set(body.lowercased().split { !$0.isLetter }.map(String.init)
            .filter { $0.count >= 4 && !stopwords.contains($0) }.prefix(60))
    }

    static func similarity(_ a: TaskPattern, _ b: TaskPattern) -> Double {
        func jaccard(_ x: Set<String>, _ y: Set<String>) -> Double {
            x.isEmpty || y.isEmpty ? 0 : Double(x.intersection(y).count) / Double(x.union(y).count)
        }
        // Gleiche Werkzeuge allein heißt wenig (fast alles nutzt read_file) – die Wörter zählen mehr.
        return 0.65 * jaccard(a.words, b.words) + 0.35 * jaccard(a.tools, b.tools)
    }

    static func load() -> [TaskPattern] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([TaskPattern].self, from: data)) ?? []
    }

    /// Auftrag eintragen und frühere ähnliche Gespräche liefern (ohne das aktuelle, neueste zuerst).
    static func record(_ pattern: TaskPattern, into list: [TaskPattern]? = nil, persist: Bool = true) -> [String] {
        var all = (list ?? load()).filter { $0.chatID != pattern.chatID }
        let similar = all.filter { similarity($0, pattern) >= threshold }.sorted { $0.date > $1.date }.map(\.chatID)
        all.append(pattern)
        if all.count > 300 { all.removeFirst(all.count - 300) }
        if persist {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(all).write(to: file, options: .atomic)
        }
        return similar
    }
}
