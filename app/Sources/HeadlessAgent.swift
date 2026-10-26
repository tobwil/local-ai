import Foundation

/// `KI lokal --agent "<Auftrag>" [--workspace <ordner>] [--mode chat|work|code] [--yolo] [--max-tokens N] [--steps N] [--headless]`
/// Mit --workspace landet der Auftrag im Projekt dieses Ordners (wird bei Bedarf angelegt); --mode erzwingt die Arbeitsweise;
/// --attach <datei> (mehrfach möglich) hängt Dateien an wie die Büroklammer im Chat; --weiter setzt das offene Gespräch
/// der App fort, statt ein neues zu beginnen.
/// Läuft die App bereits, übernimmt sie den Auftrag live im Agent-Tab (siehe AgentHandoff); das Terminal
/// zeigt den Verlauf mit. Sonst – oder mit --headless – läuft der Agent ohne Oberfläche in diesem Prozess.
/// Mit --yolo laufen Datei- und Shell-Werkzeuge ohne Rückfrage; die Notbremse bleibt an. Ohne Oberfläche
/// lehnt sie gefährliche Aktionen automatisch ab (es gibt niemanden, der freigeben könnte).
enum HeadlessAgent {
    static func value(_ args: [String], _ flag: String) -> String? {
        args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }

    /// Alle Werte eines wiederholbaren Schalters (z. B. mehrmals --attach), als absolute Pfade.
    static func files(_ args: [String], _ flag: String) -> [String] {
        args.indices.filter { args[$0] == flag && $0 + 1 < args.count }.map {
            URL(fileURLWithPath: (args[$0 + 1] as NSString).expandingTildeInPath).standardizedFileURL.path
        }
    }

    @MainActor
    static func run(arguments args: [String]) async -> Int32 {
        guard let task = value(args, "--agent"), !task.isEmpty else {
            print("Auftrag fehlt: --agent \"…\"")
            return 2
        }
        if !args.contains("--headless"), let code = await AgentHandoff.forward(arguments: args) { return code }

        let app = AppState.shared
        await DevEnvironment.detect()
        let session = app.session
        let previousYOLO = UserDefaults.standard.object(forKey: "yolo")
        let previousProject = UserDefaults.standard.string(forKey: "project")
        defer {
            UserDefaults.standard.set(previousProject, forKey: "project")
            UserDefaults.standard.set(previousYOLO, forKey: "yolo")
        }
        if let ws = value(args, "--workspace") {
            let url = URL(fileURLWithPath: (ws as NSString).expandingTildeInPath)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            session.switchProject(session.projects.project(forFolder: url))
        }
        if let m = value(args, "--mode").flatMap(WorkMode.init(rawValue:)) { session.modeOverride = m }
        session.autoApprove = args.contains("--yolo")
        session.dangerGuard = true

        await app.server.probe()
        if !app.server.state.isUp && !app.selectedIsCloud {
            print("▶ Engine wird gestartet …")
            app.server.start()
            for _ in 0..<240 where !app.server.state.isUp { try? await Task.sleep(for: .milliseconds(500)) }
            guard app.server.state.isUp else { print("✗ Engine startet nicht"); return 1 }
        }

        var context = app.agentContext
        if let n = value(args, "--max-tokens").flatMap(Int.init) { context.maxTokens = n }
        if let n = value(args, "--steps").flatMap(Int.init) { context.maxSteps = n }
        print("▶ Modell: \(app.selectedModelName) · \(session.project?.name ?? "ohne Projekt") · \(session.mode.title) · Ordner: \(session.workspace.path) · \(session.autoApprove ? "YOLO" : "mit Freigabe")")
        print("▶ Auftrag: \(task.prefix(200))\(task.count > 200 ? " …" : "")\n")

        session.reset()
        session.documents = files(args, "--attach").map { URL(fileURLWithPath: $0) }
        session.input = task
        session.send(model: app.selectedModelID, tools: app.modeTools, context: context)
        return await follow(session, autoDeny: true) { print($0) }
    }

    /// Verfolgt einen laufenden Auftrag und gibt Werkzeug-Aufrufe und Antworten als Zeilen aus.
    /// `autoDeny`: Freigabe-Anfragen sofort ablehnen (ohne Oberfläche); sonst wartet der Agent auf den Nutzer.
    @MainActor
    static func follow(_ session: AgentSession, autoDeny: Bool, emit: (String) -> Void) async -> Int32 {
        let started = Date()
        var printed = Set<UUID>()
        var toolStates: [UUID: String] = [:]
        while session.isRunning || !printed.isSuperset(of: session.items.map(\.id)) {
            for item in session.items {
                switch item.kind {
                case let .tool(name, _, arguments, state, result):
                    if state == .awaitingApproval {
                        if autoDeny {
                            emit("  ⛔ \(name): Notbremse – ohne Nutzer automatisch abgelehnt")
                            session.approve(item.id, false)
                        } else if toolStates[item.id] != "waiting" {
                            toolStates[item.id] = "waiting"
                            emit("  ⏸ \(name): wartet auf deine Freigabe in der App")
                        }
                    }
                    let key = "\(state)"
                    if toolStates[item.id] != key, state != .running, state != .awaitingApproval {
                        toolStates[item.id] = key
                        let arg = arguments.replacingOccurrences(of: "\n", with: " ").prefix(140)
                        emit("  🔧 \(name) [\(state.rawValue)] \(arg)")
                        if state == .failed { emit("     ↳ \(result.prefix(300))") }
                        printed.insert(item.id)
                    }
                case let .assistant(text, _, stats):
                    if let stats, !printed.contains(item.id) {
                        printed.insert(item.id)
                        if !text.isEmpty { emit("\n💬 \(text)\n") }
                        emit("     (\(stats.tokens) Tokens, \(String(format: "%.1f", stats.tokPerSec)) tok/s)")
                    } else if !session.isRunning && stats == nil {
                        printed.insert(item.id)
                    }
                case let .error(m):
                    let mark = m.hasPrefix(AgentSession.qualityPrefix) ? "🔎" : m.hasPrefix(AgentSession.stepLimitPrefix) ? "⏸" : "✗"
                    if !printed.contains(item.id) { printed.insert(item.id); emit("\(mark) \(m)") }
                case .user:
                    printed.insert(item.id)
                }
            }
            if !session.isRunning { break }
            try? await Task.sleep(for: .milliseconds(400))
        }
        emit("\n▶ Fertig nach \(Int(Date().timeIntervalSince(started))) s")
        return session.items.contains { if case let .error(m) = $0.kind { return !m.hasPrefix(AgentSession.qualityPrefix) }; return false } ? 1 : 0
    }
}
