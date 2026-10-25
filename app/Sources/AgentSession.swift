import Foundation
import Observation

/// Ein Gespräch mit dem lokalen Modell. Im Agent-Modus darf das Modell Werkzeuge aufrufen;
/// riskante Aufrufe warten auf die Freigabe im Chat.
@MainActor @Observable
final class AgentSession {
    enum ToolState: Equatable { case awaitingApproval, running, done, failed, denied }

    struct Item: Identifiable {
        enum Kind {
            case user(String)
            case assistant(text: String, thinking: String, stats: Stats?)
            case tool(name: String, source: String, arguments: String, state: ToolState, result: String)
            case error(String)
        }
        let id = UUID()
        var kind: Kind
    }

    struct Stats: Equatable {
        var tokens: Int
        var tokPerSec: Double
        var promptTokens: Int
        var ttft: Double
    }

    private(set) var items: [Item] = []
    var input = ""
    var agentMode = true
    var thinking = false
    var autoApprove = false
    private(set) var isRunning = false
    private(set) var liveTokPerSec: Double = 0

    var workspace: URL {
        didSet { UserDefaults.standard.set(workspace.path, forKey: "workspace") }
    }

    private var history: [[String: Any]] = []
    private var runTask: Task<Void, Never>?
    private var approvals: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private let maxSteps = 16

    init() {
        let saved = UserDefaults.standard.string(forKey: "workspace")
        workspace = saved.map { URL(fileURLWithPath: $0) } ?? Paths.home
    }

    func reset() {
        stop()
        items = []
        history = []
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        for (_, c) in approvals { c.resume(returning: false) }
        approvals.removeAll()
    }

    func approve(_ id: UUID, _ ok: Bool) {
        approvals.removeValue(forKey: id)?.resume(returning: ok)
    }

    func send(model: String, tools: [AgentTool]) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        input = ""
        if history.isEmpty { history.append(["role": "system", "content": systemPrompt(tools: tools)]) }
        items.append(Item(kind: .user(text)))
        history.append(["role": "user", "content": text])
        isRunning = true
        runTask = Task {
            await loop(model: model, tools: agentMode ? tools : [])
            isRunning = false
            liveTokPerSec = 0
        }
    }

    private func systemPrompt(tools: [AgentTool]) -> String {
        var s = "Du bist ein hilfreicher Assistent, der lokal auf dem Mac des Nutzers läuft. Antworte in der Sprache des Nutzers."
        if agentMode && !tools.isEmpty {
            s += " Du kannst Werkzeuge benutzen. Arbeitsordner: \(workspace.path). Nutze Werkzeuge gezielt, fasse Ergebnisse knapp zusammen und erfinde keine Dateiinhalte."
        }
        return s
    }

    private func loop(model: String, tools: [AgentTool]) async {
        let specs = tools.map(\.openAISpec)
        for _ in 0..<maxSteps {
            if Task.isCancelled { return }
            let index = items.count
            items.append(Item(kind: .assistant(text: "", thinking: "", stats: nil)))
            var text = "", thought = ""
            var calls: [LLMClient.ToolCall] = []
            var completion = 0, prompt = 0
            let t0 = Date()
            var tFirst: Date?
            var chunks = 0

            do {
                for try await ev in LLMClient.stream(model: model, messages: history, tools: specs, thinking: thinking) {
                    switch ev {
                    case let .content(c): text += c
                    case let .reasoning(r): thought += r
                    case let .toolCalls(c): calls = c
                    case let .usage(p, c): prompt = p; completion = c
                    }
                    if case .toolCalls = ev {} else if case .usage = ev {} else {
                        chunks += 1
                        let now = Date()
                        if tFirst == nil { tFirst = now }
                        if let f = tFirst, now.timeIntervalSince(f) > 0.3 {
                            liveTokPerSec = Double(chunks - 1) / now.timeIntervalSince(f)
                        }
                        items[index].kind = .assistant(text: text, thinking: thought, stats: nil)
                    }
                }
            } catch {
                if !Task.isCancelled { items.append(Item(kind: .error(error.localizedDescription))) }
                return
            }

            let end = Date()
            let tokens = completion > 0 ? completion : chunks
            let decode = tFirst.map { end.timeIntervalSince($0) } ?? 0
            let stats = Stats(tokens: tokens, tokPerSec: decode > 0 ? Double(max(tokens - 1, 0)) / decode : 0,
                              promptTokens: prompt, ttft: (tFirst ?? end).timeIntervalSince(t0))
            if text.isEmpty && thought.isEmpty && !calls.isEmpty {
                items.remove(at: index)
            } else {
                items[index].kind = .assistant(text: text, thinking: thought, stats: stats)
            }

            var assistant: [String: Any] = ["role": "assistant", "content": text]
            if !calls.isEmpty {
                assistant["tool_calls"] = calls.map {
                    ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]]
                }
            }
            history.append(assistant)
            if calls.isEmpty { return }

            for call in calls {
                if Task.isCancelled { return }
                let result = await execute(call, tools: tools)
                history.append(["role": "tool", "tool_call_id": call.id, "content": result])
            }
        }
        items.append(Item(kind: .error("Abgebrochen nach \(maxSteps) Schritten.")))
    }

    private func execute(_ call: LLMClient.ToolCall, tools: [AgentTool]) async -> String {
        let tool = tools.first { $0.name == call.name }
        let index = items.count
        items.append(Item(kind: .tool(name: call.name, source: tool?.source ?? "?", arguments: prettyJSON(call.arguments),
                                      state: .running, result: "")))
        func update(_ state: ToolState, _ result: String) {
            items[index].kind = .tool(name: call.name, source: tool?.source ?? "?",
                                      arguments: prettyJSON(call.arguments), state: state, result: result)
        }
        guard let tool else {
            update(.failed, "Unbekanntes Werkzeug")
            return "Fehler: Werkzeug \(call.name) gibt es nicht."
        }
        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any]) ?? [:]

        if tool.needsApproval && !autoApprove {
            update(.awaitingApproval, "")
            let id = items[index].id
            let ok = await withCheckedContinuation { approvals[id] = $0 }
            guard ok else {
                update(.denied, "Abgelehnt")
                return "Der Nutzer hat diesen Aufruf abgelehnt."
            }
            update(.running, "")
        }
        do {
            let out = try await tool.run(args)
            update(.done, out)
            return out
        } catch {
            update(.failed, error.localizedDescription)
            return "Fehler: \(error.localizedDescription)"
        }
    }

    private func prettyJSON(_ s: String) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return s }
        return String(decoding: data, as: UTF8.self)
    }
}
