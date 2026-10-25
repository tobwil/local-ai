import Foundation

/// `Local AI --selftest`: prüft Engine, Tool-Calls, eingebaute Werkzeuge und den MCP-Client ohne Oberfläche.
enum SelfTest {
    static func run() -> Int32 {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failures = 0
        Task.detached {
            failures = await runAll()
            sem.signal()
        }
        sem.wait()
        print(failures == 0 ? "\n✅ Alle Prüfungen bestanden" : "\n❌ \(failures) Prüfung(en) fehlgeschlagen")
        return failures == 0 ? 0 : 1
    }

    private static func check(_ name: String, _ body: () async throws -> String) async -> Bool {
        do {
            let detail = try await body()
            print("✓ \(name): \(detail)")
            return true
        } catch {
            print("✗ \(name): \(error.localizedDescription)")
            return false
        }
    }

    private static func runAll() async -> Int {
        var failed = 0
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("localai-selftest")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try? "hallo".write(to: tmp.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)
        let tools = BuiltinTools.all { tmp }

        var model = ""
        if !(await check("Engine erreichbar") {
            let models = try await LLMClient.models()
            model = ProcessInfo.processInfo.environment["LOCAL_AI_MODEL"] ?? models.first { !$0.contains("DFlash") } ?? ""
            return "\(models.count) Modelle, teste mit \(model)"
        }) { failed += 1 }

        if !model.isEmpty, !(await check("Streaming mit Tool-Call") {
            var calls: [LLMClient.ToolCall] = []
            let list = tools.first { $0.name == "list_directory" }!
            for try await ev in LLMClient.stream(model: model,
                                                 messages: [["role": "user", "content": "Liste den Arbeitsordner mit dem Werkzeug auf."]],
                                                 tools: [list.openAISpec], thinking: false, maxTokens: 200) {
                if case let .toolCalls(c) = ev { calls = c }
            }
            guard let c = calls.first else { throw ToolError.invalid("kein Tool-Call erhalten") }
            return "\(c.name)(\(c.arguments))"
        }) { failed += 1 }

        if !(await check("Werkzeug list_directory") {
            let out = try await tools.first { $0.name == "list_directory" }!.run([:])
            guard out.contains("probe.txt") else { throw ToolError.invalid("probe.txt fehlt: \(out)") }
            return out.replacingOccurrences(of: "\n", with: ", ")
        }) { failed += 1 }

        if !(await check("Werkzeug run_shell") {
            try await tools.first { $0.name == "run_shell" }!.run(["command": "echo ok"]).replacingOccurrences(of: "\n", with: " ")
        }) { failed += 1 }

        if !model.isEmpty, !(await check("MCP-Client ↔ eigener MCP-Server") {
            // Die App spricht mit sich selbst: Client-Code und --mcp-server in einem Durchlauf.
            let exe = Bundle.main.executableURL!.path
            let client = MCPStdioClient(config: MCPServerConfig(name: "self", command: exe, args: ["--mcp-server"]))
            try await client.start()
            defer { client.stop() }
            let list = try await client.listTools()
            let answer = try await client.callTool("local_chat", arguments: ["prompt": "Antworte nur mit dem Wort: bereit", "max_tokens": 10])
            return "\(list.map(\.name).joined(separator: ", ")) · local_chat → \(answer.trimmingCharacters(in: .whitespacesAndNewlines))"
        }) { failed += 1 }
        if !(await check("Hugging Face: Dateiliste + Download") {
            let repo = "mlx-works/Ornith-1.5-35B-A3B-oQ3e-mtp"
            let files = try await HuggingFace.files(repo: repo)
            let total = files.reduce(Int64(0)) { $0 + $1.size }
            let dest = tmp.appendingPathComponent("config.json")
            try await FileDownload.fetch(HuggingFace.resolveURL(repo: repo, path: "config.json"), to: dest) { _ in }
            let size = (try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
            return "\(files.count) Dateien, \(formatBytes(total)), config.json \(size) B geladen"
        }) { failed += 1 }
        return failed
    }
}
