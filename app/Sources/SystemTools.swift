import AppKit
import Foundation

/// Werkzeuge rund um den Mac: Zwischenablage, Mitteilungen, HTTP-Anfragen und ein dauerhaftes Gedächtnis.
enum SystemTools {
    static let memoryFile = Paths.base.appendingPathComponent("memory.md")

    static func all() -> [AgentTool] {
        [
            AgentTool(name: "clipboard_read", description: "Liest den Text aus der Zwischenablage.",
                      parameters: schema([], required: []), needsApproval: false, source: "Mac") { _ in
                await MainActor.run { NSPasteboard.general.string(forType: .string) } ?? "(Zwischenablage enthält keinen Text)"
            },
            AgentTool(name: "clipboard_write", description: "Legt Text in die Zwischenablage, damit der Nutzer ihn einfügen kann.",
                      parameters: schema([("text", "string", "Text")], required: ["text"]), needsApproval: false, source: "Mac") { args in
                let text = try BuiltinTools.string(args, "text")
                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                return "In der Zwischenablage (\(text.count) Zeichen)"
            },
            AgentTool(name: "notify", description: "Zeigt eine macOS-Mitteilung, z. B. wenn eine lange Aufgabe fertig ist.",
                      parameters: schema([("title", "string", "Titel"), ("message", "string", "Text")], required: ["message"]),
                      needsApproval: false, source: "Mac") { args in
                let title = args["title"] as? String ?? "Local AI"
                let msg = try BuiltinTools.string(args, "message")
                let script = "display notification \(appleScriptString(msg)) with title \(appleScriptString(title))"
                _ = try await Shell.exec(["/usr/bin/osascript", "-e", script], cwd: Paths.home)
                return "Mitteilung gezeigt"
            },
            AgentTool(name: "http_request",
                      description: "HTTP-Anfrage an eine API (GET/POST/PUT/PATCH/DELETE) mit optionalen Headern und Body; liefert Status, wichtige Header und Antwort.",
                      parameters: schema([("method", "string", "GET, POST, PUT, PATCH oder DELETE"), ("url", "string", "Adresse"),
                                          ("headers", "object", "Header als Objekt, z. B. {\"Authorization\": \"Bearer …\"}"),
                                          ("body", "string", "Request-Body (z. B. JSON als Text)")], required: ["url"]),
                      needsApproval: true, source: "Web") { args in
                guard let url = URL(string: try BuiltinTools.string(args, "url")), ["http", "https"].contains(url.scheme ?? "") else {
                    throw ToolError.invalid("Ungültige URL")
                }
                var req = URLRequest(url: url)
                req.httpMethod = (args["method"] as? String ?? "GET").uppercased()
                req.timeoutInterval = 60
                for (k, v) in args["headers"] as? [String: Any] ?? [:] { req.setValue("\(v)", forHTTPHeaderField: k) }
                if let body = args["body"] as? String {
                    req.httpBody = Data(body.utf8)
                    if req.value(forHTTPHeaderField: "Content-Type") == nil, body.hasPrefix("{") || body.hasPrefix("[") {
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    }
                }
                let (data, resp) = try await URLSession.shared.data(for: req)
                let http = resp as? HTTPURLResponse
                let headers = ["Content-Type", "Location", "Retry-After"].compactMap { h in http?.value(forHTTPHeaderField: h).map { "\(h): \($0)" } }
                var text = String(decoding: data, as: UTF8.self)
                if text.count > 30_000 { text = String(text.prefix(30_000)) + "\n… (gekürzt)" }
                return "HTTP \(http?.statusCode ?? 0)\n\(headers.joined(separator: "\n"))\n\n\(text)"
            },
            AgentTool(name: "remember",
                      description: "Merkt sich dauerhaft eine Information über den Nutzer oder seine Vorlieben (gilt in allen künftigen Gesprächen). Nur Dinge speichern, die der Nutzer mitteilt oder die eindeutig dauerhaft nützlich sind.",
                      parameters: schema([("fact", "string", "Kurzer, eigenständiger Satz")], required: ["fact"]),
                      needsApproval: false, source: "Gedächtnis") { args in
                let fact = try BuiltinTools.string(args, "fact").replacingOccurrences(of: "\n", with: " ")
                var text = memory()
                text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + "- \(fact) (\(Date().formatted(date: .numeric, time: .omitted)))\n"
                try FileManager.default.createDirectory(at: Paths.base, withIntermediateDirectories: true)
                try text.write(to: memoryFile, atomically: true, encoding: .utf8)
                return "Gemerkt."
            },
            AgentTool(name: "forget",
                      description: "Entfernt Einträge aus dem Gedächtnis, die den angegebenen Text enthalten.",
                      parameters: schema([("text", "string", "Suchtext")], required: ["text"]),
                      needsApproval: false, source: "Gedächtnis") { args in
                let needle = try BuiltinTools.string(args, "text").lowercased()
                let lines = memory().components(separatedBy: "\n")
                let kept = lines.filter { !$0.lowercased().contains(needle) }
                try kept.joined(separator: "\n").write(to: memoryFile, atomically: true, encoding: .utf8)
                return "\(lines.count - kept.count) Eintrag/Einträge entfernt."
            },
        ]
    }

    static func memory() -> String {
        (try? String(contentsOf: memoryFile, encoding: .utf8)) ?? ""
    }

    private static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
