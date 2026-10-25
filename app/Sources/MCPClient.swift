import Foundation
import Observation

/// Ein MCP-Server, wie er auch in Claude Desktop / Claude Code konfiguriert wird.
/// `type` ist "stdio" (Befehl starten) oder "http" (Streamable HTTP unter `url`).
struct MCPServerConfig: Codable, Hashable, Identifiable {
    var name: String
    var type = "stdio"
    var command = ""
    var args: [String] = []
    var env: [String: String] = [:]
    var url = ""
    var headers: [String: String] = [:]
    var enabled = true
    /// Gesetzt, wenn der Server aus einem Plugin stammt (wird nicht in mcp.json gespeichert).
    var plugin: String?
    var id: String { name }

    var summary: String { type == "http" ? url : ([command] + args).joined(separator: " ") }

    init(name: String, type: String = "stdio", command: String = "", args: [String] = [], env: [String: String] = [:],
         url: String = "", headers: [String: String] = [:], enabled: Bool = true, plugin: String? = nil) {
        self.name = name; self.type = type; self.command = command; self.args = args; self.env = env
        self.url = url; self.headers = headers; self.enabled = enabled; self.plugin = plugin
    }

    /// Liest ein `mcpServers`-Objekt (Claude-Desktop-Format) bzw. eine `.mcp.json` aus einem Plugin.
    static func parse(_ entries: [String: [String: Any]], pluginRoot: URL? = nil, plugin: String? = nil) -> [MCPServerConfig] {
        entries.sorted { $0.key < $1.key }.compactMap { name, e in
            let sub = { (s: String) in pluginRoot.map { s.replacingOccurrences(of: "${CLAUDE_PLUGIN_ROOT}", with: $0.path) } ?? s }
            let url = e["url"] as? String ?? ""
            let type = (e["type"] as? String).map { $0 == "sse" || $0 == "streamable-http" ? "http" : $0 }
                ?? (url.isEmpty ? "stdio" : "http")
            let command = sub(e["command"] as? String ?? "")
            guard type == "http" ? !url.isEmpty : !command.isEmpty else { return nil }
            return MCPServerConfig(name: name, type: type, command: command,
                                   args: (e["args"] as? [String] ?? []).map(sub),
                                   env: (e["env"] as? [String: String] ?? [:]).mapValues(sub),
                                   url: url, headers: e["headers"] as? [String: String] ?? [:],
                                   enabled: e["disabled"] as? Bool != true, plugin: plugin)
        }
    }

    static func load(file: URL, pluginRoot: URL) -> [MCPServerConfig] {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let entries = (json["mcpServers"] as? [String: [String: Any]]) ?? (json as? [String: [String: Any]]) ?? [:]
        return parse(entries, pluginRoot: pluginRoot, plugin: pluginRoot.lastPathComponent)
    }
}

struct MCPTool {
    let name: String
    let description: String
    let inputSchema: [String: Any]
}

protocol MCPConnection: AnyObject, Sendable {
    func start() async throws
    func listTools() async throws -> [MCPTool]
    func callTool(_ name: String, arguments: [String: Any]) async throws -> String
    func stop()
}

/// Umgebung der Login-Shell des Nutzers (PATH, Tokens aus ~/.zshrc …), einmal ermittelt.
enum UserEnvironment {
    nonisolated(unsafe) private static var cached: [String: String]?
    private static let lock = NSLock()

    static var values: [String: String] {
        lock.withLock {
            if let cached { return cached }
            var env = ProcessInfo.processInfo.environment
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-l", "-i", "-c", "env -0"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            // Eine hängende ~/.zshrc darf die App nicht blockieren.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
            if let data = try? p.runAndReadBlocking(pipe) {
                for entry in data.split(separator: 0) {
                    let s = String(decoding: entry, as: UTF8.self)
                    if let eq = s.firstIndex(of: "=") { env[String(s[..<eq])] = String(s[s.index(after: eq)...]) }
                }
            }
            cached = env
            return env
        }
    }

