import Foundation
import PDFKit

/// Ein Werkzeug, das das Modell aufrufen kann – eingebaut, aus einem Skill/Plugin oder von einem MCP-Server.
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

/// Parameter für JSON-Schemas: (Name, Typ, Beschreibung).
typealias Param = (name: String, type: String, description: String)

func schema(_ params: [Param], required: [String]) -> [String: Any] {
    var props: [String: Any] = [:]
    for p in params { props[p.name] = ["type": p.type, "description": p.description] }
    return ["type": "object", "properties": props, "required": required]
}

enum BuiltinTools {
    /// Namen der Werkzeuge, die nichts verändern – Sub-Agenten bekommen nur diese.
    static let readOnly: Set<String> = ["list_directory", "read_file", "find_files", "search_files", "web_search", "fetch_url", "use_skill"]

    static func all(workspace: @escaping () -> URL) -> [AgentTool] {
        files(workspace) + web()
    }

    // MARK: Dateien & Shell

    static func files(_ workspace: @escaping () -> URL) -> [AgentTool] {
        [
            AgentTool(name: "list_directory",
                      description: "Listet Dateien und Ordner eines Verzeichnisses. Pfade relativ zum Arbeitsordner.",
                      parameters: schema([("path", "string", "Verzeichnis, Standard: Arbeitsordner")], required: []),
                      needsApproval: false, source: "Eingebaut") { args in
                let url = resolve(args["path"] as? String ?? ".", in: workspace())
                let items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])
                return items.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(400).map { u in
                    let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    return v?.isDirectory == true ? "\(u.lastPathComponent)/" : "\(u.lastPathComponent)  (\(v?.fileSize ?? 0) B)"
                }.joined(separator: "\n")
            },
            AgentTool(name: "read_file",
                      description: "Liest eine Textdatei mit Zeilennummern, optional nur einen Zeilenbereich. PDFs werden als Text gelesen.",
                      parameters: schema([("path", "string", "Dateipfad"),
                                          ("start_line", "integer", "Erste Zeile (ab 1)"),
                                          ("end_line", "integer", "Letzte Zeile")], required: ["path"]),
                      needsApproval: false, source: "Eingebaut") { args in
                let url = resolve(try string(args, "path"), in: workspace())
                let text: String
                if url.pathExtension.lowercased() == "pdf" {
                    guard let doc = PDFDocument(url: url) else { throw ToolError.invalid("PDF nicht lesbar") }
                    text = doc.string ?? ""
                } else {
                    text = try String(contentsOf: url, encoding: .utf8)
                }
                let lines = text.components(separatedBy: "\n")
                let start = max(int(args["start_line"]) ?? 1, 1)
                let end = min(int(args["end_line"]) ?? lines.count, lines.count)
                guard start <= end else { return "(leer)" }
                var out = ""
                for i in (start - 1)..<end {
                    out += "\(i + 1)\t\(lines[i])\n"
                    if out.count > 60_000 { return out + "… (gekürzt, nutze start_line/end_line)" }
                }
                return out
            },
            AgentTool(name: "find_files",
                      description: "Findet Dateien per Muster, z. B. '*.swift' oder 'README*' (rekursiv, ohne .git und node_modules).",
                      parameters: schema([("pattern", "string", "Glob-Muster für den Dateinamen"),
                                          ("path", "string", "Startordner, Standard: Arbeitsordner")], required: ["pattern"]),
                      needsApproval: false, source: "Eingebaut") { args in
                let root = resolve(args["path"] as? String ?? ".", in: workspace())
                let pattern = try string(args, "pattern")
                var hits: [String] = []
                let skip: Set<String> = [".git", "node_modules", ".build", "build", "DerivedData", ".venv"]
                let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
                while let u = e?.nextObject() as? URL {
                    if skip.contains(u.lastPathComponent) { e?.skipDescendants(); continue }
                    if fnmatch(pattern, u.lastPathComponent, 0) == 0 {
                        hits.append(String(u.path.dropFirst(root.path.count + 1)))
                        if hits.count >= 300 { break }
                    }
                }
                return hits.isEmpty ? "Keine Treffer" : hits.joined(separator: "\n")
            },
            AgentTool(name: "search_files",
                      description: "Durchsucht Dateiinhalte nach einem regulären Ausdruck (grep), mit Dateiname und Zeilennummer.",
                      parameters: schema([("pattern", "string", "Regulärer Ausdruck"),
                                          ("path", "string", "Ordner oder Datei, Standard: Arbeitsordner"),
                                          ("include", "string", "Nur Dateien mit diesem Muster, z. B. '*.py'")], required: ["pattern"]),
                      needsApproval: false, source: "Eingebaut") { args in
                let root = resolve(args["path"] as? String ?? ".", in: workspace())
                var cmd = ["grep", "-rnIE", "--exclude-dir=.git", "--exclude-dir=node_modules", "--exclude-dir=build", "-m", "20"]
                if let inc = args["include"] as? String { cmd.append("--include=\(inc)") }
                cmd += ["--", try string(args, "pattern"), root.path]
                let out = try await Shell.exec(cmd, cwd: root)
                return out.isEmpty ? "Keine Treffer" : out.replacingOccurrences(of: root.path + "/", with: "")
            },
            AgentTool(name: "write_file",
                      description: "Schreibt eine Textdatei vollständig neu (legt Ordner an, überschreibt vorhandene Dateien).",
                      parameters: schema([("path", "string", "Dateipfad"), ("content", "string", "Vollständiger neuer Inhalt")],
                                         required: ["path", "content"]),
                      needsApproval: true, source: "Eingebaut") { args in
                let url = resolve(try string(args, "path"), in: workspace())
                let content = try string(args, "content")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: url, atomically: true, encoding: .utf8)
                return "Geschrieben: \(url.path) (\(content.utf8.count) Bytes)"
            },
            AgentTool(name: "edit_file",
                      description: "Ersetzt in einer Datei genau eine Textstelle. old_string muss exakt und eindeutig vorkommen.",
                      parameters: schema([("path", "string", "Dateipfad"), ("old_string", "string", "Exakter bisheriger Text"),
                                          ("new_string", "string", "Neuer Text")], required: ["path", "old_string", "new_string"]),
                      needsApproval: true, source: "Eingebaut") { args in
                let url = resolve(try string(args, "path"), in: workspace())
                let old = try string(args, "old_string"), new = try string(args, "new_string")
                let text = try String(contentsOf: url, encoding: .utf8)
                let count = text.components(separatedBy: old).count - 1
                guard count == 1 else {
                    throw ToolError.invalid(count == 0 ? "old_string nicht gefunden" : "old_string kommt \(count)-mal vor – mehr Kontext angeben")
                }
                try text.replacingOccurrences(of: old, with: new).write(to: url, atomically: true, encoding: .utf8)
                return "Geändert: \(url.path)"
            },
            AgentTool(name: "run_shell",
                      description: "Führt einen Shell-Befehl (zsh) im Arbeitsordner aus. Timeout 120 s.",
                      parameters: schema([("command", "string", "Befehl")], required: ["command"]),
                      needsApproval: true, source: "Eingebaut") { args in
                try await Shell.run(try string(args, "command"), cwd: workspace())
            },
        ]
    }

    // MARK: Web

    static func web() -> [AgentTool] {
        [
            AgentTool(name: "web_search",
                      description: "Sucht im Web und liefert Titel, URL und Ausschnitt der besten Treffer. Danach mit fetch_url die Seiten lesen.",
                      parameters: schema([("query", "string", "Suchanfrage"), ("max_results", "integer", "Anzahl, Standard 8")],
                                         required: ["query"]),
                      needsApproval: false, source: "Web") { args in
                let results = try await WebSearch.search(try string(args, "query"), max: int(args["max_results"]) ?? 8)
                guard !results.isEmpty else { return "Keine Treffer" }
                return results.enumerated().map { i, r in "\(i + 1). \(r.title)\n   \(r.url)\n   \(r.snippet)" }
                    .joined(separator: "\n\n")
            },
            AgentTool(name: "fetch_url",
                      description: "Ruft eine Webseite (oder PDF/JSON/Text) ab und gibt den lesbaren Inhalt als Markdown zurück, inkl. Titel.",
                      parameters: schema([("url", "string", "http(s)-Adresse"), ("max_chars", "integer", "Standard 20000"),
                                          ("include_links", "boolean", "Links der Seite mit ausgeben")], required: ["url"]),
                      needsApproval: false, source: "Web") { args in
                try await WebFetch.fetch(try string(args, "url"), maxChars: int(args["max_chars"]) ?? 20_000,
                                         links: args["include_links"] as? Bool ?? false)
            },
        ]
    }

    static func resolve(_ path: String, in workspace: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded)
            : workspace.appendingPathComponent(expanded).standardizedFileURL
    }

    static func string(_ args: [String: Any], _ key: String) throws -> String {
        guard let v = args[key] as? String else { throw ToolError.invalid("Argument '\(key)' fehlt") }
        return v
    }

    static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let s = v as? String { return Int(s) }
        if let d = v as? Double { return Int(d) }
        return nil
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
    /// Befehl über die Login-Shell (PATH des Nutzers).
    static func run(_ command: String, cwd: URL, timeout: TimeInterval = 120) async throws -> String {
        let out = try await exec(["/bin/zsh", "-l", "-c", command], cwd: cwd, timeout: timeout, withStatus: true)
        return out
    }

    /// Programm direkt ausführen (ohne Shell-Interpretation der Argumente).
    static func exec(_ argv: [String], cwd: URL, timeout: TimeInterval = 60, withStatus: Bool = false) async throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0].hasPrefix("/") ? argv[0] : "/usr/bin/env")
        p.arguments = argv[0].hasPrefix("/") ? Array(argv.dropFirst()) : argv
        p.currentDirectoryURL = cwd
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let killer = Task {
            try await Task.sleep(for: .seconds(timeout))
            if p.isRunning { p.terminate() }
        }
        let (data, _) = try await p.runAndRead(pipe)
        killer.cancel()
        var out = String(decoding: data, as: UTF8.self)
        if out.count > 12_000 { out = String(out.prefix(12_000)) + "\n… (gekürzt)" }
        return withStatus ? "Exit-Code \(p.terminationStatus)\n\(out)" : out
    }
}

extension Process {
    /// Startet den Prozess, liest die Ausgabe und wartet auf das Ende.
    /// Bewusst ohne `waitUntilExit()`: das braucht eine RunLoop und kann in Concurrency-Threads hängen bleiben.
    func runAndRead(_ out: Pipe, errors: Pipe? = nil) async throws -> (Data, Data) {
        let exited = AsyncStream<Void> { cont in
            terminationHandler = { _ in cont.yield(); cont.finish() }
        }
        try run()
        async let o = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        async let e = Task.detached { errors?.fileHandleForReading.readDataToEndOfFile() ?? Data() }.value
        let result = await (o, e)
        for await _ in exited {}
        return result
    }

    /// Synchrone Variante für Stellen außerhalb von async-Kontexten.
    func runAndReadBlocking(_ out: Pipe) throws -> Data {
        let done = DispatchSemaphore(value: 0)
        terminationHandler = { _ in done.signal() }
        try run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        done.wait()
        return data
    }
}
