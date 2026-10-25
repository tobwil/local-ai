import Foundation

/// OpenAI-kompatibler Chat-Client für oMLX, mit Streaming und Tool-Calls.
enum LLMClient {
    struct ToolCall: Equatable {
        var id: String
        var name: String
        var arguments: String
    }

    enum Event {
        case content(String)
        case reasoning(String)
        case toolCalls([ToolCall])
        case usage(prompt: Int, completion: Int)
        /// Original-Inhaltsblöcke der Antwort (nur Anthropic), um sie unverändert zurückzuschicken.
        case raw([[String: Any]])
        /// Antwort am Längenlimit (max_tokens) abgeschnitten – halbe Werkzeug-Aufrufe wurden verworfen.
        case truncated
    }

    /// Streamt eine Antwort. `messages` und `tools` sind bereits im OpenAI-JSON-Format.
    /// Modell-IDs mit "anthropic:" bzw. "openai:" gehen an den jeweiligen Cloud-Anbieter.
    /// `mtp: false` schickt `X-oMLX-MTP: off` – oMLX dekodiert diese Anfrage dann ohne Spekulation.
    static func stream(model modelID: String, messages: [[String: Any]], tools: [[String: Any]],
                       thinking: Bool, maxTokens: Int = 4096, mtp: Bool = true) -> AsyncThrowingStream<Event, Error> {
        let (endpoint, model) = Endpoint.resolve(modelID)
        if case let .anthropic(key, base) = endpoint {
            return AnthropicClient.stream(model: model, key: key, base: base, messages: messages, tools: tools,
                                          thinking: thinking, maxTokens: maxTokens)
        }
        // Private Felder (z. B. _anthropic_content) nicht an OpenAI-kompatible Server schicken.
        let messages = messages.map { $0.filter { !$0.key.hasPrefix("_") } }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var body: [String: Any] = [
                        "model": model, "stream": true,
                        "messages": messages,
                        "stream_options": ["include_usage": true],
                    ]
                    var base = Paths.openAIBase
                    var req = URLRequest(url: base)
                    if case let .openai(key, b) = endpoint {
                        base = b
                        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                        // OpenAI selbst erwartet max_completion_tokens, andere kompatible Dienste meist max_tokens.
                        body[b.host == "api.openai.com" ? "max_completion_tokens" : "max_tokens"] = maxTokens
                        if thinking { body["reasoning_effort"] = "high" }
                    } else {
                        HomeNetwork.authorize(&req)
                        body["max_tokens"] = maxTokens
                        body["chat_template_kwargs"] = ["enable_thinking": thinking]
                        if !mtp { req.setValue("off", forHTTPHeaderField: "X-oMLX-MTP") }
                    }
                    if !tools.isEmpty { body["tools"] = tools }
                    req.url = base.appendingPathComponent("chat/completions")
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                    req.timeoutInterval = 1800

                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                        var text = ""
                        for try await line in bytes.lines { text += line }
                        throw LLMError.http(http.statusCode, text)
                    }

                    var calls: [Int: ToolCall] = [:]
                    var truncated = false
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let ev = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let u = ev["usage"] as? [String: Any],
                           let c = u["completion_tokens"] as? Int {
                            continuation.yield(.usage(prompt: u["prompt_tokens"] as? Int ?? 0, completion: c))
                        }
                        for choice in ev["choices"] as? [[String: Any]] ?? [] {
                            if choice["finish_reason"] as? String == "length" { truncated = true }
                            guard let delta = choice["delta"] as? [String: Any] else { continue }
                            if let r = (delta["reasoning_content"] ?? delta["reasoning"]) as? String, !r.isEmpty {
                                continuation.yield(.reasoning(r))
                            }
                            if let c = delta["content"] as? String, !c.isEmpty {
                                continuation.yield(.content(c))
                            }
                            // Tool-Calls kommen in Stücken pro Index.
                            for tc in delta["tool_calls"] as? [[String: Any]] ?? [] {
                                let i = tc["index"] as? Int ?? calls.count
                                var call = calls[i] ?? ToolCall(id: "", name: "", arguments: "")
                                if let id = tc["id"] as? String { call.id = id }
                                if let f = tc["function"] as? [String: Any] {
                                    if let n = f["name"] as? String { call.name += n }
                                    if let a = f["arguments"] as? String { call.arguments += a }
                                }
                                calls[i] = call
                            }
                        }
                    }
                    if truncated {
                        continuation.yield(.truncated)
                    } else if !calls.isEmpty {
                        let ordered = calls.keys.sorted().compactMap { calls[$0] }.map { c -> ToolCall in
                            var c = c
                            if c.id.isEmpty { c.id = "call_\(UUID().uuidString.prefix(8))" }
                            return c
                        }
                        continuation.yield(.toolCalls(ordered))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Eine Antwort ohne Streaming (für den MCP-Server-Modus).
    /// Komplette Antwort über den Stream gesammelt (für Experten-Anfragen an beliebige Anbieter).
    static func collect(model: String, system: String, prompt: String, maxTokens: Int = 8000) async throws -> String {
        var text = ""
        for try await ev in stream(model: model, messages: [["role": "system", "content": system], ["role": "user", "content": prompt]],
                                   tools: [], thinking: false, maxTokens: maxTokens) {
            if case let .content(c) = ev { text += c }
        }
        return text
    }

    static func complete(model: String, prompt: String, system: String?, maxTokens: Int) async throws -> String {
        var messages: [[String: Any]] = []
        if let system { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": prompt])
        let body: [String: Any] = ["model": model, "max_tokens": maxTokens, "messages": messages,
                                   "chat_template_kwargs": ["enable_thinking": false]]
        var req = URLRequest(url: Paths.openAIBase.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 1800
        HomeNetwork.authorize(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else {
            throw LLMError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        return msg["content"] as? String ?? ""
    }

    static func models() async throws -> [String] {
        var req = URLRequest(url: Paths.openAIBase.appendingPathComponent("models"))
        HomeNetwork.authorize(&req)
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }
}

enum LLMError: LocalizedError {
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case let .http(code, body): return "Server antwortete mit \(code): \(body.prefix(300))"
        }
    }
}