    /// Ersetzt ${VAR} und ${VAR:-standard}.
    static func expand(_ s: String, extra: [String: String] = [:]) -> String {
        guard s.contains("${") else { return s }
        let env = values.merging(extra) { $1 }
        let regex = try! NSRegularExpression(pattern: "\\$\\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\\}")
        var out = s
        for m in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(m.range, in: s), let k = Range(m.range(at: 1), in: s) else { continue }
            let fallback = Range(m.range(at: 3), in: s).map { String(s[$0]) } ?? ""
            out.replaceSubrange(r, with: env[String(s[k])] ?? fallback)
        }
        return out
    }
}

/// Gemeinsame JSON-RPC-Logik (ids, wartende Antworten, Zeitlimits).
class MCPRPCBase: @unchecked Sendable {
    let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    func reserveID() -> Int { lock.withLock { defer { nextID += 1 }; return nextID } }

    func awaitResponse(id: Int, method: String, timeout: TimeInterval, send: @escaping () -> Void) async throws -> [String: Any] {
        let timer = Task { [weak self] in
            try await Task.sleep(for: .seconds(timeout))
            self?.resolve(id, with: .failure(MCPError.timeout(method)))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { c in
            lock.withLock { pending[id] = c }
            send()
        }
    }

    func handleMessage(_ msg: [String: Any]) {
        guard let id = msg["id"] as? Int, msg["method"] == nil else { return }
        if let err = msg["error"] as? [String: Any] {
            resolve(id, with: .failure(MCPError.rpc(err["message"] as? String ?? "Fehler")))
        } else {
            resolve(id, with: .success(msg["result"] as? [String: Any] ?? [:]))
        }
    }

    func resolve(_ id: Int, with result: Result<[String: Any], Error>) {
        let c = lock.withLock { pending.removeValue(forKey: id) }
        c?.resume(with: result)
    }

    func failAll(_ error: Error) {
        let all = lock.withLock { () -> [CheckedContinuation<[String: Any], Error>] in
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        all.forEach { $0.resume(throwing: error) }
    }

    static let initializeParams: [String: Any] = [
        "protocolVersion": "2025-06-18",
        "capabilities": [:],
        "clientInfo": ["name": "Local AI", "version": "0.2.0"],
    ]

    static func parseTools(_ result: [String: Any]) -> [MCPTool] {
        (result["tools"] as? [[String: Any]] ?? []).compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            return MCPTool(name: name, description: t["description"] as? String ?? "",
                           inputSchema: t["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [:]])
        }
    }

    static func toolText(_ result: [String: Any]) throws -> String {
        let parts = (result["content"] as? [[String: Any]] ?? []).map { c -> String in
            if let text = c["text"] as? String { return text }
            if let res = c["resource"] as? [String: Any], let text = res["text"] as? String { return text }
            return "[\(c["type"] as? String ?? "Inhalt")]"
        }
        let text = parts.joined(separator: "\n")
        if result["isError"] as? Bool == true { throw MCPError.tool(text) }
        return text
    }
}

/// MCP über stdio: JSON-RPC 2.0, eine Nachricht pro Zeile.
final class MCPStdioClient: MCPRPCBase, MCPConnection, @unchecked Sendable {
    let config: MCPServerConfig
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private var buffer = Data()
    private var stderrTail = ""
    var onStderr: (@Sendable (String) -> Void)?

    init(config: MCPServerConfig) { self.config = config }

    func start() async throws {
        // Über eine Login-Shell starten, damit npx/uvx/node aus dem PATH des Nutzers gefunden werden.
        let extra = config.env.mapValues { UserEnvironment.expand($0) }
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "exec \"$0\" \"$@\"", UserEnvironment.expand(config.command, extra: extra)]
            + config.args.map { UserEnvironment.expand($0, extra: extra) }
        process.environment = UserEnvironment.values.merging(extra) { $1 }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in self?.receive(h.availableData) }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty else { return }
            let text = String(decoding: d, as: UTF8.self)
            self.lock.withLock { self.stderrTail = String((self.stderrTail + text).suffix(400)) }
            self.onStderr?(text)
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            let tail = self.lock.withLock { self.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines) }
            self.failAll(MCPError.exited(tail))
        }
        try process.run()
        _ = try await request("initialize", params: Self.initializeParams, timeout: 120)
        send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    func listTools() async throws -> [MCPTool] { Self.parseTools(try await request("tools/list", params: [:])) }

