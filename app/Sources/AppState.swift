import AppKit
import Foundation
import Observation

@MainActor @Observable
final class AppState {
    static let shared = AppState()

    private(set) var hardware = Hardware.detect()
    let server = ServerController()
    let downloads = Downloads()
    let mcp = MCPManager()
    let plugins = PluginManager()
    let settings = AppSettings()
    let session = AgentSession()
    let voice = VoiceController()
    let installer = EngineInstaller()
    let knowledge = KnowledgeBase()
    let automations = AutomationCenter()
    let usage = UsageMonitor()
    let assistants = AssistantStore()

    // MARK: Gesprächsmodus
    enum TalkPhase: Equatable { case off, listening, thinking, speaking }
    private(set) var talkPhase: TalkPhase = .off
    var talkMode: Bool { talkPhase != .off }

    var selectedModelID: String {
        didSet { UserDefaults.standard.set(selectedModelID, forKey: "selectedModel") }
    }
    /// Wird erhöht, wenn sich installierte Modelle ändern, damit die Ansichten neu prüfen.
    private(set) var installGeneration = 0
    var useBuiltinTools = true
    /// Bitte an die Oberfläche, einen Bereich zu zeigen (z. B. wenn ein Auftrag von außen kommt).
    var requestedScreen: Screen?
    /// Kurzer Hinweis oben im Agent-Tab (verschwindet nach einigen Sekunden).
    var notice: String?
    var useWebTools = true

    init() {
        let hw = Hardware.detect()
        let rec = ModelCatalog.recommended(for: hw)
        selectedModelID = UserDefaults.standard.string(forKey: "selectedModel")
            ?? ModelCatalog.all.first { $0.isInstalled && $0.fits(hw) }?.id
            ?? rec?.id ?? ModelCatalog.all[1].id
        // oMLX rechnet in GiB; knapp unter dem Metal-Limit bleiben (24-GB-Mac: 17,7).
        let limitGiB = hw.gpuLimitGB * 1e9 / 1_073_741_824
        server.memoryCeilingGiB = ((limitGiB - 0.05) * 10).rounded(.down) / 10
        BundledSkills.installIfNeeded()
        Task { await DevEnvironment.detect() }
        session.onFinish = { [weak self] text in
            guard let self else { return }
            if self.talkMode {
                self.talkPhase = .speaking
                self.voice.speak(text)
            } else if self.settings.readAloud {
                self.voice.speak(text)
            }
        }
        voice.onTranscript = { [weak self] text in self?.session.input = text }
        automations.runner = { [weak self] a in
            guard let self else { return "" }
            return try await self.runAutomation(a)
        }
        automations.speak = { [weak self] text in self?.voice.speak(text) }
        voice.onUtterance = { [weak self] text in self?.talkSend(text) }
        voice.onSpeechFinished = { [weak self] in
            guard let self, self.talkPhase == .speaking else { return }
            self.talkListen()
        }
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
        if useBuiltinTools {
            tools.append(Documents.tool({ [weak self] in self?.session.workspace ?? Paths.home }) { [weak self] url in
                self?.session.preview.show(url)
            })
            tools.append(Transcription.tool { [weak self] in self?.session.workspace ?? Paths.home })
            tools.append(Documents.canvasTool({ [weak self] in self?.session.workspace ?? Paths.home }) { [weak self] url in
                self?.session.preview.openCanvas(url)
            })
        }
        if settings.pimEnabled { tools += PIMTools.all() }
        if knowledge.chunkCount > 0 { tools.append(knowledge.tool()) }
        if settings.screenEnabled { tools.append(ScreenCapture.lookTool { [weak self] in self?.visionModelID }) }
        if !plugins.skills.isEmpty { tools.append(skillTool) }
        if !plugins.agents.isEmpty { tools.append(subAgentTool) }
        if !settings.expertModel.isEmpty { tools.append(expertTool) }
        return tools + mcp.tools
    }

