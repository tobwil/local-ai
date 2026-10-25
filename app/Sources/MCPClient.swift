import Foundation
import Observation

/// Ein MCP-Server, wie er auch in Claude Desktop / Claude Code konfiguriert wird.
struct MCPServerConfig: Codable, Hashable, Identifiable {
    var name: String
    var command: String
    var args: [String] = []
    var env: [String: String] = [:]
    var enabled = true
    var id: String { name }
}

/// MCP über stdio: JSON-RPC 2.0, eine Nachricht pro Zeile.
final class MCPStdioClient: @unchecked Sendable {
    struct Tool { let name: String; let description: String; let inputSchema: [String: Any] }

    let config: MCPServerConfig
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var stderrTail = ""
    var onStderr: (@Sendable (String) -> Void)?

    init(config: MCPServerConfig) { self.config = config }

    func start() async throws {
        // Über eine Login-Shell starten, damit npx/uvx/node aus dem PATH des Nutzers gefunden werden.
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "exec \"$0\" \"$@\"", config.command] + config.args
        var env = ProcessInfo.processInfo.environment
        config.env.forEach { env[$0] = $1 }
        process.environment = env
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in self?.receive(h.availableData) }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty else { return }
            let text = String(decoding: d, as: UTF8.self)
            self.lock.lock()
            self.stderrTail = String((self.stderrTail + text).suffix(400))
            self.lock.unlock()
            self.onStderr?(text)
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let tail = self.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            self.lock.unlock()
            self.failAll(MCPError.exited(tail))
        }
        try process.run()

        _ = try await request("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "Local AI", "version": "0.1.0"],
        ], timeout: 60)
        notify("notifications/initialized")
    }

    func listTools() async throws -> [Tool] {
        let result = try await request("tools/list", params: [:])
        return (result["tools"] as? [[String: Any]] ?? []).compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            return Tool(name: name, description: t["description"] as? String ?? "",
                        inputSchema: t["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [:]])
        }
    }

    func callTool(_ name: String, arguments: [String: Any]) async throws -> String {
        let result = try await request("tools/call", params: ["name": name, "arguments": arguments], timeout: 300)
        let parts = (result["content"] as? [[String: Any]] ?? []).map { c -> String in
            if let text = c["text"] as? String { return text }
            return "[\(c["type"] as? String ?? "Inhalt")]"
        }
        let text = parts.joined(separator: "\n")
        if result["isError"] as? Bool == true { throw MCPError.tool(text) }
        return text
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    // MARK: JSON-RPC

    private func request(_ method: String, params: [String: Any], timeout: TimeInterval = 30) async throws -> [String: Any] {
        let id = lock.withLock {
            defer { nextID += 1 }
            return nextID
        }
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let timer = Task { [weak self] in
            try await Task.sleep(for: .seconds(timeout))
            self?.resolve(id, with: .failure(MCPError.timeout(method)))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { c in
            lock.lock()
            pending[id] = c
            lock.unlock()
            send(msg)
        }
    }

    private func notify(_ method: String) {
        send(["jsonrpc": "2.0", "method": method])
    }

    private func send(_ msg: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        data.append(0x0A)
        try? stdin.fileHandleForWriting.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        for line in lines {
            guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = msg["id"] as? Int, msg["method"] == nil else { continue }
            if let err = msg["error"] as? [String: Any] {
                resolve(id, with: .failure(MCPError.rpc(err["message"] as? String ?? "Fehler")))
            } else {
                resolve(id, with: .success(msg["result"] as? [String: Any] ?? [:]))
            }
        }
    }

    private func resolve(_ id: Int, with result: Result<[String: Any], Error>) {
        lock.lock()
        let c = pending.removeValue(forKey: id)
        lock.unlock()
        c?.resume(with: result)
    }

    private func failAll(_ error: Error) {
        lock.lock()
        let all = pending.values
        pending.removeAll()
        lock.unlock()
        all.forEach { $0.resume(throwing: error) }
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

/// Verwaltet die konfigurierten MCP-Server und stellt ihre Werkzeuge dem Agenten bereit.
@MainActor @Observable
final class MCPManager {
    enum Status: Equatable { case off, connecting, connected(Int), failed(String) }

    static let configURL = Paths.base.appendingPathComponent("mcp.json")
    static let claudeDesktopConfig = Paths.home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")

    private(set) var servers: [MCPServerConfig] = []
    private(set) var status: [String: Status] = [:]
    private(set) var tools: [AgentTool] = []
    private(set) var log: [String] = []
    private var clients: [String: MCPStdioClient] = [:]

    init() { load() }

    func connectAll() async {
        for s in servers where s.enabled && clients[s.name] == nil { await connect(s) }
    }

    func connect(_ server: MCPServerConfig) async {
        disconnect(server.name)
        status[server.name] = .connecting
        let client = MCPStdioClient(config: server)
        client.onStderr = { [weak self] text in
            Task { @MainActor in self?.appendLog("[\(server.name)] \(text)") }
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
        } catch {
            client.stop()
            status[server.name] = .failed(error.localizedDescription)
        }
    }

    func disconnect(_ name: String) {
        clients.removeValue(forKey: name)?.stop()
        tools.removeAll { $0.source == name }
        status[name] = .off
    }

    func disconnectAll() { servers.forEach { disconnect($0.name) } }

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

    /// Übernimmt die stdio-Server aus der Claude-Desktop-Konfiguration. Gibt die Anzahl neuer Server zurück.
    func importClaudeDesktop() -> Int {
        guard let data = try? Data(contentsOf: Self.claudeDesktopConfig),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["mcpServers"] as? [String: [String: Any]] else { return 0 }
        var added = 0
        for (name, e) in entries.sorted(by: { $0.key < $1.key }) {
            guard let command = e["command"] as? String, !servers.contains(where: { $0.name == name }) else { continue }
            servers.append(MCPServerConfig(name: name, command: command,
                                           args: e["args"] as? [String] ?? [],
                                           env: e["env"] as? [String: String] ?? [:]))
            added += 1
        }
        save()
        return added
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
        servers = entries.sorted { $0.key < $1.key }.compactMap { name, e in
            guard let command = e["command"] as? String else { return nil }
            return MCPServerConfig(name: name, command: command, args: e["args"] as? [String] ?? [],
                                   env: e["env"] as? [String: String] ?? [:],
                                   enabled: e["disabled"] as? Bool != true)
        }
    }

    /// Gleiches Format wie Claude Desktop, damit sich die Datei austauschen lässt.
    private func save() {
        var entries: [String: Any] = [:]
        for s in servers {
            var e: [String: Any] = ["command": s.command, "args": s.args]
            if !s.env.isEmpty { e["env"] = s.env }
            if !s.enabled { e["disabled"] = true }
            entries[s.name] = e
        }
        try? FileManager.default.createDirectory(at: Paths.base, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": entries], options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Self.configURL, options: .atomic)
        }
    }
}