    func callTool(_ name: String, arguments: [String: Any]) async throws -> String {
        try Self.toolText(try await request("tools/call", params: ["name": name, "arguments": arguments], timeout: 300))
    }

    func stop() { if process.isRunning { process.terminate() } }

    private func request(_ method: String, params: [String: Any], timeout: TimeInterval = 30) async throws -> [String: Any] {
        let id = reserveID()
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        return try await awaitResponse(id: id, method: method, timeout: timeout) { [weak self] in self?.send(msg) }
    }

    private func send(_ msg: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        data.append(0x0A)
        try? stdin.fileHandleForWriting.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines: [Data] = lock.withLock {
            buffer.append(data)
            var out: [Data] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                out.append(buffer[buffer.startIndex..<nl])
                buffer.removeSubrange(buffer.startIndex...nl)
            }
            return out
        }
        for line in lines {
            if let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { handleMessage(msg) }
        }
    }
}

/// MCP über Streamable HTTP: POST pro Nachricht, Antwort als JSON oder Server-Sent Events.
final class MCPHTTPClient: MCPRPCBase, MCPConnection, @unchecked Sendable {
    let config: MCPServerConfig
    private var sessionID: String?
    private var protocolVersion: String?

    init(config: MCPServerConfig) { self.config = config }

    func start() async throws {
        let result = try await request("initialize", params: Self.initializeParams)
        protocolVersion = result["protocolVersion"] as? String
        try await post(["jsonrpc": "2.0", "method": "notifications/initialized"], expectResponse: false)
    }

    func listTools() async throws -> [MCPTool] { Self.parseTools(try await request("tools/list", params: [:])) }

    func callTool(_ name: String, arguments: [String: Any]) async throws -> String {
        try Self.toolText(try await request("tools/call", params: ["name": name, "arguments": arguments]))
    }

    func stop() {}

