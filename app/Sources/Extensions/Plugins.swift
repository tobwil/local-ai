import Foundation
import Observation

/// Ein installiertes Plugin im Claude-Code-Format:
/// `.claude-plugin/plugin.json`, `skills/*/SKILL.md`, `commands/*.md`, `agents/*.md`, `.mcp.json`.
struct Plugin: Identifiable {
    let name: String
    let description: String
    let version: String
    let dir: URL
    var enabled: Bool
    let skills: [Skill]
    let commands: [SlashCommand]
    let agents: [SubAgentDef]
    let mcpServers: [MCPServerConfig]
    var id: String { name }

    static func load(_ dir: URL, enabled: Bool) -> Plugin? {
        let manifest = dir.appendingPathComponent(".claude-plugin/plugin.json")
        let json = (try? Data(contentsOf: manifest)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let hasContent = ["skills", "commands", "agents", ".mcp.json"].contains {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
        guard json != nil || hasContent else { return nil }
        let name = json?["name"] as? String ?? dir.lastPathComponent
        return Plugin(name: name,
                      description: json?["description"] as? String ?? "",
                      version: json?["version"] as? String ?? "",
                      dir: dir, enabled: enabled,
                      skills: Skill.load(in: dir.appendingPathComponent("skills"), source: name),
                      commands: SlashCommand.load(in: dir.appendingPathComponent("commands"), source: name),
                      agents: SubAgentDef.load(in: dir.appendingPathComponent("agents"), source: name),
                      mcpServers: MCPServerConfig.load(file: dir.appendingPathComponent(".mcp.json"), pluginRoot: dir)
                        .map { var s = $0; s.name = "\(name):\(s.name)"; return s })
    }
}

/// Eintrag aus einer marketplace.json.
struct CatalogEntry: Identifiable, Hashable {
    enum Source: Hashable {
        case local(URL)
        case git(url: String, ref: String?, subdir: String?)
    }
    let name: String
    let description: String
    let category: String
    let author: String
    let marketplace: String
    let source: Source
    var id: String { "\(marketplace)/\(name)" }
}

struct Marketplace: Identifiable, Hashable {
    let name: String
    let dir: URL
    var id: String { dir.path }
}

@MainActor @Observable
final class PluginManager {
    static let pluginsDir = Paths.base.appendingPathComponent("plugins")
    static let marketplacesDir = Paths.base.appendingPathComponent("marketplaces")
    static let stateFile = Paths.base.appendingPathComponent("plugins.json")
    static let skillsDir = Paths.base.appendingPathComponent("skills")
    static let claudeSkillsDir = Paths.home.appendingPathComponent(".claude/skills")
    static let claudeCommandsDir = Paths.home.appendingPathComponent(".claude/commands")
    static let claudeMarketplaces = Paths.home.appendingPathComponent(".claude/plugins/marketplaces")
    static let officialMarketplace = "https://github.com/anthropics/claude-plugins-official.git"

    private(set) var plugins: [Plugin] = []
    private(set) var ownSkills: [Skill] = []
    private(set) var claudeSkills: [Skill] = []
    private(set) var claudeCommands: [SlashCommand] = []
    private(set) var marketplaces: [Marketplace] = []
    private(set) var catalog: [CatalogEntry] = []
    private(set) var busy: [String: String] = [:]
    private(set) var errors: [String: String] = [:]
    var includeClaudeCode: Bool {
        didSet { UserDefaults.standard.set(includeClaudeCode, forKey: "includeClaudeCode") }
    }
    private var disabled: Set<String> = []

    init() {
        includeClaudeCode = UserDefaults.standard.object(forKey: "includeClaudeCode") as? Bool ?? true
        reload()
    }

    // MARK: Was der Agent sieht

    var activePlugins: [Plugin] { plugins.filter(\.enabled) }

    var skills: [Skill] {
        ownSkills + activePlugins.flatMap(\.skills) + (includeClaudeCode ? claudeSkills : [])
    }

    var commands: [SlashCommand] {
        activePlugins.flatMap(\.commands) + (includeClaudeCode ? claudeCommands : [])
    }

    var agents: [SubAgentDef] { activePlugins.flatMap(\.agents) }
    var mcpServers: [MCPServerConfig] { activePlugins.flatMap(\.mcpServers) }

    func isInstalled(_ entry: CatalogEntry) -> Bool { plugins.contains { $0.name == entry.name } }

    // MARK: Laden

    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.pluginsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Self.skillsDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: Self.stateFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            disabled = Set(json["disabled"] as? [String] ?? [])
        }
        let dirs = (try? fm.contentsOfDirectory(at: Self.pluginsDir, includingPropertiesForKeys: nil)) ?? []
        plugins = dirs.compactMap { Plugin.load($0, enabled: !disabled.contains($0.lastPathComponent)) }
            .sorted { $0.name < $1.name }
        ownSkills = Skill.load(in: Self.skillsDir, source: "KI/lokal")
        claudeSkills = Skill.load(in: Self.claudeSkillsDir, source: "Claude Code")
        claudeCommands = SlashCommand.load(in: Self.claudeCommandsDir, source: "Claude Code")
        loadMarketplaces()
    }

