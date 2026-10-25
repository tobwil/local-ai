import Foundation
import Observation

/// Was der Agent über Skills, Sub-Agenten und Einstellungen wissen muss.
struct AgentContext {
    var skills: [Skill]
    var agents: [SubAgentDef]
    var commands: [SlashCommand]
    var customInstructions: String
    var maxSteps: Int
    var maxTokens: Int
}

/// Ein Gespräch mit dem lokalen Modell. Im Agent-Modus darf das Modell Werkzeuge aufrufen;
/// riskante Aufrufe warten auf die Freigabe im Chat.
@MainActor @Observable
final class AgentSession {
    enum ToolState: String { case awaitingApproval, running, done, failed, denied }

    struct Item: Identifiable {
        enum Kind {
            case user(String, images: [Data])
            case assistant(text: String, thinking: String, stats: Stats?)
            case tool(name: String, source: String, arguments: String, state: ToolState, result: String)
            case error(String)
        }
        var id = UUID()
        var kind: Kind
    }

    struct Stats: Equatable {
        var model = ""
        var tokens: Int
        var tokPerSec: Double
        var promptTokens: Int
        var ttft: Double
    }

    private(set) var items: [Item] = []
    var input = ""
    /// Angehängte Bilder (JPEG) für die nächste Nachricht.
    var attachments: [Data] = []
    var agentMode = true
    var thinking = false
    /// YOLO-Modus: Werkzeuge laufen ohne Nachfrage (bleibt über Neustarts erhalten).
    var autoApprove = UserDefaults.standard.bool(forKey: "yolo") {
        didSet { UserDefaults.standard.set(autoApprove, forKey: "yolo") }
    }
    /// Notbremse: auch im YOLO-Modus bei zerstörerischen Aktionen fragen.
    var dangerGuard = UserDefaults.standard.object(forKey: "dangerGuard") as? Bool ?? true {
        didSet { UserDefaults.standard.set(dangerGuard, forKey: "dangerGuard") }
    }
    private(set) var isRunning = false
    private(set) var liveTokPerSec: Double = 0
    private(set) var chatID = UUID().uuidString
    private(set) var historyVersion = 0

    var workspace: URL {
        didSet { UserDefaults.standard.set(workspace.path, forKey: "workspace") }
    }

    private var history: [[String: Any]] = []

    var hasImagesInHistory: Bool {
        items.contains { if case let .user(_, imgs) = $0.kind { return !imgs.isEmpty }; return false }
    }
    private var runTask: Task<Void, Never>?
    private var approvals: [UUID: CheckedContinuation<Bool, Never>] = [:]

    init() {
        let saved = UserDefaults.standard.string(forKey: "workspace")
        workspace = saved.map { URL(fileURLWithPath: $0) } ?? Paths.home
    }