    private func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = reserveID()
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        guard let response = try await post(msg, expectResponse: true) else { throw MCPError.rpc("Keine Antwort auf \(method)") }
        if let err = response["error"] as? [String: Any] { throw MCPError.rpc(err["message"] as? String ?? "Fehler") }
        return response["result"] as? [String: Any] ?? [:]
    }

    @discardableResult
    private func post(_ msg: [String: Any], expectResponse: Bool) async throws -> [String: Any]? {
        guard let url = URL(string: UserEnvironment.expand(config.url)) else { throw MCPError.rpc("Ungültige URL") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID { req.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let protocolVersion { req.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        let extra = config.env.mapValues { UserEnvironment.expand($0) }
        for (k, v) in config.headers { req.setValue(UserEnvironment.expand(v, extra: extra), forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: msg)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else { throw MCPError.rpc("Keine HTTP-Antwort") }
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = sid }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw MCPError.rpc("Anmeldung nötig (HTTP \(http.statusCode)) – Token unter Umgebung/Headers eintragen")
            }
            throw MCPError.rpc("HTTP \(http.statusCode)")
        }
        guard expectResponse else { return nil }
        let wantedID = msg["id"] as? Int
        if (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream") {
            for try await line in bytes.lines where line.hasPrefix("data:") {
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                   obj["id"] as? Int == wantedID { return obj }
            }
            return nil
        }
        var data = Data()
        for try await b in bytes { data.append(b) }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

enum MCPError: LocalizedError {
    case exited(String), timeout(String), rpc(String), tool(String)
    var errorDescription: String? {
        switch self {
        case let .exited(tail): return tail.isEmpty ? "MCP-Server wurde beendet" : "MCP-Server wurde beendet: \(tail)"
        case let .timeout(m): return "Zeitüberschreitung bei \(m)"
        case let .rpc(m): return m
        case let .tool(m): return m
        }
    }
}

/// Verwaltet die MCP-Server (eigene + aus Plugins) und stellt ihre Werkzeuge dem Agenten bereit.
@MainActor @Observable
final class MCPManager {
    enum Status: Equatable { case off, connecting, connected(Int), failed(String) }

    static let configURL = Paths.base.appendingPathComponent("mcp.json")
    static let claudeDesktopConfig = Paths.home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")

    private(set) var servers: [MCPServerConfig] = []
    private(set) var pluginServers: [MCPServerConfig] = []
    private(set) var status: [String: Status] = [:]
    private(set) var tools: [AgentTool] = []
    private(set) var log: [String] = []
    private var clients: [String: MCPConnection] = [:]

    init() { load() }

    var allServers: [MCPServerConfig] { servers + pluginServers }

    func connectAll() async {
        for s in allServers where s.enabled && clients[s.name] == nil { await connect(s) }
    }

    /// Plugin-Server übernehmen: neue verbinden, entfernte trennen.
    func setPluginServers(_ list: [MCPServerConfig]) async {
        let gone = Set(pluginServers.map(\.name)).subtracting(list.map(\.name))
        gone.forEach { disconnect($0); status[$0] = nil }
        pluginServers = list
        for s in list where clients[s.name] == nil { await connect(s) }
    }

    func connect(_ server: MCPServerConfig) async {
        disconnect(server.name)
        status[server.name] = .connecting
        let client: MCPConnection
        if server.type == "http" {
            client = MCPHTTPClient(config: server)
        } else {
            let stdio = MCPStdioClient(config: server)
            stdio.onStderr = { [weak self] text in
                Task { @MainActor in self?.appendLog("[\(server.name)] \(text)") }
            }
            client = stdio
        }
        do {
            try await client.start()
            let list = try await client.listTools()
            clients[server.name] = client
            status[server.name] = .connected(list.count)
            tools.removeAll { $0.source == server.name }
            tools += list.map { t in
                AgentTool(name: Self.toolName(server.name, t.name), description: t.description,
                          parameters: t.inputSchema, needsApproval: true, source: server.name) { args in
                    try await client.callTool(t.name, arguments: args)
                }
            }
            appendLog("[\(server.name)] verbunden, \(list.count) Werkzeuge")
        } catch {
            client.stop()
            status[server.name] = .failed(error.localizedDescription)
            appendLog("[\(server.name)] Fehler: \(error.localizedDescription)")
        }
    }

    func disconnect(_ name: String) {
        clients.removeValue(forKey: name)?.stop()
        tools.removeAll { $0.source == name }
        status[name] = .off
    }

    func disconnectAll() { allServers.forEach { disconnect($0.name) } }

    func add(_ server: MCPServerConfig) {
        servers.removeAll { $0.name == server.name }
        servers.append(server)
        save()
    }

    func remove(_ name: String) {
        disconnect(name)
        servers.removeAll { $0.name == name }
        status[name] = nil
        save()
    }

    func setEnabled(_ name: String, _ enabled: Bool) {
        guard let i = servers.firstIndex(where: { $0.name == name }) else { return }
        servers[i].enabled = enabled
        save()
        if enabled { Task { await connect(servers[i]) } } else { disconnect(name) }
    }

    /// Übernimmt die Server aus der Claude-Desktop-Konfiguration. Gibt die Anzahl neuer Server zurück.
    func importClaudeDesktop() -> Int {
        guard let data = try? Data(contentsOf: Self.claudeDesktopConfig),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["mcpServers"] as? [String: [String: Any]] else { return 0 }
        let new = MCPServerConfig.parse(entries).filter { s in !servers.contains { $0.name == s.name } }
        servers += new
        save()
        return new.count
    }

    /// Werkzeugnamen müssen für die API eindeutig und schlicht sein.
    static func toolName(_ server: String, _ tool: String) -> String {
        let clean = { (s: String) in s.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression) }
        return String("\(clean(server))__\(clean(tool))".prefix(64))
    }

    private func appendLog(_ text: String) {
        log.append(contentsOf: text.split(separator: "\n").map(String.init))
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["mcpServers"] as? [String: [String: Any]] else { return }
        servers = MCPServerConfig.parse(entries)
    }

    /// Gleiches Format wie Claude Desktop, damit sich die Datei austauschen lässt.
    private func save() {
        var entries: [String: Any] = [:]
        for s in servers {
            var e: [String: Any] = s.type == "http" ? ["type": "http", "url": s.url] : ["command": s.command, "args": s.args]
            if !s.env.isEmpty { e["env"] = s.env }
            if !s.headers.isEmpty { e["headers"] = s.headers }
            if !s.enabled { e["disabled"] = true }
            entries[s.name] = e
        }
        try? FileManager.default.createDirectory(at: Paths.base, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": entries], options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Self.configURL, options: .atomic)
        }
    }
}