    private func loadMarketplaces() {
        let fm = FileManager.default
        let roots = [Self.marketplacesDir, Self.claudeMarketplaces]
        var seen = Set<String>()
        marketplaces = roots.flatMap { root in
            ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).compactMap { dir -> Marketplace? in
                let file = dir.appendingPathComponent(".claude-plugin/marketplace.json")
                guard let data = try? Data(contentsOf: file),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                let name = json["name"] as? String ?? dir.lastPathComponent
                guard seen.insert(name).inserted else { return nil }
                return Marketplace(name: name, dir: dir)
            }
        }
        catalog = marketplaces.flatMap(entries).sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private func entries(_ m: Marketplace) -> [CatalogEntry] {
        let file = m.dir.appendingPathComponent(".claude-plugin/marketplace.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return (json["plugins"] as? [[String: Any]] ?? []).compactMap { p in
            guard let name = p["name"] as? String else { return nil }
            let source: CatalogEntry.Source
            if let rel = p["source"] as? String {
                source = .local(m.dir.appendingPathComponent(rel).standardizedFileURL)
            } else if let s = p["source"] as? [String: Any] {
                let kind = s["source"] as? String ?? ""
                let ref = s["ref"] as? String
                switch kind {
                case "github":
                    guard let repo = s["repo"] as? String else { return nil }
                    source = .git(url: "https://github.com/\(repo).git", ref: ref, subdir: s["path"] as? String)
                case "url", "git-subdir", "git":
                    guard let url = s["url"] as? String else { return nil }
                    source = .git(url: url, ref: ref, subdir: s["path"] as? String)
                default:
                    return nil
                }
            } else {
                return nil
            }
            let author = (p["author"] as? [String: Any])?["name"] as? String ?? ""
            return CatalogEntry(name: name, description: p["description"] as? String ?? "",
                                category: p["category"] as? String ?? "", author: author,
                                marketplace: m.name, source: source)
        }
    }

    // MARK: Ändern

    func setEnabled(_ name: String, _ enabled: Bool) {
        if enabled { disabled.remove(name) } else { disabled.insert(name) }
        saveState()
        if let i = plugins.firstIndex(where: { $0.name == name }) { plugins[i].enabled = enabled }
    }

    func install(_ entry: CatalogEntry) async {
        busy[entry.id] = "wird installiert …"
        errors[entry.id] = nil
        let dest = Self.pluginsDir.appendingPathComponent(entry.name)
        do {
            switch entry.source {
            case let .local(dir):
                try copyFresh(dir, to: dest)
            case let .git(url, ref, subdir):
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("localai-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: tmp) }
                var args = ["clone", "--depth", "1"]
                if let ref { args += ["--branch", ref] }
                try await Git.run(args + [url, tmp.path])
                try copyFresh(subdir.map { tmp.appendingPathComponent($0) } ?? tmp, to: dest)
                try? FileManager.default.removeItem(at: dest.appendingPathComponent(".git"))
            }
            reload()
        } catch {
            errors[entry.id] = error.localizedDescription
        }
        busy[entry.id] = nil
    }

    /// Plugin direkt aus einem Git-Repository (oder Unterordner davon) installieren.
    func install(gitURL: String) async {
        let name = URL(string: gitURL)?.deletingPathExtension().lastPathComponent ?? "plugin"
        await install(CatalogEntry(name: name, description: "", category: "", author: "", marketplace: "git",
                                   source: .git(url: gitURL, ref: nil, subdir: nil)))
    }

    func uninstall(_ plugin: Plugin) {
        try? FileManager.default.trashItem(at: plugin.dir, resultingItemURL: nil)
        reload()
    }

    func addMarketplace(_ gitURL: String) async {
        let key = "marketplace:\(gitURL)"
        busy[key] = "wird geladen …"
        errors[key] = nil
        let name = URL(string: gitURL)?.deletingPathExtension().lastPathComponent ?? "marketplace"
        let dest = Self.marketplacesDir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: Self.marketplacesDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) {
                try await Git.run(["-C", dest.path, "pull", "--ff-only"])
            } else {
                try await Git.run(["clone", "--depth", "1", gitURL, dest.path])
            }
            reload()
        } catch {
            errors[key] = error.localizedDescription
        }
        busy[key] = nil
    }

    private func copyFresh(_ src: URL, to dest: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else { throw ToolError.invalid("Quelle fehlt: \(src.path)") }
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: src, to: dest)
    }

    private func saveState() {
        let data = try? JSONSerialization.data(withJSONObject: ["disabled": disabled.sorted()], options: .prettyPrinted)
        try? data?.write(to: Self.stateFile, options: .atomic)
    }
}

enum Git {
    static func run(_ args: [String]) async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = pipe
        let (data, _) = try await p.runAndRead(pipe)
        guard p.terminationStatus == 0 else {
            throw ToolError.invalid("git \(args.first ?? ""): \(String(decoding: data, as: UTF8.self).suffix(300))")
        }
    }
}
