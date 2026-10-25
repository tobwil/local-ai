import Foundation

/// Wählt das Modell nach Thema der Nachricht – schnell und ohne zusätzlichen Modellaufruf.
/// Auf Macs mit wenig Speicher passt nur ein großes Modell; ein Wechsel kostet Ladezeit.
enum ModelRouter {
    enum Topic: String, CaseIterable, Identifiable {
        case general, code, vision
        var id: String { rawValue }
        var label: String {
            switch self {
            case .general: return "Allgemein (Wissen, Texte, Chat)"
            case .code: return "Code & Agent-Aufgaben"
            case .vision: return "Bilder"
            }
        }
        var icon: String {
            switch self {
            case .general: return "text.bubble"
            case .code: return "chevron.left.forwardslash.chevron.right"
            case .vision: return "eye"
            }
        }
    }

    static func classify(_ text: String, hasImages: Bool, isCommand: Bool) -> Topic {
        if hasImages { return .vision }
        if isCommand { return .code }
        let t = text.lowercased()
        if t.contains("```") { return .code }
        let codeWords = ["code", "bug", "fehler", "error", "exception", "stacktrace", "stack trace", "traceback",
                         "compile", "kompilier", "refactor", "funktion", "function", "klasse", "class ", "methode",
                         "skript", "script", "programm", "terminal", "shell", "git ", "commit", "repo", "api",
                         "json", "regex", "sql", "datei", "ordner", "debug", "test", "build", "xcode", "swift",
                         "python", "javascript", "typescript", "rust", "golang", "kotlin", "java ", "c++", "html", "css"]
        let hits = codeWords.filter { t.contains($0) }.count
        let fileRef = WebSearch.matches(t, #"\b[\w/.-]+\.(py|swift|js|ts|tsx|go|rs|java|kt|c|cpp|h|m|rb|php|sh|yml|yaml|json|md|toml)\b"#).count
        return hits + fileRef * 2 >= 2 ? .code : .general
    }
}
