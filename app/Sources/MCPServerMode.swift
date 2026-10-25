import Foundation

/// `KI lokal --mcp-server`: stellt das lokale Modell als MCP-Server über stdio bereit,
/// damit Claude Code, Claude Desktop oder andere MCP-Clients Aufgaben daran abgeben können.
/// Voraussetzung: oMLX läuft (in der App gestartet oder per tools/serve.sh).
enum MCPServerMode {
    static func run() {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = msg["method"] as? String else { continue }
            // Nachrichten ohne id sind Notifications und bekommen keine Antwort.
            guard let id = msg["id"] else { continue }
            let params = msg["params"] as? [String: Any] ?? [:]
            let response: [String: Any]
            do {
                response = ["jsonrpc": "2.0", "id": id, "result": try handle(method, params)]
            } catch {
                response = ["jsonrpc": "2.0", "id": id,
                            "error": ["code": -32603, "message": error.localizedDescription]]
            }
            if let out = try? JSONSerialization.data(withJSONObject: response) {
                FileHandle.standardOutput.write(out + Data([0x0A]))
            }
        }
    }

    private static func handle(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "initialize":
            return ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "ki-lokal", "version": "0.3.0"],
                    "instructions": "Lokales LLM auf diesem Mac (oMLX). Gut für Zusammenfassungen, Entwürfe, Code-Umbauten und alles, was den Rechner nicht verlassen soll."]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": [
                ["name": "local_chat",
                 "description": "Schickt eine Aufgabe an das lokale Modell auf diesem Mac und gibt die Antwort zurück. Daten verlassen den Rechner nicht.",
                 "inputSchema": ["type": "object",
                                 "properties": ["prompt": ["type": "string", "description": "Aufgabe oder Frage"],
                                                "system": ["type": "string", "description": "Optionale Systemanweisung"],
                                                "max_tokens": ["type": "integer", "description": "Standard 2048"]],
                                 "required": ["prompt"]]],
                ["name": "local_models",
                 "description": "Listet die lokal verfügbaren Modelle.",
                 "inputSchema": ["type": "object", "properties": [:]]],
            ]]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let text = try blocking { try await callTool(name, args) }
            return ["content": [["type": "text", "text": text]]]
        default:
            throw ToolError.invalid("Unbekannte Methode \(method)")
        }
    }

    private static func callTool(_ name: String, _ args: [String: Any]) async throws -> String {
        let models: [String]
        do {
            models = try await LLMClient.models()
        } catch {
            throw ToolError.invalid("Der lokale Server läuft nicht – starte ihn in der App KI/lokal (oder mit tools/serve.sh).")
        }
        switch name {
        case "local_models":
            return models.joined(separator: "\n")
        case "local_chat":
            guard let prompt = args["prompt"] as? String else { throw ToolError.invalid("prompt fehlt") }
            let preferred = ProcessInfo.processInfo.environment["LOCAL_AI_MODEL"]
                ?? UserDefaults.standard.string(forKey: "selectedModel")
            let model = models.first { $0 == preferred } ?? models.first { !$0.contains("DFlash") } ?? ""
            guard !model.isEmpty else { throw ToolError.invalid("Kein lokales Modell verfügbar – läuft oMLX?") }
            return try await LLMClient.complete(model: model, prompt: prompt, system: args["system"] as? String,
                                                maxTokens: args["max_tokens"] as? Int ?? 2048)
        default:
            throw ToolError.invalid("Unbekanntes Werkzeug \(name)")
        }
    }

    /// stdio ist synchron; die HTTP-Aufrufe sind async.
    private static func blocking<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, Error>!
        Task.detached {
            do { result = .success(try await work()) } catch { result = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try result.get()
    }
}
