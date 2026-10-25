import AppKit
import Foundation
import Observation

@MainActor @Observable
final class AppState {
    static let shared = AppState()

    let hardware = Hardware.detect()
    let server = ServerController()
    let downloads = Downloads()
    let mcp = MCPManager()
    let plugins = PluginManager()
    let settings = AppSettings()
    let session = AgentSession()

    var selectedModelID: String {
        didSet { UserDefaults.standard.set(selectedModelID, forKey: "selectedModel") }
    }
    /// Wird erhöht, wenn sich installierte Modelle ändern, damit die Ansichten neu prüfen.
    private(set) var installGeneration = 0
    var useBuiltinTools = true
    var useWebTools = true

    init() {
        let hw = hardware
        let rec = ModelCatalog.recommended(for: hw)
        selectedModelID = UserDefaults.standard.string(forKey: "selectedModel")
            ?? ModelCatalog.all.first { $0.isInstalled && $0.fits(hw) }?.id
            ?? rec?.id ?? ModelCatalog.all[1].id
        // oMLX rechnet in GiB; knapp unter dem Metal-Limit bleiben (24-GB-Mac: 17,7).
        let limitGiB = hw.gpuLimitGB * 1e9 / 1_073_741_824
        server.memoryCeilingGiB = ((limitGiB - 0.05) * 10).rounded(.down) / 10
        BundledSkills.installIfNeeded()
        plugins.reload()
    }

    var recommended: ModelInfo? { ModelCatalog.recommended(for: hardware) }
    var selectedModel: ModelInfo? { ModelCatalog.model(id: selectedModelID) }
    var selectedModelName: String { CloudModels.displayName(selectedModelID) }
    var selectedIsCloud: Bool { CloudModels.isCloud(selectedModelID) }
    /// Senden geht, wenn der lokale Server läuft oder ein Cloud-Modell gewählt ist.
    var canSend: Bool { server.state.isUp || selectedIsCloud || (settings.routerEnabled && settings.routes.values.contains(where: CloudModels.isCloud)) }

    /// Katalog + Hugging Face + lokal gefunden; neu berechnet, wenn sich etwas ändert.
    var allModels: [ModelInfo] {
        _ = installGeneration
        return ModelCatalog.all
    }

    func addFromHub(_ m: HubModel) {
        let info = m.asModelInfo()
        CustomModels.add(info)
        installGeneration += 1
        download(info)
    }

    var installedModels: [ModelInfo] {
        _ = installGeneration
        return ModelCatalog.all.filter(\.isInstalled)
    }

    // MARK: Werkzeuge für den Agenten

    var agentTools: [AgentTool] {
        let ws = { [session] in session.workspace }
        var tools: [AgentTool] = []
        if useBuiltinTools { tools += BuiltinTools.files(ws) }
        if useWebTools { tools += BuiltinTools.web() }
        if settings.browserEnabled { tools += BrowserTools.all() }
        if useBuiltinTools { tools += SystemTools.all() }
        if !plugins.skills.isEmpty { tools.append(skillTool) }
        if !plugins.agents.isEmpty { tools.append(subAgentTool) }
        if !settings.expertModel.isEmpty { tools.append(expertTool) }
        return tools + mcp.tools
    }

    var agentContext: AgentContext {
        AgentContext(skills: plugins.skills, agents: plugins.agents, commands: plugins.commands,
                     customInstructions: settings.customInstructions,
                     maxSteps: settings.maxSteps, maxTokens: settings.maxTokens)
    }

    private var skillTool: AgentTool {
        let skills = plugins.skills
        return AgentTool(name: "use_skill",
                         description: "Lädt die Anleitung eines Skills (siehe Liste im Systemprompt) samt seiner Dateien.",
                         parameters: schema([("name", "string", "Name des Skills")], required: ["name"]),
                         needsApproval: false, source: "Skills") { args in
            let name = args["name"] as? String ?? ""
            guard let skill = skills.first(where: { $0.name == name }) ?? skills.first(where: { $0.name.lowercased() == name.lowercased() }) else {
                throw ToolError.invalid("Skill '\(name)' gibt es nicht. Verfügbar: \(skills.map(\.name).joined(separator: ", "))")
            }
            let body = Frontmatter(url: skill.file)?.body ?? ""
            let files = (FileManager.default.enumerator(atPath: skill.dir.path)?.allObjects as? [String] ?? [])
                .filter { $0 != "SKILL.md" && !$0.hasPrefix(".") }.prefix(60)
            var out = "# Skill: \(skill.name)\nOrdner: \(skill.dir.path)\n\n\(body)"
            if !files.isEmpty {
                out += "\n\n## Dateien im Skill (mit read_file lesen, Skripte mit run_shell ausführen)\n"
                out += files.map { "- \(skill.dir.appendingPathComponent($0).path)" }.joined(separator: "\n")
            }
            return out
        }
    }

