import Foundation

/// Arbeitsweise des Agenten – ergibt sich aus dem Projekt (Code-Ordner → Code) oder wird dort fest eingestellt.
/// Jede hat eigene Werkzeuge und Hinweise im Systemprompt. Weniger Werkzeuge halten den Prompt kurz
/// (schnellerer Start) und erleichtern dem lokalen Modell die Wahl. Automationen nutzen weiter alle Werkzeuge.
enum WorkMode: String, CaseIterable, Identifiable {
    case chat, work, code
    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .work: return "Arbeiten"
        case .code: return "Code"
        }
    }

    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .work: return "briefcase"
        case .code: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// Zusatz hinter „KI/“ im leeren Gespräch.
    var wordmark: String {
        switch self {
        case .chat: return "chat"
        case .work: return "arbeit"
        case .code: return "code"
        }
    }

    var tagline: String {
        switch self {
        case .chat: return "Fragen, Ideen, Texte – schnell und ohne Werkzeug-Umwege"
        case .work: return "Erledigt Aufgaben mit Dateien, Web, Kalender, Mail und Browser"
        case .code: return "Programmiert im Projektordner: lesen, ändern, ausführen, prüfen"
        }
    }

    var help: String {
        switch self {
        case .chat: return "Chat: Gespräch mit Websuche und deinen Dokumenten – ohne Datei- oder Shell-Zugriff"
        case .work: return "Arbeiten: alle Werkzeuge für Alltagsaufgaben (Dateien, Web, Kalender, Mail, Browser, MCP)"
        case .code: return "Code: Projektordner, Dateien, Shell und Web – mit schnellem Code-Dekodieren (MTP)"
        }
    }

    /// Chat braucht keinen Arbeitsordner (und damit auch kein YOLO).
    var hasWorkspace: Bool { self != .chat }

    func allows(_ tool: AgentTool) -> Bool {
        switch self {
        case .chat: return Self.chatTools.contains(tool.name)
        case .work: return true
        case .code: return !Self.notForCode.contains(tool.source)
        }
    }

    private static let chatTools: Set<String> = ["web_search", "fetch_url", "search_documents", "remember", "forget", "learn_lesson",
                                                 "ask_expert", "look_at_screen", "open_canvas", "create_document", "transcribe",
                                                 "calculate", "date_calc", "table_summary"]
    private static let notForCode: Set<String> = ["Kalender", "Erinnerungen", "Kontakte", "Mail", "Browser"]

    var ideas: [(icon: String, text: String)] {
        switch self {
        case .chat:
            return [("text.quote", "Formuliere diese Mail freundlicher und kürzer: …"),
                    ("lightbulb", "Gib mir fünf Ideen für einen Team-Workshop zum Thema KI im Alltag."),
                    ("globe", "Was sind die wichtigsten KI-Neuigkeiten dieser Woche? Mit Quellen."),
                    ("character.book.closed", "Erkläre mir Mixture-of-Experts so, dass es ein 12-Jähriger versteht.")]
        case .work:
            return [("folder", "Was liegt in meinem Arbeitsordner? Fasse die wichtigsten Dateien zusammen."),
                    ("calendar", "Was steht heute und morgen in meinem Kalender? Gibt es Überschneidungen?"),
                    ("doc.text.magnifyingglass", "Recherchiere drei Anbieter für Videokonferenz-Hardware und vergleiche sie in einer Tabelle."),
                    ("terminal", "Wie viel Speicherplatz ist auf meinem Mac frei? Prüfe es mit einem Shell-Befehl.")]
        case .code:
            return [("map", "Verschaffe dir einen Überblick über dieses Projekt und erkläre mir Aufbau und Einstieg."),
                    ("chevron.left.forwardslash.chevron.right", "Schreibe ein Python-Skript, das alle Fotos in einem Ordner nach Datum sortiert, und speichere es als sort_photos.py."),
                    ("checkmark.seal", "Führe die Tests aus und behebe, was fehlschlägt."),
                    ("gamecontroller", "Programmiere ein kleines Browser-Spiel (HTML + Canvas) und prüfe es mit node --check.")]
        }
    }
}
