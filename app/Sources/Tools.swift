import Foundation

/// Ein Werkzeug, das das Modell aufrufen kann – eingebaut oder von einem MCP-Server.
struct AgentTool: Identifiable {
    let name: String
    let description: String
    /// JSON-Schema der Argumente.
    let parameters: [String: Any]
    let needsApproval: Bool
    let source: String
    let run: ([String: Any]) async throws -> String

    var id: String { name }

    var openAISpec: [String: Any] {
        ["type": "function",
         "function": ["name": name, "description": description, "parameters": parameters]]
    }
}

enum BuiltinTools {
    static func all(workspace: @escaping () -> URL) -> [AgentTool] {
        [
            AgentTool(name: "list_directory",
                      description: "Listet Dateien und Ordner eines Verzeichnisses. Pfade relativ zum Arbeitsordner.",
                      parameters: schema(["path": "Verzeichnis, Standard: Arbeitsordner"], required: []),
                      needsApproval: false, source: "Eingebaut") { args in
                let url = resolve(args["path"] as? String ?? ".", in: workspace())
                let items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])
                return items.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(300).map { u in
                    let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    return v?.isDirectory == true ? "\(u.lastPathComponent)/" : "\(u.lastPathComponent)  (\(v?.fileSize ?? 0) B)"
                }.joined(separator: "\n")
            },
            AgentTool(name: "read_file",
                      description: "Liest eine Textdatei (bis 40.000 Zeichen).",
                      parameters: schema(["path": "Dateipfad"], required: ["path"]),
                      needsApproval: false, source: "Eingebaut") { args in
                let url = resolve(try string(args, "path"), in: workspace())
                let text = try String(contentsOf: url, encoding: .utf8)
                return text.count > 40_000 ? String(text.prefix(40_000)) + "\n… (gekürzt)" : text
            },
            AgentTool(name: "write_file",
                      description: "Schreibt eine Textdatei (legt Ordner an, überschreibt vorhandene Dateien).",
                      parameters: schema(["path": "Dateipfad", "content": "Vollständiger neuer Inhalt"], required: ["path", "content"]),
                      needsApproval: true, source: "Eingebaut") { args in
                let url = resolve(try string(args, "path"), in: workspace())
                let content = try string(args, "content")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: url, atomically: true, encoding: .utf8)
                return "Geschrieben: \(url.path) (\(content.utf8.count) Bytes)"
            },
            AgentTool(name: "run_shell",
                      description: "Führt einen Shell-Befehl (zsh) im Arbeitsordner aus. Timeout 120 s.",
                      parameters: schema(["command": "Befehl"], required: ["command"]),
                      needsApproval: true, source: "Eingebaut") { args in
                try await Shell.run(try string(args, "command"), cwd: workspace())
            },
            AgentTool(name: "fetch_url",
                      description: "Ruft eine Webseite ab und gibt den Text zurück (bis 20.000 Zeichen).",
                      parameters: schema(["url": "http(s)-Adresse"], required: ["url"]),
                      needsApproval: false, source: "Eingebaut") { args in
                guard let url = URL(string: try string(args, "url")), ["http", "https"].contains(url.scheme ?? "") else {
                    throw ToolError.invalid("Ungültige URL")
                }
                let (data, _) = try await URLSession.shared.data(from: url)
                let text = HTMLText.strip(String(decoding: data, as: UTF8.self))
                return text.count > 20_000 ? String(text.prefix(20_000)) + "\n… (gekürzt)" : text
            },
        ]
    }

    static func schema(_ props: [String: String], required: [String]) -> [String: Any] {
        ["type": "object",
         "properties": props.mapValues { ["type": "string", "description": $0] },
         "required": required]
    }

    static func resolve(_ path: String, in workspace: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded)
            : workspace.appendingPathComponent(expanded).standardizedFileURL
    }

    private static func string(_ args: [String: Any], _ key: String) throws -> String {
        guard let v = args[key] as? String else { throw ToolError.invalid("Argument '\(key)' fehlt") }
        return v
    }
}

enum ToolError: LocalizedError {
    case invalid(String)
    case denied
    var errorDescription: String? {
        switch self {
        case let .invalid(m): return m
        case .denied: return "Vom Nutzer abgelehnt"
        }
    }
}

enum Shell {
    static func run(_ command: String, cwd: URL, timeout: TimeInterval = 120) async throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", command]
        p.currentDirectoryURL = cwd
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let killer = Task {
            try await Task.sleep(for: .seconds(timeout))
            if p.isRunning { p.terminate() }
        }
        let data = await Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }.value
        p.waitUntilExit()
        killer.cancel()
        var out = String(decoding: data, as: UTF8.self)
        if out.count > 12_000 { out = String(out.prefix(12_000)) + "\n… (gekürzt)" }
        return "Exit-Code \(p.terminationStatus)\n\(out)"
    }
}

enum HTMLText {
    static func strip(_ html: String) -> String {
        var s = html
        for pattern in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<[^>]+>"] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        for (entity, char) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