    /// "Briefing-/Experten-Agent": der lokale Agent holt sich für schwere Teilfragen eine Einschätzung aus der Cloud.
    private var expertTool: AgentTool {
        let model = settings.expertModel
        return AgentTool(name: "ask_expert",
                         description: "Fragt ein stärkeres Cloud-Modell (\(CloudModels.displayName(model))) nach einer Einschätzung, einem Briefing oder einer Lösung für eine schwierige Teilaufgabe. Gib allen nötigen Kontext mit – das Modell sieht das Gespräch nicht. Daten verlassen dabei den Mac.",
                         parameters: schema([("question", "string", "Frage oder Auftrag"),
                                             ("context", "string", "Relevanter Kontext: Code, Fakten, bisherige Ergebnisse")],
                                            required: ["question"]),
                         needsApproval: true, source: "Cloud-Experte") { args in
            let q = try BuiltinTools.string(args, "question")
            let ctx = args["context"] as? String ?? ""
            return try await LLMClient.collect(model: model,
                system: "Du berätst einen lokalen KI-Agenten. Antworte präzise, strukturiert und handlungsorientiert, in der Sprache der Frage.",
                prompt: ctx.isEmpty ? q : "\(q)\n\n--- Kontext ---\n\(ctx)")
        }
    }

    private var subAgentTool: AgentTool {
        let agents = plugins.agents
        let model = selectedModelID
        let ws = session.workspace
        let readOnly = (BuiltinTools.files { ws } + BuiltinTools.web()).filter { BuiltinTools.readOnly.contains($0.name) }
        return AgentTool(name: "run_agent",
                         description: "Gibt eine abgeschlossene Teilaufgabe an einen spezialisierten Sub-Agenten (nur lesende Werkzeuge) und liefert dessen Bericht.",
                         parameters: schema([("agent", "string", "Name des Sub-Agenten"), ("task", "string", "Vollständige Aufgabenbeschreibung")],
                                            required: ["agent", "task"]),
                         needsApproval: false, source: "Sub-Agenten") { args in
            let name = args["agent"] as? String ?? ""
            guard let agent = agents.first(where: { $0.name == name }) else {
                throw ToolError.invalid("Sub-Agent '\(name)' gibt es nicht. Verfügbar: \(agents.map(\.name).joined(separator: ", "))")
            }
            let system = agent.prompt + "\n\nArbeitsordner: \(ws.path). Du kannst nur lesen (Dateien, Web). Schließe mit einem klaren Bericht ab."
            return try await AgentSession.runSubAgent(model: model, system: system,
                                                      task: try BuiltinTools.string(args, "task"), tools: readOnly, maxSteps: 12)
        }
    }

    // MARK: Ablauf

    private var booted = false

    func bootOnce() async {
        guard !booted else { return }
        booted = true
        await server.probe()
        await mcp.connectAll()
        await mcp.setPluginServers(plugins.mcpServers)
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await server.probe()
            }
        }
    }

    /// Nach Änderungen an Plugins: Skills/Befehle neu einlesen und Plugin-MCP-Server abgleichen.
    func pluginsChanged() async {
        plugins.reload()
        await mcp.setPluginServers(plugins.mcpServers)
    }

    func download(_ model: ModelInfo) {
        downloads.start(model) { [weak self] in
            self?.installGeneration += 1
            if self?.selectedModel?.isInstalled != true { self?.selectedModelID = model.id }
        }
    }

    func moveToTrash(_ model: ModelInfo) {
        try? FileManager.default.trashItem(at: model.folder, resultingItemURL: nil)
        installGeneration += 1
    }

    func setAcceleration(_ acc: Acceleration, for model: ModelInfo) async {
        try? ModelSettingsStore.setAcceleration(acc, for: model.id)
        installGeneration += 1
        if server.state == .running { await server.restart() }
    }

    /// Letzte Entscheidung des Routers (für die Anzeige im Chat).
    private(set) var lastRoute: (topic: ModelRouter.Topic, model: String)?

    func send() {
        session.send(model: routedModel(), tools: agentTools, context: agentContext)
    }

    /// Ohne Router: das gewählte Modell. Mit Router: das Modell für das Thema der Nachricht, sofern installiert.
    func routedModel() -> String {
        guard settings.routerEnabled else { lastRoute = nil; return selectedModelID }
        var topic = ModelRouter.classify(session.input, hasImages: !session.attachments.isEmpty,
                                         isCommand: session.input.hasPrefix("/"))
        // Bilder im Verlauf verstehen nur Vision-Modelle – dann dabei bleiben.
        if session.hasImagesInHistory { topic = .vision }
        let wanted = settings.routes[topic.rawValue] ?? ""
        let usable = !wanted.isEmpty && (CloudModels.isCloud(wanted) || ModelCatalog.model(id: wanted)?.isInstalled == true)
        let model = usable ? wanted : selectedModelID
        lastRoute = (topic, model)
        return model
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    var appExecutablePath: String {
        Bundle.main.executableURL?.path ?? "/Applications/Local AI.app/Contents/MacOS/Local AI"
    }
}
