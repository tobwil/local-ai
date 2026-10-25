import Foundation

/// Claude über die Messages-API (rohes HTTP mit SSE – für Swift gibt es kein offizielles SDK).
/// Übersetzt den Verlauf im OpenAI-Format, streamt Text, Thinking und Tool-Aufrufe und
/// liefert am Ende die Original-Inhaltsblöcke zurück, damit Thinking-Blöcke unverändert
/// wieder mitgeschickt werden können.
enum AnthropicClient {
    static let version = "2026-10-21"
    /// Modelle, für die serverseitige Fallbacks bei Ablehnungen eingeschaltet werden.
    static let fallbackModels: Set<String> = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-1", "claude-opus-5"]

    static func stream(model: String, key: String, base: URL, messages: [[String: Any]], tools: [[String: Any]],
                       thinking: Bool, maxTokens: Int) -> AsyncThrowingStream<LLMClient.Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (system, converted) = convert(messages)
                    var body: [String: Any] = [
                        "model": model, "max_tokens": max(maxTokens, 16_000), "stream": true,
                        "messages": converted,
                        // Automatisches Prompt-Caching: der lange Systemprompt + Werkzeuge werden wiederverwendet.
                        "cache_control": ["type": "ephemeral"],
                        "output_config": ["effort": UserDefaults.standard.string(forKey: "anthropicEffort") ?? "high"],
                    ]
                    if !system.isEmpty { body["system"] = system }
                    if thinking { body["thinking"] = ["type": "adaptive", "display": "summarized"] }
                    if !tools.isEmpty { body["tools"] = tools.compactMap(convertTool) }
                    var req = URLRequest(url: base.appendingPathComponent("v1/messages"))
                    req.httpMethod = "POST"
                    req.timeoutInterval = 1800
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue(key, forHTTPHeaderField: "x-api-key")
                    req.setValue(version, forHTTPHeaderField: "anthropic-version")
                    if fallbackModels.contains(model), base == Endpoint.anthropicBase {
                        body["fallbacks"] = "default"
                        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                    }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                        var text = ""
                        for try await line in bytes.lines { text += line }
                        throw LLMError.http(http.statusCode, text)
                    }

                    var blocks: [Int: [String: Any]] = [:]
                    var partialJSON: [Int: String] = [:]
                    var stopReason = ""
                    var inputTokens = 0, outputTokens = 0
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:"),
                              let ev = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any]
                        else { continue }
                        switch ev["type"] as? String {
                        case "message_start":
                            let usage = (ev["message"] as? [String: Any])?["usage"] as? [String: Any]
                            inputTokens = (usage?["input_tokens"] as? Int ?? 0) + (usage?["cache_read_input_tokens"] as? Int ?? 0)
                        case "content_block_start":
                            guard let i = ev["index"] as? Int, let block = ev["content_block"] as? [String: Any] else { continue }
                            blocks[i] = block
                            if block["type"] as? String == "tool_use" { partialJSON[i] = "" }
                        case "content_block_delta":
                            guard let i = ev["index"] as? Int, let d = ev["delta"] as? [String: Any] else { continue }
                            switch d["type"] as? String {
                            case "text_delta":
                                let t = d["text"] as? String ?? ""
                                let prev = blocks[i]?["text"] as? String ?? ""
                                blocks[i]?["text"] = prev + t
                                if !t.isEmpty { continuation.yield(.content(t)) }
                            case "thinking_delta":
                                let t = d["thinking"] as? String ?? ""
                                let prev = blocks[i]?["thinking"] as? String ?? ""
                                blocks[i]?["thinking"] = prev + t
                                if !t.isEmpty { continuation.yield(.reasoning(t)) }
                            case "signature_delta":
                                let prev = blocks[i]?["signature"] as? String ?? ""
                                blocks[i]?["signature"] = prev + (d["signature"] as? String ?? "")
                            case "input_json_delta":
                                partialJSON[i, default: ""] += d["partial_json"] as? String ?? ""
                            default:
                                break
                            }
                        case "content_block_stop":
                            guard let i = ev["index"] as? Int, let json = partialJSON[i] else { continue }
                            // Mit eager_input_streaming prüft der Server die Eingabe nicht – hier selbst parsen.
                            let input = (try? JSONSerialization.jsonObject(with: Data((json.isEmpty ? "{}" : json).utf8))) as? [String: Any]
                            blocks[i]?["input"] = input ?? [:]
                            blocks[i]?["_raw_input"] = json
                        case "message_delta":
                            if let r = (ev["delta"] as? [String: Any])?["stop_reason"] as? String { stopReason = r }
                            if let o = (ev["usage"] as? [String: Any])?["output_tokens"] as? Int { outputTokens = o }
                        case "error":
                            let msg = (ev["error"] as? [String: Any])?["message"] as? String ?? "Fehler im Stream"
                            throw LLMError.http(0, msg)
                        default:
                            break
                        }
                    }

                    let ordered = blocks.keys.sorted().compactMap { blocks[$0] }
                    continuation.yield(.usage(prompt: inputTokens, completion: outputTokens))
                    if stopReason == "refusal" {
                        throw LLMError.http(200, "Claude hat die Anfrage abgelehnt (refusal).")
                    }
                    // Bei abgeschnittener Antwort keine halben Tool-Aufrufe ausführen.
                    if stopReason != "max_tokens" {
                        let calls = ordered.filter { $0["type"] as? String == "tool_use" }.map { b -> LLMClient.ToolCall in
                            let raw = b["_raw_input"] as? String ?? "{}"
                            return LLMClient.ToolCall(id: b["id"] as? String ?? "", name: b["name"] as? String ?? "",
                                                      arguments: raw.isEmpty ? "{}" : raw)
                        }
                        if !calls.isEmpty { continuation.yield(.toolCalls(calls)) }
                    }
                    continuation.yield(.raw(ordered.map { var b = $0; b["_raw_input"] = nil; return b }))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func convertTool(_ spec: [String: Any]) -> [String: Any]? {
        guard let f = spec["function"] as? [String: Any], let name = f["name"] as? String else { return nil }
        return ["name": name, "description": f["description"] as? String ?? "",
                "input_schema": f["parameters"] as? [String: Any] ?? ["type": "object", "properties": [:]],
                "eager_input_streaming": true]
    }

    /// OpenAI-Verlauf → Messages-API. Aufeinanderfolgende Tool-Ergebnisse landen in einer Nutzer-Nachricht.
    static func convert(_ history: [[String: Any]]) -> (system: String, messages: [[String: Any]]) {
        var system: [String] = []
        var out: [[String: Any]] = []

        func append(role: String, _ blocks: [[String: Any]]) {
            guard !blocks.isEmpty else { return }
            if let last = out.last, last["role"] as? String == role, var content = last["content"] as? [[String: Any]] {
                content += blocks
                out[out.count - 1]["content"] = content
            } else {
                out.append(["role": role, "content": blocks])
            }
        }

        for msg in history {
            switch msg["role"] as? String {
            case "system":
                if let s = msg["content"] as? String { system.append(s) }
            case "user":
                if let s = msg["content"] as? String {
                    append(role: "user", [["type": "text", "text": s]])
                } else if let parts = msg["content"] as? [[String: Any]] {
                    append(role: "user", parts.compactMap { p in
                        if p["type"] as? String == "text" { return ["type": "text", "text": p["text"] as? String ?? ""] }
                        if let url = (p["image_url"] as? [String: Any])?["url"] as? String, url.hasPrefix("data:"),
                           let comma = url.firstIndex(of: ",") {
                            let media = url.dropFirst(5).prefix { $0 != ";" }
                            return ["type": "image", "source": ["type": "base64", "media_type": String(media),
                                                                "data": String(url[url.index(after: comma)...])]]
                        }
                        return nil
                    })
                }
            case "assistant":
                if let raw = msg["_anthropic_content"] as? [[String: Any]] {
                    append(role: "assistant", raw)   // unverändert, inkl. Thinking-Signaturen
                    continue
                }
                var blocks: [[String: Any]] = []
                if let t = msg["content"] as? String, !t.isEmpty { blocks.append(["type": "text", "text": t]) }
                for call in msg["tool_calls"] as? [[String: Any]] ?? [] {
                    let f = call["function"] as? [String: Any] ?? [:]
                    let args = (f["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
                    blocks.append(["type": "tool_use", "id": call["id"] as? String ?? UUID().uuidString,
                                   "name": f["name"] as? String ?? "", "input": args as? [String: Any] ?? [:]])
                }
                append(role: "assistant", blocks)
            case "tool":
                append(role: "user", [["type": "tool_result", "tool_use_id": msg["tool_call_id"] as? String ?? "",
                                       "content": msg["content"] as? String ?? ""]])
            default:
                break
            }
        }
        return (system.joined(separator: "\n\n"), out)
    }
}
