import Foundation

/// Liest Markdown mit YAML-Frontmatter, wie es Claude Code für Skills, Befehle und Agenten nutzt.
/// Unterstützt flache `key: value`-Paare und eingerückte Fortsetzungszeilen – genug für diese Dateien.
struct Frontmatter {
    var fields: [String: String] = [:]
    var body: String

    init(text: String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            body = text
            return
        }
        var key: String?
        for line in lines[1..<end] {
            if let k = key, line.hasPrefix(" ") || line.hasPrefix("\t") {
                let more = line.trimmingCharacters(in: .whitespaces)
                fields[k] = [fields[k] ?? "", more].filter { !$0.isEmpty && $0 != ">" && $0 != "|" }.joined(separator: " ")
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces)
            var v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, let f = v.first, f == v.last, f == "\"" || f == "'" { v = String(v.dropFirst().dropLast()) }
            fields[k] = v
            key = k
        }
        body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init?(url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        self.init(text: text)
    }

    subscript(_ key: String) -> String? { fields[key].flatMap { $0.isEmpty ? nil : $0 } }
}

/// Ein Skill: Ordner mit SKILL.md. Der Inhalt wird erst geladen, wenn das Modell ihn braucht.
struct Skill: Identifiable, Hashable {
    let name: String
    let description: String
    let dir: URL
    /// "KI/lokal", "Claude Code" oder der Plugin-Name.
    let source: String
    var id: String { "\(source)/\(name)" }
    var file: URL { dir.appendingPathComponent("SKILL.md") }

    static func load(in root: URL, source: String) -> [Skill] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir in
            let file = dir.appendingPathComponent("SKILL.md")
            guard let fm = Frontmatter(url: file) else { return nil }
            return Skill(name: fm["name"] ?? dir.lastPathComponent, description: fm["description"] ?? "",
                         dir: dir, source: source)
        }
        .sorted { $0.name < $1.name }
    }
}

/// Ein Slash-Befehl: Markdown-Vorlage, `$ARGUMENTS` wird durch die Eingabe ersetzt.
struct SlashCommand: Identifiable, Hashable {
    let name: String
    let description: String
    let argumentHint: String
    let body: String
    let source: String
    var id: String { "\(source)/\(name)" }

    func expand(_ arguments: String) -> String {
        var text = body
        if text.contains("$ARGUMENTS") {
            text = text.replacingOccurrences(of: "$ARGUMENTS", with: arguments)
        } else if !arguments.isEmpty {
            text += "\n\nArgumente: \(arguments)"
        }
        let parts = arguments.split(separator: " ").map(String.init)
        for (i, p) in parts.enumerated() { text = text.replacingOccurrences(of: "$\(i + 1)", with: p) }
        return text
    }

    static func load(in root: URL, source: String) -> [SlashCommand] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "md" }.compactMap { url in
            guard let fm = Frontmatter(url: url) else { return nil }
            return SlashCommand(name: url.deletingPathExtension().lastPathComponent,
                                description: fm["description"] ?? String(fm.body.prefix(80)),
                                argumentHint: fm["argument-hint"] ?? "", body: fm.body, source: source)
        }
        .sorted { $0.name < $1.name }
    }
}

/// Ein Sub-Agent (agents/*.md): eigener Systemprompt, wird über das Werkzeug run_agent aufgerufen.
struct SubAgentDef: Identifiable, Hashable {
    let name: String
    let description: String
    let prompt: String
    let source: String
    var id: String { "\(source)/\(name)" }

    static func load(in root: URL, source: String) -> [SubAgentDef] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "md" }.compactMap { url in
            guard let fm = Frontmatter(url: url) else { return nil }
            return SubAgentDef(name: fm["name"] ?? url.deletingPathExtension().lastPathComponent,
                               description: fm["description"] ?? "", prompt: fm.body, source: source)
        }
        .sorted { $0.name < $1.name }
    }
}