    func reset() {
        stop()
        items = []
        history = []
        chatID = UUID().uuidString
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

    func send(model: String, tools: [AgentTool], context: AgentContext) {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty, !isRunning else { return }
        if text.isEmpty { text = "Was ist auf dem Bild zu sehen?" }
        input = ""
        let images = attachments
        attachments = []
        let shown = text
        // Slash-Befehl: "/name argumente" → Vorlage des Befehls
        if text.hasPrefix("/") {
            let parts = text.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
            if let cmd = context.commands.first(where: { $0.name == parts.first }) {
                text = cmd.expand(parts.count > 1 ? parts[1] : "")
            }
        }
        if history.isEmpty { history.append(["role": "system", "content": systemPrompt(tools: tools, context: context)]) }
        items.append(Item(kind: .user(shown, images: images)))
        if images.isEmpty {
            history.append(["role": "user", "content": text])
        } else {
            let parts: [[String: Any]] = [["type": "text", "text": text]] + images.map {
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\($0.base64EncodedString())"]]
            }
            history.append(["role": "user", "content": parts])
        }
        isRunning = true
        runTask = Task {
            await loop(model: model, tools: agentMode ? tools : [], context: context)
            isRunning = false
            liveTokPerSec = 0
            save()
        }
    }

    // MARK: Systemprompt

    private func systemPrompt(tools: [AgentTool], context: AgentContext) -> String {
        var s = """
        Du bist ein hilfreicher, gründlicher Assistent, der lokal auf dem Mac des Nutzers läuft. \
        Antworte in der Sprache des Nutzers. Heute ist \(Date().formatted(date: .complete, time: .omitted)).
        """
        if agentMode && !tools.isEmpty {
            s += """


            Du arbeitest als Agent mit Werkzeugen. Arbeitsordner: \(workspace.path)
            - Plane kurz, nutze Werkzeuge gezielt und prüfe Ergebnisse, statt zu raten. Erfinde keine Dateiinhalte oder Fakten.
            - Für aktuelle Informationen: web_search, dann die besten Quellen mit fetch_url lesen und mit Links belegen.
            - Für Code: erst lesen (read_file, search_files, find_files), dann gezielt ändern (edit_file).
            - Anleitungen für Claude Code nennen Werkzeuge wie Read, Write, Edit, Bash, Grep, Glob, WebFetch, WebSearch, Task – \
            nutze dafür read_file, write_file, edit_file, run_shell, search_files, find_files, fetch_url, web_search, run_agent.
            """
            if tools.contains(where: { $0.name == "browser_read" }) {
                s += "\n- Browser des Nutzers: erst browser_tabs/browser_read, dann mit den Nummern [n] browser_click/browser_type. Nach jeder Aktion den neuen Zustand prüfen. Keine Käufe, Zahlungen, Logins oder Nachrichten ohne ausdrückliche Bitte des Nutzers."
            }
            if !context.skills.isEmpty {
                s += "\n\n## Skills\nWenn eine Aufgabe zu einem Skill passt, lade ihn ZUERST mit use_skill und folge seiner Anleitung.\n"
                for sk in context.skills.prefix(80) {
                    s += "- \(sk.name): \(sk.description.prefix(240))\n"
                }
            }
            if !context.agents.isEmpty {
                s += "\n## Sub-Agenten (über run_agent)\n"
                for a in context.agents.prefix(40) { s += "- \(a.name): \(a.description.prefix(200))\n" }
            }
        }
        let memory = SystemTools.memory().trimmingCharacters(in: .whitespacesAndNewlines)
        if agentMode && tools.contains(where: { $0.name == "remember" }) {
            s += "\n\n## Gedächtnis\nMit remember/forget pflegst du dauerhafte Notizen über den Nutzer."
            if !memory.isEmpty { s += " Bisher gemerkt:\n\(memory.suffix(4000))" }
        }
        if !context.customInstructions.isEmpty {
            s += "\n\n## Anweisungen des Nutzers\n\(context.customInstructions)"
        }
        return s
    }

    // MARK: Agent-Schleife

    private func loop(model: String, tools: [AgentTool], context: AgentContext) async {
        let specs = tools.map(\.openAISpec)
        for _ in 0..<context.maxSteps {
            if Task.isCancelled { return }
            let index = items.count
            items.append(Item(kind: .assistant(text: "", thinking: "", stats: nil)))
            var text = "", thought = ""
            var calls: [LLMClient.ToolCall] = []
            var rawBlocks: [[String: Any]]?
            var completion = 0, prompt = 0
            let t0 = Date()
            var tFirst: Date?
            var chunks = 0

            do {
                for try await ev in LLMClient.stream(model: model, messages: history, tools: specs,
                                                     thinking: thinking, maxTokens: context.maxTokens) {
                    switch ev {
                    case let .content(c): text += c
                    case let .reasoning(r): thought += r
                    case let .toolCalls(c): calls = c; continue
                    case let .usage(p, c): prompt = p; completion = c; continue
                    case let .raw(b): rawBlocks = b; continue
                    }
                    chunks += 1
                    let now = Date()
                    if tFirst == nil { tFirst = now }
                    if let f = tFirst, now.timeIntervalSince(f) > 0.3 {
                        liveTokPerSec = Double(chunks - 1) / now.timeIntervalSince(f)
                    }
                    items[index].kind = .assistant(text: text, thinking: thought, stats: nil)
                }
            } catch {
                if !Task.isCancelled { items.append(Item(kind: .error(error.localizedDescription))) }
                return
            }

            let end = Date()
            let tokens = completion > 0 ? completion : chunks
            let decode = tFirst.map { end.timeIntervalSince($0) } ?? 0
            let stats = Stats(model: model, tokens: tokens, tokPerSec: decode > 0 ? Double(max(tokens - 1, 0)) / decode : 0,
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
            if let rawBlocks { assistant["_anthropic_content"] = rawBlocks }
            history.append(assistant)
            if calls.isEmpty { return }

            for call in calls {
                if Task.isCancelled { return }
                let result = await execute(call, tools: tools)
                history.append(["role": "tool", "tool_call_id": call.id, "content": result])
            }
        }
        items.append(Item(kind: .error("Abgebrochen nach \(context.maxSteps) Schritten.")))
    }

    private func execute(_ call: LLMClient.ToolCall, tools: [AgentTool]) async -> String {
        let tool = tools.first { $0.name == call.name }
        let index = items.count
        let args = prettyJSON(call.arguments)
        items.append(Item(kind: .tool(name: call.name, source: tool?.source ?? "?", arguments: args, state: .running, result: "")))
        func update(_ state: ToolState, _ result: String) {
            items[index].kind = .tool(name: call.name, source: tool?.source ?? "?", arguments: args, state: state, result: result)
        }
        guard let tool else {
            update(.failed, "Unbekanntes Werkzeug")
            return "Fehler: Werkzeug \(call.name) gibt es nicht. Verfügbar: \(tools.map(\.name).joined(separator: ", "))"
        }
        let parsed = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any]) ?? [:]

        let dangerous = dangerGuard ? Self.dangerReason(tool: tool.name, args: parsed) : nil
        if tool.needsApproval && (!autoApprove || dangerous != nil) {
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
            let out = try await tool.run(parsed)
            update(.done, out)
            return out
        } catch {
            update(.failed, error.localizedDescription)
            return "Fehler: \(error.localizedDescription)"
        }
    }