    /// `kilokal://agent?projekt=Name&vorschau=1` (oder `vorschau=/pfad/datei.html`), `kilokal://modelle` …
    /// – Bereich zeigen, im Agent-Tab auch Projekt und Vorschau.
    func open(link url: URL) {
        guard url.scheme == "kilokal", let screen = Screen(link: url.host() ?? "") else { return }
        requestedScreen = screen
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ names: String...) -> String? { query.first { names.contains($0.name) }?.value }
        if value("engine") == "start" { Task { _ = await ensureEngine() } }
        if screen == .agent {
            if let name = value("projekt", "project") {
                let p = session.projects.projects.first { $0.name.lowercased() == name.lowercased() }
                if p != nil || ["allgemein", "ohne", "keins"].contains(name.lowercased()) { session.switchProject(p) }
            }
            if let id = value("chat", "gespraech") { session.load(id: id) }
            if let v = value("vorschau", "preview") {
                let path = (v as NSString).expandingTildeInPath
                if path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) {
                    session.preview.show(URL(fileURLWithPath: path))
                    if value("bearbeiten", "edit") == "1" { session.preview.editing = true }
                } else {
                    session.preview.isOpen = v == "1" || v == "true"
                }
            }
        }
        NSApp.activate()
    }

    // MARK: Skills aus Gesprächen

    /// Entwurf einer SKILL.md aus einem gespeicherten Gespräch (Ablauf, Werkzeuge, Stolperfallen).
    func draftSkill(fromChat id: String) async throws -> String {
        guard let json = ChatStore.load(id: id) else { throw ToolError.invalid("Gespräch nicht gefunden") }
        var transcript = ""
        for item in json["items"] as? [[String: Any]] ?? [] {
            switch item["k"] as? String {
            case "user": transcript += "\n\n[Nutzer] " + String((item["text"] as? String ?? "").prefix(2000))
            case "assistant":
                let t = item["text"] as? String ?? ""
                if !t.isEmpty { transcript += "\n\n[Agent] " + String(t.prefix(1500)) }
            case "tool":
                transcript += "\n[Werkzeug \(item["name"] as? String ?? "?") – \(item["state"] as? String ?? "")] "
                    + String((item["args"] as? String ?? "").prefix(300)).replacingOccurrences(of: "\n", with: " ")
            default: break
            }
            if transcript.count > 14_000 { transcript += "\n…"; break }
        }
        let system = """
        Du schreibst Skills für einen KI-Agenten (Format wie bei Claude Code). Ein Skill ist eine wiederverwendbare \
        Schritt-für-Schritt-Anleitung, gewonnen aus einem erfolgreichen Gespräch. Gib NUR den Inhalt einer SKILL.md aus:
        ---
        name: kurzer-name-in-kebab-case
        description: Nutzen, wenn … (ein Satz, wann der Skill passt)
        ---
        # Titel
        ## Wann verwenden
        ## Schritte
        (nummeriert und konkret: welche Werkzeuge, Befehle, Prüfungen)
        ## Ergebnis prüfen
        ## Stolperfallen
        (was im Gespräch schiefging und wie man es vermeidet)
        Verallgemeinere: keine einmaligen Details, außer sie gehören zum Ablauf. Schreibe auf Deutsch.
        """
        var md = try await LLMClient.collect(model: selectedModelID, system: system,
                                             prompt: "Gespräch:\n\(transcript)\n\nSchreibe jetzt die SKILL.md.", maxTokens: 2500)
        md = md.trimmingCharacters(in: .whitespacesAndNewlines)
        if md.hasPrefix("```") {
            md = md.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if md.hasSuffix("```") { md = String(md.dropLast(3)) }
        }
        if let start = md.range(of: "---") { md = String(md[start.lowerBound...]) }
        return md.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// SKILL.md speichern (~/.kilokal/skills/<name>/) und Skills neu einlesen. Liefert den Namen.
    func saveSkill(markdown: String) throws -> String {
        guard let m = markdown.firstMatch(of: /(?m)^name:\s*(.+)$/) else {
            throw ToolError.invalid("Im Kopf fehlt „name: …“")
        }
        let base = String(m.1).lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "ä", with: "ae").replacingOccurrences(of: "ö", with: "oe")
            .replacingOccurrences(of: "ü", with: "ue").replacingOccurrences(of: "ß", with: "ss")
            .replacing(/[^a-z0-9]+/, with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !base.isEmpty else { throw ToolError.invalid("Ungültiger Name") }
        var name = base, n = 2
        while FileManager.default.fileExists(atPath: PluginManager.skillsDir.appendingPathComponent(name).path) {
            name = "\(base)-\(n)"; n += 1
        }
        let dir = PluginManager.skillsDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = markdown.replacingOccurrences(of: "name: \(m.1)", with: "name: \(name)")
        try text.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        plugins.reload()
        return name
    }

    /// Werkzeuge des aktuellen Modus im Agent-Tab (Chat · Arbeiten · Code).
    var modeTools: [AgentTool] { agentTools.filter(session.mode.allows) }

    var agentContext: AgentContext {
        var c = AgentContext(skills: plugins.skills, agents: plugins.agents, commands: plugins.commands,
                             customInstructions: settings.customInstructions,
                             maxSteps: settings.maxSteps, maxTokens: settings.maxTokens)
        c.selfDescription = selectedIsCloud
            ? "Du bist \(selectedModelName) (Cloud) und arbeitest in der Mac-App KI/lokal von KIsruptiv."
            : "Du bist \(selectedModelName) und läufst über die App KI/lokal von KIsruptiv vollständig lokal auf diesem Mac "
              + "(\(hardware.chip), \(hardware.memoryGiB) GB Arbeitsspeicher) – ohne Cloud."
        return c
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
        automations.start()
        AgentHandoff.listen(self)
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

    /// GPU-Speichergrenze anheben (macOS fragt nach dem Administrator-Passwort; gilt bis zum Neustart).
    /// `mb == 0` setzt den Standard wieder her.
    func setGPULimit(mb: Int) async -> String? {
        let script = "do shell script \"/usr/sbin/sysctl iogpu.wired_limit_mb=\(mb)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { return error[NSAppleScript.errorMessage] as? String ?? "Abgebrochen" }
        hardware = Hardware.detect()
        let limitGiB = hardware.gpuLimitGB * 1e9 / 1_073_741_824
        server.memoryCeilingGiB = ((limitGiB - 0.05) * 10).rounded(.down) / 10
        if server.state == .running { await server.restart() }
        return nil
    }

    /// Führt eine geplante Aufgabe unbeaufsichtigt aus: Engine bei Bedarf starten, passende Werkzeuge, kein Nachfragen.
    func runAutomation(_ a: Automation) async throws -> String {
        if !selectedIsCloud && !server.state.isUp {
            guard server.engineInstalled else { throw ToolError.invalid("Engine ist nicht eingerichtet") }
            server.start()
            for _ in 0..<240 where !server.state.isUp { try await Task.sleep(for: .milliseconds(500)) }
            guard server.state.isUp else { throw ToolError.invalid("Server startet nicht") }
        }
        let ws = { [session] in session.workspace }
        var tools = (BuiltinTools.files(ws) + BuiltinTools.web()).filter { BuiltinTools.readOnly.contains($0.name) }
        tools += SystemTools.all().filter { ["notify", "clipboard_read", "remember"].contains($0.name) }
        if knowledge.chunkCount > 0 { tools.append(knowledge.tool()) }
        if settings.pimEnabled {
            tools += PIMTools.all().filter { ["calendar_events", "reminders_list", "contacts_search", "mail_recent"].contains($0.name) }
        }
        if a.allowActions {
            tools += BuiltinTools.files(ws).filter { !BuiltinTools.readOnly.contains($0.name) }
            tools += SystemTools.all().filter { $0.name == "http_request" }
            if settings.pimEnabled { tools += PIMTools.all().filter { ["calendar_create", "reminders_create", "mail_draft"].contains($0.name) } }
            if settings.browserEnabled { tools += BrowserTools.all() }
        }
        tools += mcp.tools.filter { _ in a.allowActions }
        let memory = SystemTools.memory().trimmingCharacters(in: .whitespacesAndNewlines)
        let system = """
        Du bist KI/lokal und führst die geplante Aufgabe „\(a.name)“ unbeaufsichtigt aus. Heute ist \(Date().formatted(date: .complete, time: .shortened)).
        Es gibt keine Rückfragen an den Nutzer: nutze die Werkzeuge, erfinde nichts und liefere am Ende das fertige Ergebnis auf Deutsch.
        \(memory.isEmpty ? "" : "Was du über den Nutzer weißt:\n\(memory.suffix(3000))")
        \(settings.customInstructions)
        """
        return try await AgentSession.runSubAgent(model: selectedModelID, system: system, task: a.prompt, tools: tools, maxSteps: 16,
                                                  logContext: "Automation: \(a.name)")
    }

    /// Vision-Modell für Bilder: das gewählte (falls es Bilder kann), sonst Router-Ziel oder erstes installiertes.
    var visionModelID: String? {
        if selectedModel?.vision == true || selectedIsCloud { return selectedModelID }
        if let routed = settings.routes[ModelRouter.Topic.vision.rawValue], !routed.isEmpty { return routed }
        return installedModels.first { $0.vision }?.id
    }

    func toggleTalkMode() {
        if talkMode {
            talkPhase = .off
            voice.pauseInterval = nil
            voice.stopListening()
            voice.stopSpeaking()
        } else {
            talkListen()
        }
    }

    private func talkListen() {
        talkPhase = .listening
        voice.pauseInterval = 1.4
        session.input = ""
        voice.startListening(currentText: "")
    }

    /// Für den Selbsttest: einen Gesprächszug ohne Mikrofon auslösen.
    func simulateTalkTurn(_ text: String) {
        talkPhase = .thinking
        talkSend(text)
    }

    /// Fertige Äußerung: ggf. Bildschirm anhängen („schau auf meinen Bildschirm“), abschicken, auf Antwort warten.
    private func talkSend(_ text: String) {
        guard talkMode else { return }
        talkPhase = .thinking
        Task {
            let lower = text.lowercased()
            if settings.screenEnabled, ["bildschirm", "was siehst du", "schau mal", "screenshot"].contains(where: lower.contains),
               let jpeg = try? await ScreenCapture.capture(.screen) {
                session.attachments.append(jpeg)
            }
            guard await ensureEngine() else { talkListen(); return }
            session.input = text
            send()
            // Kein Text zurück (Fehler/Abbruch)? Dann weiter zuhören.
            while session.isRunning { try? await Task.sleep(for: .milliseconds(200)) }
            if talkPhase == .thinking { talkListen() }
        }
    }

    /// Empfohlener Wert: ~83 % des Arbeitsspeichers für die GPU (24 GB → 20 GB), Rest für macOS.
    var recommendedGPULimitMB: Int { Int(Double(hardware.memoryGiB) * 1024 * 0.83) }

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

    /// Senden geht, sobald eine Engine installiert ist – läuft sie nicht, startet `send()` sie vorher.
    var canSendOrStart: Bool { canSend || server.engineInstalled }

    /// Engine bereit machen: läuft sie schon (auch von außen gestartet), sofort true; sonst starten und warten.
    func ensureEngine() async -> Bool {
        if canSend { return true }
        guard server.engineInstalled else { return false }
        await server.probe()
        if !server.state.isUp { server.start() }   // tut nichts, wenn sie schon startet
        for _ in 0..<240 where !server.state.isUp {
            try? await Task.sleep(for: .milliseconds(500))
            await server.probe()
        }
        return server.state.isUp
    }

    func send(adjust: @escaping (inout AgentContext) -> Void = { _ in }) {
        if !canSend && server.engineInstalled {
            // Engine automatisch starten und danach abschicken (Eingabe bleibt bis dahin stehen).
            Task { if await ensureEngine() { send(adjust: adjust) } }
            return
        }
        if voice.isListening { voice.stopListening() }
        let model = routedModel()
        var context = agentContext
        context.spoken = talkMode
        // MTP "Automatisch": nur bei Code-Aufgaben spekulieren (Header X-oMLX-MTP).
        if ModelSettingsStore.acceleration(for: model) == .auto {
            switch session.mode {
            case .chat: context.mtp = false
            case .code: context.mtp = true
            case .work:
                context.mtp = ModelRouter.classify(session.input, hasImages: false, isCommand: session.input.hasPrefix("/")) == .code
            }
        }
        // Code-Projekte schreiben ganze Dateien in einer Antwort – dafür mehr Platz (der Kontext reicht auf 24 GB für ~29k).
        if session.mode == .code { context.maxTokens = max(context.maxTokens, 16_384) }
        adjust(&context)
        session.send(model: model, tools: modeTools, context: context)
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
        Bundle.main.executableURL?.path ?? "/Applications/KI lokal.app/Contents/MacOS/KI lokal"
    }
}
