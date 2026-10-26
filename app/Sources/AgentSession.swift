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
    /// MTP-Spekulation für diese Aufgabe (bei "Automatisch" nur für Code).
    var mtp = true
    /// Gesprächsmodus: Antwort wird vorgelesen.
    var spoken = false
    /// Wer und wo das Modell ist (Modellname, Chip, Arbeitsspeicher) – damit es Fragen zu sich selbst beantworten kann.
    var selfDescription = ""
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
    /// Angehängte Dateien (PDF, Word, Excel, PowerPoint, Text, ZIP, alles andere) für die nächste Nachricht.
    var documents: [URL] = []
    /// Projekte gruppieren Gespräche; nil = ohne Projekt.
    let projects = ProjectStore()
    private(set) var project: Project?
    /// Arbeitsweise (Werkzeuge, Systemprompt, MTP) – aus dem Projekt abgeleitet, siehe Project.mode.
    private(set) var mode: WorkMode = .work
    @ObservationIgnored private var applyingProject = false
    /// Einmalig vorgegebene Arbeitsweise (z. B. `--mode` im Terminal); gilt bis zum nächsten Projekt- oder Gesprächswechsel.
    var modeOverride: WorkMode? { didSet { refreshMode() } }
    var thinking = false
    /// Vorschau-Panel neben dem Chat.
    let preview = PreviewStore()
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
    /// Tatsächliche Eingabelänge der letzten Anfrage (laut Engine), 0 = noch unbekannt.
    private(set) var lastPromptTokens = 0
    /// Kontextfenster der lokalen Engine (oMLX `max_context_window`, zählt nur die Eingabe).
    static let localWindow = 32_768
    /// Ab hier verdichten: Platz für die nächste Antwort samt Werkzeug-Ergebnis (≤ 6 000 Zeichen) muss bleiben.
    static let compactAtTokens = 24_000
    /// Beginn des aktuellen Modell-Schritts – für die Anzeige „liest Eingabe … 12 s“.
    private(set) var stepStarted: Date?
    private(set) var chatID = UUID().uuidString
    private(set) var historyVersion = 0
    /// Wird nach jeder fertigen Antwort mit deren Text aufgerufen (z. B. zum Vorlesen).
    var onFinish: ((String) -> Void)?

    /// Arbeitsordner: der Ordner des Projekts, ohne Projekt ~/Dokumente/KI lokal (änderbar).
    var workspace: URL {
        didSet {
            guard workspace != oldValue, !applyingProject else { return }
            if var p = project {
                p.folder = workspace.path
                projects.upsert(p)
                project = p
                refreshMode()
            } else {
                UserDefaults.standard.set(workspace.path, forKey: "workspace")
            }
        }
    }

    private var history: [[String: Any]] = []
    /// In diesem Auftrag geänderte Dateien (für den Qualitäts-Check vor „fertig“).
    @ObservationIgnored private var changedFiles: [URL] = []
    @ObservationIgnored private var reviews = 0
    @ObservationIgnored private var lastReviewFailed = false
    @ObservationIgnored private var nudges = 0
    @ObservationIgnored private var recentCalls: [String] = []
    @ObservationIgnored private var userTask = ""
    static let qualityPrefix = "Qualitäts-Check"

    /// Ungefähre Länge des Verlaufs in Zeichen (für die Kontext-Anzeige; ≈ Zeichen / 3,5 Tokens).
    var contextChars: Int { Self.totalLength(history) }

    /// Dateien, die der Agent in diesem Gespräch erstellt oder geändert hat (neueste zuerst, ohne Doppelte).
    var outputs: [URL] {
        var seen = Set<String>(), out: [URL] = []
        for item in items.reversed() {
            guard case let .tool(name, _, args, .done, _) = item.kind else { continue }
            let url: URL?
            if let u = PreviewStore.writtenPath(tool: name, arguments: args, workspace: workspace) { url = u }
            else if ["create_document", "open_canvas"].contains(name),
                    let p = (try? JSONSerialization.jsonObject(with: Data(args.utf8)) as? [String: Any])?["path"] as? String {
                url = BuiltinTools.resolve(p, in: workspace)
            } else { url = nil }
            if let url, FileManager.default.fileExists(atPath: url.path), seen.insert(url.path).inserted { out.append(url) }
        }
        return out
    }

    /// Erfolgreiche Werkzeug-Aufrufe im Gespräch – ab einigen lohnt sich der Vorschlag „Als Skill speichern“.
    var successfulToolCalls: Int {
        items.filter { if case .tool(_, _, _, .done, _) = $0.kind { return true }; return false }.count
    }

    var hasImagesInHistory: Bool {
        items.contains { if case let .user(_, imgs) = $0.kind { return !imgs.isEmpty }; return false }
    }
    private var runTask: Task<Void, Never>?
    private var approvals: [UUID: CheckedContinuation<Bool, Never>] = [:]

    /// Ordner für Gespräche ohne Projekt (dort landen auch erzeugte Dokumente).
    static let defaultWorkspace = Paths.home.appendingPathComponent("Documents/KI lokal")

    init() {
        let d = UserDefaults.standard
        // Frühere Versionen haben hier den Ordner des letzten Terminal-Auftrags gespeichert → einmalig zurücksetzen.
        if !d.bool(forKey: "workspaceV2") {
            d.removeObject(forKey: "workspace")
            d.set(true, forKey: "workspaceV2")
        }
        try? FileManager.default.createDirectory(at: Self.defaultWorkspace, withIntermediateDirectories: true)
        workspace = Self.generalWorkspace
        let saved = UserDefaults.standard.string(forKey: "project").flatMap(UUID.init(uuidString:))
        project = projects.project(id: saved)
        if let folder = project?.folderURL { workspace = folder }
        refreshMode()
    }

    private static var generalWorkspace: URL {
        UserDefaults.standard.string(forKey: "workspace").map { URL(fileURLWithPath: $0) } ?? defaultWorkspace
    }

    /// Arbeitsweise neu bestimmen (der Ordner kann sich inzwischen mit Code gefüllt haben).
    func refreshMode() {
        mode = modeOverride ?? project?.mode ?? .work
    }

    /// Projekt (nil = ohne Projekt) setzen, ohne das Gespräch anzufassen.
    private func apply(project p: Project?) {
        project = p
        modeOverride = nil
        UserDefaults.standard.set(p?.id.uuidString, forKey: "project")
        let target = p?.folderURL ?? Self.generalWorkspace
        if workspace != target {
            applyingProject = true
            workspace = target
            applyingProject = false
        }
        if let p { projects.touch(p.id) }
        refreshMode()
    }

    /// Projektwechsel beginnt ein neues Gespräch (das alte bleibt im Verlauf des alten Projekts).
    func switchProject(_ p: Project?) {
        guard !isRunning else { return }
        if p?.id != project?.id || !items.isEmpty { reset() }
        apply(project: p)
    }

    /// Projekt-Einstellungen übernehmen (Name, Ordner, Art, Anweisungen).
    func updateProject(_ p: Project) {
        projects.upsert(p)
        if p.id == project?.id { apply(project: p) }
    }

    func deleteProject(_ p: Project) {
        projects.remove(p)
        if p.id == project?.id { switchProject(nil) }
    }

    /// „Neues Gespräch“ aus der Oberfläche: auch eine einmalige Vorgabe (--mode) endet hier.
    func newChat() {
        reset()
        modeOverride = nil
    }

    func reset() {
        stop()
        items = []
        history = []
        lastPromptTokens = 0
        chatID = UUID().uuidString
        customTitle = nil
        angeheftet = false
        preview.clear()
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
        guard !text.isEmpty || !attachments.isEmpty || !documents.isEmpty, !isRunning else { return }
        refreshMode()
        if text.isEmpty { text = documents.isEmpty ? "Was ist auf dem Bild zu sehen?" : "Fasse die angehängten Dateien zusammen." }
        input = ""
        let images = attachments
        attachments = []
        let files = documents
        documents = []
        var shown = text
        if !files.isEmpty {
            shown += "\n" + files.map { "📎 \($0.lastPathComponent)" }.joined(separator: "\n")
            // Platz im Kontext aufteilen: zusammen höchstens ~24 000 Zeichen (~7 000 Tokens).
            let limit = max(3000, 24_000 / files.count)
            text += "\n\n" + files.map { Documents.attachmentText($0, limit: limit) }.joined(separator: "\n\n")
        }
        // Slash-Befehl: "/name argumente" → Vorlage des Befehls
        if text.hasPrefix("/") {
            let parts = text.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
            if let cmd = context.commands.first(where: { $0.name == parts.first }) {
                text = cmd.expand(parts.count > 1 ? parts[1] : "")
            }
        }
        // Systemprompt bei jeder Nachricht aktualisieren (Werkzeuge, Skills oder Gesprächsmodus können sich ändern);
        // bleibt er gleich, nutzt der Prompt-Cache weiter denselben Anfang.
        let system: [String: Any] = ["role": "system", "content": systemPrompt(tools: tools, context: context)]
        if history.isEmpty { history.append(system) } else if history[0]["role"] as? String == "system" { history[0] = system }
        items.append(Item(kind: .user(shown, images: images)))
        if images.isEmpty {
            history.append(["role": "user", "content": text])
        } else {
            let parts: [[String: Any]] = [["type": "text", "text": text]] + images.map {
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\($0.base64EncodedString())"]]
            }
            history.append(["role": "user", "content": parts])
        }
        changedFiles = []
        reviews = 0
        lastReviewFailed = false
        nudges = 0
        recentCalls = []
        userTask = String(shown.prefix(1500))
        isRunning = true
        runTask = Task {
            await loop(model: model, tools: tools, context: context)
            isRunning = false
            liveTokPerSec = 0
            save()
            if !Task.isCancelled, case let .assistant(text, _, _)? = items.last?.kind, !text.isEmpty { onFinish?(text) }
        }
    }

    // MARK: Systemprompt

    private func systemPrompt(tools: [AgentTool], context: AgentContext) -> String {
        var s = """
        Du bist ein hilfreicher, gründlicher Assistent, der lokal auf dem Mac des Nutzers läuft. \
        Antworte in der Sprache des Nutzers – auch in Zwischenbemerkungen zwischen Werkzeug-Aufrufen. Heute ist \(Date().formatted(date: .complete, time: .omitted)).
        \(context.selfDescription)
        """
        if mode == .chat {
            s += "\n\nChat-Modus: Antworte direkt und im Gesprächston. Werkzeuge nur, wenn sie wirklich nötig sind – für aktuelle Fakten web_search/fetch_url (mit Links), für Unterlagen des Nutzers search_documents."
        } else if !tools.isEmpty {
            s += """


            Du arbeitest als Agent mit Werkzeugen. Arbeitsordner: \(workspace.path)
            - Plane kurz, nutze Werkzeuge gezielt und prüfe Ergebnisse, statt zu raten. Erfinde keine Dateiinhalte oder Fakten.
            - Für aktuelle Informationen: web_search, dann die besten Quellen mit fetch_url lesen und mit Links belegen.
            - Für Code: erst lesen (read_file, search_files, find_files), dann gezielt ändern (edit_file).
            - Anleitungen für Claude Code nennen Werkzeuge wie Read, Write, Edit, Bash, Grep, Glob, WebFetch, WebSearch, Task – \
            nutze dafür read_file, write_file, edit_file, run_shell, search_files, find_files, fetch_url, web_search, run_agent.
            """
            if !DevEnvironment.summary.isEmpty {
                s += "\n- Verfügbare Programme auf diesem Mac (genau diese Pfade nutzen, nicht suchen):\n" + DevEnvironment.summary
            }
            s += "\n- Nach jedem write_file/edit_file prüft die App die Datei automatisch (Syntax; HTML-Seiten im Browser) und hängt den Befund an die Werkzeug-Antwort an. Bei ❌ zuerst diesen Fehler beheben."
            if mode == .code {
                s += """

                - Code-Modus: Der Arbeitsordner ist das Projekt. Erst Aufbau verstehen (list_directory, find_files, read_file), \
                dann in kleinen Schritten ändern statt ganze Dateien neu zu schreiben: kleine Stellen mit edit_file, ganze Blöcke \
                oder Funktionen mit replace_lines (Zeilennummern aus read_file).
                - Gibt es einen Ordner tests/ (test_*.js, test_*.py), führe die Tests nach jeder Änderung aus (node tests/test_x.js) \
                und arbeite, bis alle grün sind – die App prüft das vor „fertig“ noch einmal.
                - Große Dateien (über ~300 Zeilen) in Teilen schreiben: write_file mit dem ersten Teil, dann edit_file für weitere Teile.
                - Nach jeder Änderung prüfen (Build, Tests, Linter oder Syntax-Check mit run_shell) und Fehler beheben, bevor du fertig meldest.
                - Zum Schluss kurz: was du geändert hast und wie man es startet oder testet.
                """
            }
            s += "\n- Angehängte Dateien stehen schon in der Nachricht (zwischen <dokument>-Tags) – nicht erneut lesen, direkt damit arbeiten. Nur wenn dort „gekürzt“ steht, den Rest mit read_file holen."
            if tools.contains(where: { $0.name == "open_canvas" }) {
                s += "\n- Texte, die der Nutzer weiterbearbeiten will (Entwurf, Brief, Konzept, „als Canvas“, „editierbar“): mit open_canvas öffnen statt nur in den Chat schreiben. Der Nutzer kann im Canvas selbst ändern – vor eigenen Änderungen read_file."
            }
            if tools.contains(where: { $0.name == "create_document" }) {
                s += "\n- Dokumente (PDF, Word, Excel) mit create_document erzeugen – Inhalt als Markdown, Tabellen als | Markdown-Tabelle |."
            }
            if tools.contains(where: { $0.name == "search_documents" }) {
                s += "\n- Eigene Dokumente des Nutzers: bei Fragen zu seinen Unterlagen, Projekten oder Notizen zuerst search_documents nutzen und die Datei als Quelle nennen."
            }
            if tools.contains(where: { $0.name == "calendar_events" }) {
                s += "\n- Kalender/Erinnerungen/Kontakte/Mail: Zeiten immer als ISO in Ortszeit (\(TimeZone.current.identifier)). Mails nur als Entwurf (mail_draft)."
            }
            if tools.contains(where: { $0.name == "browser_read" }) {
                s += "\n- Browser des Nutzers: erst browser_tabs/browser_read, dann mit den Nummern [n] browser_click/browser_type. Nach jeder Aktion den neuen Zustand prüfen. Keine Käufe, Zahlungen, Logins oder Nachrichten ohne ausdrückliche Bitte des Nutzers."
            }
            if !context.skills.isEmpty {
                s += "\n\n## Skills\nWenn eine Aufgabe zu einem Skill passt, lade ihn ZUERST mit use_skill und folge seiner Anleitung.\n"
                // Im Code-Projekt knapp halten: jedes Zeichen im Systemprompt kostet Speicher bei jeder Anfrage.
                if mode == .code {
                    s += "Verfügbar (Name genügt für use_skill): " + context.skills.prefix(40).map(\.name).joined(separator: ", ") + "\n"
                } else {
                    for sk in context.skills.prefix(80) { s += "- \(sk.name): \(sk.description.prefix(240))\n" }
                }
            }
            if !context.agents.isEmpty {
                s += "\n## Sub-Agenten (über run_agent)\n"
                for a in context.agents.prefix(40) { s += "- \(a.name): \(a.description.prefix(200))\n" }
            }
        }
        let memory = SystemTools.memory().trimmingCharacters(in: .whitespacesAndNewlines)
        if tools.contains(where: { $0.name == "remember" }) {
            s += "\n\n## Gedächtnis\nMit remember/forget pflegst du dauerhafte Notizen über den Nutzer."
            if !memory.isEmpty { s += " Bisher gemerkt:\n\(memory.suffix(4000))" }
        }
        if context.spoken {
            s += "\n\n## Gesprächsmodus\nDeine Antwort wird vorgelesen. Antworte natürlich, kurz (meist 1–4 Sätze) und ohne Tabellen, Code-Blöcke, Aufzählungszeichen oder Links. Wenn du Werkzeuge nutzt, fasse das Ergebnis mündlich zusammen."
        }
        if let project {
            s += "\n\n## Projekt „\(project.name)“"
            if let folder = project.folder { s += "\nProjektordner: \(folder)" }
            if !project.instructions.isEmpty { s += "\n\(project.instructions)" }
        }
        if !context.customInstructions.isEmpty {
            s += "\n\n## Anweisungen des Nutzers\n\(context.customInstructions)"
        }
        return s
    }

    // MARK: Agent-Schleife

    private func loop(model: String, tools: [AgentTool], context: AgentContext) async {
        let specs = tools.map(\.openAISpec)
        var memoryRetries = 0
        for step in 0..<context.maxSteps {
            if Task.isCancelled { return }
            // Lokale Modelle: Verlauf rechtzeitig verdichten, damit die Eingabe in den Speicher passt (24 GB).
            let local = !CloudModels.isCloud(model)
            // Solange der Verlauf nur wächst, liest die Engine pro Schritt nur das Neue ein (Prefix-Cache) – so trägt das
            // 32k-Fenster auch auf 24 GB. Erst kurz vor dem Fenster verdichten, dann deutlich darunter (≈ 6k Tokens), damit
            // das einmalige Neu-Einlesen ohne Cache in den Speicher passt. Lehnt der Speicherwächter trotzdem ab
            // (kalter Cache, z. B. altes Gespräch wieder geöffnet), greift unten die Wiederholung mit Kürzen.
            if local, lastPromptTokens > Self.compactAtTokens || Self.totalLength(history) > 90_000 {
                compactHistory(budget: 9_000)
                lastPromptTokens = 0
            }
            let itemID = UUID()
            items.append(Item(id: itemID, kind: .assistant(text: "", thinking: "", stats: nil)))
            var text = "", thought = ""
            var calls: [LLMClient.ToolCall] = []
            var rawBlocks: [[String: Any]]?
            var completion = 0, prompt = 0
            let t0 = Date()
            stepStarted = t0
            var tFirst: Date?
            var chunks = 0
            var truncated = false

            do {
                for try await ev in LLMClient.stream(model: model, messages: history, tools: specs,
                                                     thinking: thinking, maxTokens: context.maxTokens, mtp: context.mtp) {
                    switch ev {
                    case let .content(c): text += c
                    case let .reasoning(r): thought += r
                    case let .toolCalls(c): calls = c; continue
                    case let .usage(p, c): prompt = p; completion = c; continue
                    case let .raw(b): rawBlocks = b; continue
                    case .truncated: truncated = true; continue
                    }
                    chunks += 1
                    let now = Date()
                    if tFirst == nil { tFirst = now }
                    if let f = tFirst, now.timeIntervalSince(f) > 0.3 {
                        liveTokPerSec = Double(chunks - 1) / now.timeIntervalSince(f)
                    }
                    setKind(itemID, .assistant(text: text, thinking: thought, stats: nil))
                }
            } catch {
                // Zu lange Eingabe für den Speicher? Stärker verdichten und den Schritt wiederholen.
                let message = error.localizedDescription
                if local, memoryRetries < 2, message.contains("memory guard") || message.contains("Prefill would require") {
                    memoryRetries += 1
                    items.removeAll { $0.id == itemID }
                    compactHistory(budget: memoryRetries == 1 ? 9_000 : 6_500, keepRecent: memoryRetries == 1 ? 3 : 2)
                    items.append(Item(kind: .error(Self.qualityPrefix + ": Verlauf war zu lang für den Speicher – ältere Schritte gekürzt, es geht weiter." + (memoryRetries == 2 ? " Tipp: „GPU-Speicher erhöhen“ in den Einstellungen gibt dem Modell deutlich mehr Platz." : ""))))
                    continue
                }
                if !Task.isCancelled { items.append(Item(kind: .error(message))) }
                return
            }

            let end = Date()
            let tokens = completion > 0 ? completion : chunks
            let decode = tFirst.map { end.timeIntervalSince($0) } ?? 0
            let stats = Stats(model: model, tokens: tokens, tokPerSec: decode > 0 ? Double(max(tokens - 1, 0)) / decode : 0,
                              promptTokens: prompt, ttft: (tFirst ?? end).timeIntervalSince(t0))
            if prompt > 0 { lastPromptTokens = prompt }
            memoryRetries = 0
            if text.isEmpty && thought.isEmpty && !calls.isEmpty {
                items.removeAll { $0.id == itemID }
            } else {
                setKind(itemID, .assistant(text: text, thinking: thought, stats: stats))
            }

            var assistant: [String: Any] = ["role": "assistant", "content": text]
            if !calls.isEmpty {
                assistant["tool_calls"] = calls.map {
                    ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]]
                }
            }
            if let rawBlocks { assistant["_anthropic_content"] = rawBlocks }
            history.append(assistant)
            let assistantIndex = history.count - 1
            if truncated {
                // Am Längenlimit abgeschnitten: nicht einfach aufhören, sondern in kleineren Teilen weitermachen lassen.
                items.append(Item(kind: .error("Antwort am Längenlimit (\(context.maxTokens) Tokens) abgeschnitten – der Agent macht in kleineren Teilen weiter.")))
                history.append(["role": "user", "content": "(Hinweis der App: Deine letzte Antwort wurde am Längenlimit von \(context.maxTokens) Tokens abgeschnitten; ein begonnener Werkzeug-Aufruf wurde verworfen. Teile große Inhalte auf: Datei zuerst mit write_file und dem ersten Teil anlegen, weitere Teile mit edit_file anhängen. Mach jetzt weiter.)"])
                continue
            }
            if calls.isEmpty {
                // Nur angekündigt („Ich starte …“, „Lass mich …“), aber nichts getan? Kleine Modelle beenden dann gern
                // den Zug. Bis zu zweimal erinnern, den Schritt wirklich auszuführen.
                if nudges < 3, mode != .chat, !tools.isEmpty, step < context.maxSteps - 1 {
                    if Self.asksForWhatToolsCanDo(text) {
                        nudges += 1
                        history.append(["role": "user", "content": "(Hinweis der App: Du hast Werkzeuge und kannst alles selbst holen – Dateien lesen (read_file, list_directory), Befehle ausführen (run_shell), im Web suchen. Frag den Nutzer nicht nach Inhalten, die du selbst lesen kannst. Mach den nächsten Schritt jetzt mit einem Werkzeug.)"])
                        continue
                    }
                    if Self.isAnnouncement(text) {
                        nudges += 1
                        history.append(["role": "user", "content": "(Hinweis der App: Du hast nur angekündigt, aber kein Werkzeug aufgerufen. Führe den nächsten Schritt jetzt direkt mit einem Werkzeug aus – nicht beschreiben, machen.)"])
                        continue
                    }
                }
                // Qualitäts-Check: Hat der Agent Code geändert, prüft die App alles noch einmal und lässt ihn
                // Befunde beheben, bevor er „fertig“ meldet – einmal pro Auftrag.
                // Einmal prüfen; waren Tests/Prüfungen rot, bis zu dreimal (sonst meldet das Modell „fertig“ trotz Fehlern).
                if reviews < (lastReviewFailed ? 3 : 1), !changedFiles.isEmpty, mode != .chat, step < context.maxSteps - 2 {
                    reviews += 1
                    var reports: [String] = []
                    for url in changedFiles { if let r = await CodeCheck.report(for: url) { reports.append(r) } }
                    if let tests = await CodeCheck.projectTests(in: workspace) { reports.append(tests) }
                    let failing = reports.contains { $0.hasPrefix("❌") || $0.contains("NICHT grün") }
                    lastReviewFailed = failing
                    items.append(Item(kind: .error(Self.qualityPrefix + (failing ? ": Fehler gefunden – der Agent behebt sie." : ": Prüfungen bestanden – letzter Blick auf Vollständigkeit und Texte."))))
                    history.append(["role": "user", "content": """
                        (Qualitäts-Check der App, bevor du fertig meldest)
                        Prüfergebnisse der geänderten Dateien:
                        \(reports.isEmpty ? "keine automatischen Prüfungen möglich" : reports.joined(separator: "\n"))

                        Ursprünglicher Auftrag: \(userTask)

                        Prüfe jetzt: 1) Sind alle Befunde oben behoben? 2) Ist jeder Punkt des Auftrags erfüllt? \
                        3) Stimmen sichtbare Texte (Tippfehler, Sprache, überlappende Beschriftungen, Startzustand)? \
                        Wenn etwas fehlt oder falsch ist: jetzt mit Werkzeugen beheben. Wenn alles stimmt: antworte nur mit einer \
                        kurzen Zusammenfassung auf Deutsch (was geändert wurde, wie man es startet).
                        """])
                    continue
                }
                return
            }

            for call in calls {
                if Task.isCancelled { return }
                var result = await execute(call, tools: tools)
                // Schleife? Derselbe Aufruf mit denselben Argumenten zum dritten Mal → Hinweis statt stur weiter
                let signatur = call.name + "|" + call.arguments
                recentCalls.append(signatur)
                if recentCalls.count > 6 { recentCalls.removeFirst() }
                if recentCalls.filter({ $0 == signatur }).count >= 3 {
                    result += "\n\n(Hinweis der App: Du rufst dieses Werkzeug zum dritten Mal mit genau denselben Argumenten auf – das Ergebnis ändert sich nicht. Ändere den Ansatz: anderes Werkzeug, andere Datei/Zeilen, oder fasse zusammen, was du weißt.)"
                    recentCalls.removeAll()
                }
                // Kurz vor dem Schrittlimit daran erinnern, zum Ende zu kommen.
                let left = context.maxSteps - step - 1
                if left <= 3 { result += "\n\n(Hinweis der App: noch \(left) Schritt\(left == 1 ? "" : "e") – bring die Aufgabe jetzt zu Ende.)" }
                history.append(["role": "tool", "tool_call_id": call.id, "content": local ? Self.capToolResult(result, tool: call.name) : result])
            }
            // Selbst geschriebene Dateiinhalte stehen jetzt auf der Platte – im Verlauf genügt ein Verweis.
            // Das ändert nur die letzte Nachricht, der Prompt-Cache davor bleibt gültig.
            if local, rawBlocks == nil { history[assistantIndex] = Self.slimToolCalls(history[assistantIndex]) }
        }
        items.append(Item(kind: .error(Self.stepLimitPrefix + " \(context.maxSteps) Schritten – der Agent ist noch nicht fertig. Mit „Weitermachen“ geht es an derselben Stelle weiter.")))
    }

    private func execute(_ call: LLMClient.ToolCall, tools: [AgentTool]) async -> String {
        let tool = tools.first { $0.name == call.name }
        let itemID = UUID()
        let args = prettyJSON(call.arguments)
        items.append(Item(id: itemID, kind: .tool(name: call.name, source: tool?.source ?? "?", arguments: args, state: .running, result: "")))
        func update(_ state: ToolState, _ result: String) {
            setKind(itemID, .tool(name: call.name, source: tool?.source ?? "?", arguments: args, state: state, result: result))
        }
        guard let tool else {
            update(.failed, "Unbekanntes Werkzeug")
            return "Fehler: Werkzeug \(call.name) gibt es nicht. Verfügbar: \(tools.map(\.name).joined(separator: ", "))"
        }
        let parsed = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any]) ?? [:]

        let dangerous = dangerGuard ? Self.dangerReason(tool: tool.name, args: parsed) : nil
        var approval = tool.needsApproval ? (autoApprove ? "YOLO" : "freigegeben") : "frei"
        let started = Date()
        if tool.needsApproval && (!autoApprove || dangerous != nil) {
            update(.awaitingApproval, "")
            let ok = await withCheckedContinuation { approvals[itemID] = $0 }
            if dangerous != nil { approval = "Notbremse → " + (ok ? "freigegeben" : "abgelehnt") }
            guard ok else {
                update(.denied, "Abgelehnt")
                ActionLog.log(context: "Chat", tool: tool.name, source: tool.source, arguments: args, approval: "abgelehnt",
                              ok: false, started: started, result: "")
                return "Der Nutzer hat diesen Aufruf abgelehnt."
            }
            update(.running, "")
        }
        do {
            var out = try await tool.run(parsed)
            let written = PreviewStore.writtenPath(tool: tool.name, arguments: call.arguments, workspace: workspace)
            if let written, mode != .chat {
                if !changedFiles.contains(written) { changedFiles.append(written) }
                if let report = await CodeCheck.report(for: written) { out += "\n\n" + report }
            }
            update(.done, out)
            if let url = written {
                preview.fileWritten(url)
            } else {
                preview.reloadIfChanged()
            }
            ActionLog.log(context: "Chat", tool: tool.name, source: tool.source, arguments: args, approval: approval,
                          ok: true, started: started, result: out)
            return out
        } catch {
            update(.failed, error.localizedDescription)
            ActionLog.log(context: "Chat", tool: tool.name, source: tool.source, arguments: args, approval: approval,
                          ok: false, started: started, result: error.localizedDescription)
            return "Fehler: \(error.localizedDescription)"
        }
    }

    /// Eintrag über seine ID ändern – wurde das Gespräch inzwischen zurückgesetzt, passiert nichts.
    private func setKind(_ id: UUID, _ kind: Item.Kind) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].kind = kind }
    }

    static let stepLimitPrefix = "Pause nach"

    // MARK: Verlauf verdichten

    /// Hält den Verlauf unter `budget` Zeichen (≈ Zeichen/3,5 Tokens): ältere Werkzeug-Ergebnisse und große Dateiinhalte
    /// in früheren Werkzeug-Aufrufen werden gekürzt. Systemprompt, Aufgabe und die letzten `keepRecent` Nachrichten bleiben.
    private func compactHistory(budget: Int, keepRecent: Int = 6) {
        func size() -> Int { history.reduce(0) { $0 + Self.length(of: $1) } }
        guard size() > budget, history.count > keepRecent + 2 else { return }
        let protected = Set([0, 1] + Array(max(0, history.count - keepRecent)..<history.count))
        for limit in [1500, 600, 200] {
            for i in history.indices where !protected.contains(i) {
                var m = history[i]
                if m["role"] as? String == "tool", let c = m["content"] as? String, c.count > limit {
                    m["content"] = String(c.prefix(limit)) + "\n… [von der App gekürzt: \(c.count) Zeichen – bei Bedarf erneut lesen]"
                }
                if var calls = m["tool_calls"] as? [[String: Any]] {
                    for j in calls.indices {
                        guard var f = calls[j]["function"] as? [String: Any], let a = f["arguments"] as? String, a.count > limit,
                              var obj = (try? JSONSerialization.jsonObject(with: Data(a.utf8))) as? [String: Any] else { continue }
                        for (k, v) in obj { if let s = v as? String, s.count > 200 { obj[k] = String(s.prefix(200)) + " …[gekürzt, steht in der Datei]" } }
                        if let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) { f["arguments"] = s }
                        calls[j]["function"] = f
                    }
                    m["tool_calls"] = calls
                }
                if m["role"] as? String == "assistant", let c = m["content"] as? String, c.count > limit * 2 {
                    m["content"] = String(c.prefix(limit * 2)) + " …[gekürzt]"
                }
                history[i] = m
            }
            if size() <= budget { return }
        }
    }

    /// Werkzeug-Ergebnis begrenzen, bevor es in den Verlauf kommt (Anfang und Ende bleiben, Hinweis zum Nachlesen).
    nonisolated static func capToolResult(_ text: String, tool: String) -> String {
        let limit = tool == "read_file" ? 6_000 : 4_000
        guard text.count > limit else { return text }
        let head = text.prefix(limit - 1_200), tail = text.suffix(900)
        let hint = tool == "read_file" ? "mit start_line/end_line gezielt nachlesen" : "bei Bedarf gezielter abfragen (z. B. grep, head, tail)"
        return "\(head)\n\n… [von der App gekürzt: \(text.count - head.count - tail.count) Zeichen ausgelassen – \(hint)] …\n\n\(tail)"
    }

    /// Große Argumente (Dateiinhalte) in einer Werkzeug-Anfrage des Modells durch einen kurzen Verweis ersetzen.
    nonisolated static func slimToolCalls(_ message: [String: Any]) -> [String: Any] {
        guard var calls = message["tool_calls"] as? [[String: Any]] else { return message }
        var m = message
        for j in calls.indices {
            guard var f = calls[j]["function"] as? [String: Any], let a = f["arguments"] as? String, a.count > 1_500,
                  var obj = (try? JSONSerialization.jsonObject(with: Data(a.utf8))) as? [String: Any] else { continue }
            for key in ["content", "new_string", "old_string", "new_text", "old_text"] {   // auch replace_lines.new_text
                if let v = obj[key] as? String, v.count > 400 {
                    obj[key] = String(v.prefix(240)) + " …[\(v.count) Zeichen – vollständig in der Datei, bei Bedarf read_file]"
                }
            }
            if let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) { f["arguments"] = s }
            calls[j]["function"] = f
        }
        m["tool_calls"] = calls
        return m
    }

    static func totalLength(_ history: [[String: Any]]) -> Int { history.reduce(0) { $0 + length(of: $1) } }

    private static func length(of message: [String: Any]) -> Int {
        var n = (message["content"] as? String)?.count ?? 600   // Bilder/Teile grob schätzen
        for c in message["tool_calls"] as? [[String: Any]] ?? [] {
            n += ((c["function"] as? [String: Any])?["arguments"] as? String)?.count ?? 0
        }
        return n
    }

    /// Kurze Absichtserklärung ohne Ergebnis, z. B. „Ich starte mit …“, „Lass mich die Datei lesen.“
    /// „Kannst du mir den Inhalt der Datei geben?“ – obwohl read_file & Co. bereitstehen.
    nonisolated static func asksForWhatToolsCanDo(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.range(of: #"(könntest|kannst) du mir .{0,80}(inhalt|datei|ausgabe|code|ordner)|zur verfügung stell|ich kann .{0,60}nicht (lesen|sehen|öffnen|zugreifen)|liegt mir nicht vor|ohne den .{0,30}(code|inhalt)|i (don't|do not|cannot|can't) (have access|see|read)|please (provide|share|paste)"#,
                           options: .regularExpression) != nil
    }

    nonisolated static func isAnnouncement(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count < 2500 else { return false }
        // Entscheidend ist das Ende: Kündigt der letzte Satz etwas an, statt ein Ergebnis zu nennen?
        let tail = String(t.suffix(260)).lowercased()
        if ["fertig", "erledigt", "zusammenfassung", "hier ist", "ergebnis:", "viel spaß", "gerne wieder"].contains(where: tail.contains) { return false }
        if tail.hasSuffix("?") { return false }   // Rückfrage an den Nutzer ist in Ordnung
        if tail.hasSuffix(":") || tail.hasSuffix("…") || tail.hasSuffix("...") { return true }
        let verbs = "starte|beginne|werde|schaue|prüfe|lese|erstelle|schreibe|lege|mache|fange|füge|ändere|korrigiere|passe|baue|teste|führe|warte|melde|behebe|ergänze|aktualisiere|rufe"
        return tail.range(of: "\\b((ich|wir) (\(verbs))|lass mich|lass uns|let me|i('ll| will)|als nächstes|jetzt (\(verbs))|zuerst (\(verbs))|dann (\(verbs)))\\b",
                          options: .regularExpression) != nil
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
            // Dateien außerhalb des Benutzerordners ändern (z. B. Homebrew, /usr, /Library) – auch über „cd /opt/… && ln …“.
            let systemPath = #"(^|[\s'"=:;&(])/(opt|usr|library|system|etc|private/etc|applications|bin|sbin)(/|\b)"#
            let modifying = #"\b(ln|cp|mv|rm|rmdir|chmod|chown|chflags|tee|touch|mkdir|install|rsync|xattr|unlink|truncate|sed\s+-i)\b"#
            let redirectToSystem = #">>?\s*['"]?/(opt|usr|library|system|etc|applications|bin|sbin)/"#
            if (cmd.range(of: systemPath, options: .regularExpression) != nil && cmd.range(of: modifying, options: .regularExpression) != nil)
                || cmd.range(of: redirectToSystem, options: .regularExpression) != nil {
                return "Shell-Befehl ändert Dateien außerhalb des Benutzerordners"
            }
            if cmd.range(of: #"\bbrew\s+(uninstall|remove|rm|link|unlink|cleanup|untap|services)\b|\b(npm|pnpm|yarn)\b.*\s(-g|--global)\b"#,
                         options: .regularExpression) != nil {
                return "Shell-Befehl ändert systemweit installierte Pakete"
            }
        }
        if ["write_file", "edit_file", "replace_lines"].contains(tool), let path = args["path"] as? String {
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
    static func runSubAgent(model: String, system: String, task: String, tools: [AgentTool], maxSteps: Int,
                            logContext: String = "Sub-Agent") async throws -> String {
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
                    let started = Date()
                    do {
                        out = try await tool.run(args)
                        ActionLog.log(context: logContext, tool: tool.name, source: tool.source, arguments: call.arguments,
                                      approval: "unbeaufsichtigt", ok: true, started: started, result: out)
                    } catch {
                        out = "Fehler bei \(call.name): \(error.localizedDescription)"
                        ActionLog.log(context: logContext, tool: tool.name, source: tool.source, arguments: call.arguments,
                                      approval: "unbeaufsichtigt", ok: false, started: started, result: error.localizedDescription)
                    }
                } else {
                    out = "Werkzeug \(call.name) ist für Sub-Agenten nicht verfügbar."
                }
                messages.append(["role": "tool", "tool_call_id": call.id, "content": out])
            }
        }
        return "(Sub-Agent hat nach \(maxSteps) Schritten aufgehört)"
    }

    // MARK: Speichern & Laden

    /// Vom Nutzer vergebener Titel (sonst: Anfang der ersten Nachricht).
    private(set) var customTitle: String?
    /// Angeheftet: steht in der Gesprächsliste oben (z. B. das „Haupt-Gespräch“ eines Projekts).
    private(set) var angeheftet = false

    var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        for item in items { if case let .user(t, _) = item.kind { return String(t.prefix(60)) } }
        return "Neues Gespräch"
    }

    func rename(chatID id: String, to newTitle: String) {
        ChatStore.rename(id: id, to: newTitle)
        if id == chatID { customTitle = newTitle.isEmpty ? nil : newTitle }
        historyVersion += 1
    }

    func anheften(chatID id: String, _ an: Bool) {
        ChatStore.anheften(id: id, an)
        if id == chatID { angeheftet = an }
        historyVersion += 1
    }

    func deleteChat(id: String) {
        ChatStore.delete(id: id)
        if id == chatID { newChat() }
        historyVersion += 1
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
        ChatStore.save(id: chatID, ["title": title, "customTitle": customTitle ?? "", "angeheftet": angeheftet, "updated": Date().timeIntervalSince1970, "mode": mode.rawValue,
                                    "project": project?.id.uuidString ?? "",
                                    "items": encoded, "history": history])
        historyVersion += 1
    }

    func load(id: String) {
        guard !isRunning, let json = ChatStore.load(id: id) else { return }
        chatID = id
        customTitle = (json["customTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        angeheftet = json["angeheftet"] as? Bool ?? false
        apply(project: projects.project(id: (json["project"] as? String).flatMap(UUID.init(uuidString:))))
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
        lastPromptTokens = items.reversed().lazy.compactMap { item -> Int? in
            if case let .assistant(_, _, stats?) = item.kind, stats.promptTokens > 0 { return stats.promptTokens }
            return nil
        }.first ?? 0
        // Vorschau-Tabs aus den geschriebenen Dateien wiederherstellen (ohne das Panel aufzuklappen).
        preview.clear()
        for item in items {
            if case let .tool(name, _, args, .done, _) = item.kind,
               let url = PreviewStore.writtenPath(tool: name, arguments: args, workspace: workspace),
               FileManager.default.fileExists(atPath: url.path) {
                let open = preview.autoOpen
                preview.autoOpen = false
                preview.fileWritten(url)
                preview.autoOpen = open
            }
        }
    }
}