    /// Erkennt Aktionen, die auch im YOLO-Modus eine Freigabe brauchen. nil = unbedenklich.
    nonisolated static func dangerReason(tool: String, args: [String: Any]) -> String? {
        if tool == "run_shell", let cmd = (args["command"] as? String)?.lowercased() {
            let patterns = [#"\bsudo\b"#, #"\brm\s+(-[a-z]*[rf][a-z]*\s+)+"#, #"\bmkfs"#, #"\bdiskutil\s+(erase|partition|zero)"#,
                            #"\bdd\s+if="#, #">\s*/dev/(disk|rdisk)"#, #"\bgit\s+push\b.*(-f\b|--force)"#, #"\bgit\s+reset\s+--hard"#,
                            #"\b(shutdown|reboot|halt)\b"#, #"\bkillall\b"#, #"\blaunchctl\s+(unload|remove|bootout)"#,
                            #"\bcsrutil\b"#, #"\bsecurity\s+delete"#, #"\bchmod\s+-r\s+777"#, #"curl[^|]*\|\s*(ba|z)?sh"#,
                            #"\bsrm\b"#, #"\bfind\b.*-delete"#]
            if let hit = patterns.first(where: { cmd.range(of: $0, options: .regularExpression) != nil }) {
                return "Shell-Befehl passt auf Schutzregel \(hit)"
            }
        }
        if tool == "write_file" || tool == "edit_file", let path = args["path"] as? String {
            let p = (path as NSString).expandingTildeInPath
            if p.hasPrefix("/") && !p.hasPrefix(Paths.home.path) && !p.hasPrefix("/tmp") && !p.hasPrefix("/private/tmp") {
                return "Schreiben außerhalb des Benutzerordners"
            }
        }
        if tool == "http_request", let m = (args["method"] as? String)?.uppercased(), m == "DELETE" { return "HTTP DELETE" }
        return nil
    }

    private func prettyJSON(_ s: String) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return s }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Sub-Agent

