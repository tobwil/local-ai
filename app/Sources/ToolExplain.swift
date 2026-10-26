import Foundation

/// Übersetzt einen Werkzeug-Aufruf in Klartext für die Freigabe: was der Agent tun will, das Wichtigste daraus
/// (Befehl, Datei, Adresse) und warum KI/lokal nachfragt.
enum ToolExplain {
    struct Info {
        let summary: String
        let detail: String?
        let detailLabel: String
        let risk: String
    }

    static func path(of arguments: String) -> String? {
        ((try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any])?["path"] as? String
    }

    /// Kurze Zeile für die Liste der Arbeitsschritte, z. B. „index.html geändert“.
    static func short(name: String, arguments: String) -> (icon: String, text: String) {
        let a = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]) ?? [:]
        func s(_ k: String) -> String { a[k] as? String ?? "" }
        func file(_ k: String = "path") -> String { let p = s(k); return p.isEmpty ? "." : (p as NSString).lastPathComponent }
        switch name {
        case "list_directory": return ("folder", "Ordner angesehen: \(file())")
        case "read_file": return ("doc.text", "Gelesen: \(file())")
        case "find_files": return ("magnifyingglass", "Dateien gesucht: \(s("pattern"))")
        case "search_files": return ("text.magnifyingglass", "Im Code gesucht: \(s("query").isEmpty ? s("pattern") : s("query"))")
        case "write_file": return ("square.and.pencil", "Geschrieben: \(file())")
        case "edit_file": return ("pencil.line", "Geändert: \(file())")
        case "replace_lines": return ("text.line.first.and.arrowtriangle.forward", "Zeilen \(a["start_line"] ?? "?")–\(a["end_line"] ?? "?") ersetzt: \(file())")
        case "run_shell": return ("terminal", "Befehl: \(s("command").replacingOccurrences(of: "\n", with: " ").prefix(90))")
        case "web_search": return ("globe", "Im Web gesucht: \(s("query"))")
        case "fetch_url": return ("safari", "Seite gelesen: \(URL(string: s("url"))?.host() ?? s("url"))")
        case "http_request": return ("network", "\((a["method"] as? String ?? "GET").uppercased()) \(URL(string: s("url"))?.host() ?? s("url"))")
        case "create_document": return ("doc.richtext", "Dokument erstellt: \(file())")
        case "open_canvas": return ("rectangle.and.pencil.and.ellipsis", "Canvas geöffnet: \(s("title"))")
        case "transcribe": return ("waveform", "Transkribiert: \(file())")
        case "search_documents": return ("books.vertical", "Im Wissen gesucht: \(s("query"))")
        case "use_skill": return ("book.pages", "Skill geladen: \(s("name"))")
        case "run_agent": return ("person.2", "Sub-Agent: \(s("agent"))")
        case "ask_expert": return ("cloud", "Cloud-Experte gefragt")
        case "look_at_screen": return ("camera.viewfinder", "Bildschirm angesehen")
        case "calendar_events": return ("calendar", "Kalender gelesen")
        case "calendar_create": return ("calendar.badge.plus", "Termin angelegt: \(s("title"))")
        case "reminders_list": return ("checklist", "Erinnerungen gelesen")
        case "reminders_create": return ("checklist", "Erinnerung angelegt: \(s("title"))")
        case "mail_recent": return ("envelope", "Mails gelesen")
        case "mail_draft": return ("envelope.badge", "Mail-Entwurf: \(s("subject"))")
        case "contacts_search": return ("person.crop.circle", "Kontakt gesucht: \(s("query"))")
        case "browser_open": return ("safari", "Im Browser geöffnet: \(URL(string: s("url"))?.host() ?? s("url"))")
        case "browser_read", "browser_tabs": return ("safari", "Browser gelesen")
        case "browser_click": return ("cursorarrow.click", "Im Browser geklickt")
        case "browser_type": return ("keyboard", "Im Browser getippt")
        case "remember": return ("brain", "Gemerkt")
        case "clipboard_read", "clipboard_write": return ("doc.on.clipboard", "Zwischenablage")
        case "notify": return ("bell", "Mitteilung gezeigt")
        default: return ("wrench.and.screwdriver", name)
        }
    }

    static func explain(name: String, source: String, arguments: String) -> Info {
        let a = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]) ?? [:]
        func s(_ k: String) -> String { a[k] as? String ?? "" }
        switch name {
        case "run_shell":
            return Info(summary: "Einen Befehl im Terminal ausführen", detail: s("command"), detailLabel: "Befehl",
                        risk: "Terminal-Befehle können Dateien ändern oder löschen, Programme starten und Daten ins Internet senden.")
        case "write_file":
            let path = s("path")
            let exists = FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath)
            let lines = s("content").components(separatedBy: "\n").count
            return Info(summary: "\(exists ? "Datei überschreiben" : "Neue Datei anlegen"): \(path) (\(lines) Zeilen)",
                        detail: String(s("content").prefix(1200)), detailLabel: "Inhalt (Anfang)",
                        risk: exists ? "Der bisherige Inhalt der Datei wird ersetzt." : "Legt eine Datei auf deinem Mac an.")
        case "edit_file":
            return Info(summary: "Datei ändern: \(s("path"))",
                        detail: "− \(s("old_text").prefix(500))\n+ \(s("new_text").prefix(500))", detailLabel: "Änderung",
                        risk: "Ändert eine bestehende Datei.")
        case "replace_lines":
            return Info(summary: "Zeilen \(a["start_line"] ?? "?")–\(a["end_line"] ?? "?") ersetzen in \(s("path"))",
                        detail: String(s("new_text").prefix(1200)), detailLabel: "Neuer Text", risk: "Ändert eine bestehende Datei.")
        case "create_document":
            return Info(summary: "Dokument erstellen: \(s("path"))", detail: String(s("content").prefix(800)), detailLabel: "Inhalt (Anfang)",
                        risk: "Legt eine Datei auf deinem Mac an (überschreibt eine gleichnamige).")
        case "http_request":
            let method = (a["method"] as? String ?? "GET").uppercased()
            return Info(summary: "\(method)-Anfrage an \(s("url"))", detail: a["body"].map { "\($0)".prefix(800).description }, detailLabel: "Daten",
                        risk: method == "GET" ? "Ruft eine Adresse im Internet ab." : "Sendet Daten an einen Server im Internet.")
        case "browser_open":
            return Info(summary: "Im Browser öffnen: \(s("url"))", detail: nil, detailLabel: "",
                        risk: "Handelt in deinem echten Browser – mit deinen Anmeldungen.")
        case "browser_click":
            return Info(summary: "Im Browser auf Element [\(a["index"].map { "\($0)" } ?? "?")] klicken", detail: nil, detailLabel: "",
                        risk: "Ein Klick kann etwas auslösen (absenden, bestellen, löschen) – mit deinen Anmeldungen.")
        case "browser_type":
            return Info(summary: "Im Browser Text eingeben", detail: s("text"), detailLabel: "Text",
                        risk: "Tippt in eine Webseite – mit deinen Anmeldungen.")
        case "calendar_create":
            return Info(summary: "Termin anlegen: \(s("title"))", detail: "\(s("start")) – \(s("end"))", detailLabel: "Zeit",
                        risk: "Trägt einen Termin in deinen Kalender ein.")
        case "reminders_create":
            return Info(summary: "Erinnerung anlegen: \(s("title"))", detail: nil, detailLabel: "", risk: "Legt eine Erinnerung an.")
        case "mail_draft":
            return Info(summary: "E-Mail-Entwurf an \(s("to")): \(s("subject"))", detail: String(s("body").prefix(800)), detailLabel: "Text",
                        risk: "Legt nur einen Entwurf in Mail an – gesendet wird nichts.")
        case "clipboard_write":
            return Info(summary: "In die Zwischenablage kopieren", detail: String(s("text").prefix(500)), detailLabel: "Text",
                        risk: "Ersetzt den Inhalt deiner Zwischenablage.")
        case "look_at_screen":
            return Info(summary: "Bildschirmfoto aufnehmen und auswerten", detail: nil, detailLabel: "",
                        risk: "Das Bild geht an das Vision-Modell (lokal, außer ein Cloud-Modell ist gewählt).")
        case "ask_expert":
            return Info(summary: "Frage an ein Cloud-Modell senden", detail: String(s("question").prefix(600)), detailLabel: "Frage",
                        risk: "Die Frage und der mitgegebene Kontext verlassen deinen Mac.")
        case "transcribe":
            return Info(summary: "Audio transkribieren: \(s("path"))", detail: nil, detailLabel: "", risk: "Läuft auf dem Mac.")
        default:
            let pretty = arguments.count > 2 ? arguments : nil
            return Info(summary: source.hasPrefix("MCP") || !["Eingebaut", "Web", "Mac"].contains(source)
                        ? "Werkzeug „\(name)“ von \(source) aufrufen" : "Werkzeug „\(name)“ ausführen",
                        detail: pretty.map { String($0.prefix(1000)) }, detailLabel: "Argumente",
                        risk: "Externe Werkzeuge (MCP) können je nach Server Daten lesen, ändern oder senden.")
        }
    }
}