    /// Führt einen Sub-Agenten ohne Rückfragen aus (nur lesende Werkzeuge) und liefert seine Schlussantwort.
    static func runSubAgent(model: String, system: String, task: String, tools: [AgentTool], maxSteps: Int) async throws -> String {
        var messages: [[String: Any]] = [["role": "system", "content": system], ["role": "user", "content": task]]
        let specs = tools.map(\.openAISpec)
        for _ in 0..<maxSteps {
            var text = ""
            var calls: [LLMClient.ToolCall] = []
            for try await ev in LLMClient.stream(model: model, messages: messages, tools: specs, thinking: false) {
                if case let .content(c) = ev { text += c }
                if case let .toolCalls(c) = ev { calls = c }
            }
            var assistant: [String: Any] = ["role": "assistant", "content": text]
            if !calls.isEmpty {
                assistant["tool_calls"] = calls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] }
            }
            messages.append(assistant)
            if calls.isEmpty { return text }
            for call in calls {
                let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any]) ?? [:]
                let out: String
                if let tool = tools.first(where: { $0.name == call.name }) {
                    out = (try? await tool.run(args)) ?? "Fehler bei \(call.name)"
                } else {
                    out = "Werkzeug \(call.name) ist für Sub-Agenten nicht verfügbar."
                }
                messages.append(["role": "tool", "tool_call_id": call.id, "content": out])
            }
        }
        return "(Sub-Agent hat nach \(maxSteps) Schritten aufgehört)"
    }

    // MARK: Speichern & Laden

    var title: String {
        for item in items { if case let .user(t, _) = item.kind { return String(t.prefix(60)) } }
        return "Neues Gespräch"
    }

    private func save() {
        guard !items.isEmpty else { return }
        let encoded: [[String: Any]] = items.map { item in
            switch item.kind {
            case let .user(t, imgs): return ["k": "user", "text": t, "images": imgs.map { $0.base64EncodedString() }]
            case let .assistant(t, th, st):
                var d: [String: Any] = ["k": "assistant", "text": t, "thinking": th]
                if let st { d["stats"] = [st.tokens, st.tokPerSec, st.promptTokens, st.ttft, st.model] as [Any] }
                return d
            case let .tool(n, src, a, s, r):
                return ["k": "tool", "name": n, "source": src, "args": a, "state": s.rawValue, "result": String(r.prefix(20_000))]
            case let .error(m): return ["k": "error", "text": m]
            }
        }
        ChatStore.save(id: chatID, ["title": title, "updated": Date().timeIntervalSince1970,
                                    "items": encoded, "history": history])
        historyVersion += 1
    }

    func load(id: String) {
        guard !isRunning, let json = ChatStore.load(id: id) else { return }
        chatID = id
        history = json["history"] as? [[String: Any]] ?? []
        items = (json["items"] as? [[String: Any]] ?? []).compactMap { d in
            switch d["k"] as? String {
            case "user":
                let imgs = (d["images"] as? [String] ?? []).compactMap { Data(base64Encoded: $0) }
                return Item(kind: .user(d["text"] as? String ?? "", images: imgs))
            case "assistant":
                let s = d["stats"] as? [Any]
                let stats = s.flatMap { s -> Stats? in
                    guard s.count >= 4 else { return nil }
                    return Stats(model: s.count > 4 ? s[4] as? String ?? "" : "", tokens: s[0] as? Int ?? 0, tokPerSec: s[1] as? Double ?? 0,
                                 promptTokens: s[2] as? Int ?? 0, ttft: s[3] as? Double ?? 0)
                }
                return Item(kind: .assistant(text: d["text"] as? String ?? "", thinking: d["thinking"] as? String ?? "", stats: stats))
            case "tool":
                let state = ToolState(rawValue: d["state"] as? String ?? "") ?? .done
                return Item(kind: .tool(name: d["name"] as? String ?? "", source: d["source"] as? String ?? "",
                                        arguments: d["args"] as? String ?? "",
                                        state: state == .awaitingApproval || state == .running ? .denied : state,
                                        result: d["result"] as? String ?? ""))
            case "error": return Item(kind: .error(d["text"] as? String ?? ""))
            default: return nil
            }
        }
    }
}
