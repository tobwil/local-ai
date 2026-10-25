import AppKit
import Foundation

/// Übergibt `--agent`-Aufträge an eine bereits laufende KI/lokal-App, damit sie live im Agent-Tab erscheinen.
/// Verbindung über DistributedNotificationCenter: Terminal → App „request“, App → Terminal „event“
/// (Annahme, Fortschrittszeilen, Ende mit Exit-Code). Das Terminal zeigt denselben Verlauf wie ohne Oberfläche.
enum AgentHandoff {
    static let request = Notification.Name("de.kisruptiv.kilokal.agent.request")
    static let event = Notification.Name("de.kisruptiv.kilokal.agent.event")

    private struct Event: Sendable {
        var kind: String
        var text = ""
        var code = 0
    }

    // MARK: Terminal-Seite

    /// Exit-Code, wenn eine laufende App den Auftrag übernommen hat; nil = ohne Oberfläche ausführen.
    @MainActor
    static func forward(arguments args: [String]) async -> Int32? {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let bundleID = Bundle.main.bundleIdentifier,
              let gui = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                  .first(where: { $0.processIdentifier != me }),
              let task = HeadlessAgent.value(args, "--agent") else { return nil }
        let pid = gui.processIdentifier

        var payload: [String: Any] = ["task": task, "yolo": args.contains("--yolo")]
        if let m = HeadlessAgent.value(args, "--mode") { payload["mode"] = m }
        let attach = HeadlessAgent.files(args, "--attach")
        if !attach.isEmpty { payload["attach"] = attach }
        // Relativer Pfad gilt relativ zum Terminal, nicht zur App.
        if let ws = HeadlessAgent.value(args, "--workspace") {
            payload["workspace"] = URL(fileURLWithPath: (ws as NSString).expandingTildeInPath).standardizedFileURL.path
        }
        if let n = HeadlessAgent.value(args, "--max-tokens").flatMap(Int.init) { payload["maxTokens"] = n }
        if let n = HeadlessAgent.value(args, "--steps").flatMap(Int.init) { payload["steps"] = n }

        let id = UUID().uuidString
        let (stream, cont) = AsyncStream.makeStream(of: Event.self)
        let center = DistributedNotificationCenter.default()
        let token = center.addObserver(forName: event, object: id, queue: nil) { n in
            let u = n.userInfo ?? [:]
            cont.yield(Event(kind: u["kind"] as? String ?? "", text: u["text"] as? String ?? "", code: u["code"] as? Int ?? 0))
        }
        // Ältere App-Versionen antworten nicht → nach 3 s ohne Oberfläche weitermachen.
        let timeout = Task { try? await Task.sleep(for: .seconds(3)); cont.yield(Event(kind: "timeout")) }
        let watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if kill(pid, 0) != 0 { cont.yield(Event(kind: "gone")) }
            }
        }
        defer {
            center.removeObserver(token)
            timeout.cancel()
            watchdog.cancel()
        }
        center.postNotificationName(request, object: id, userInfo: payload, deliverImmediately: true)

        var accepted = false
        for await e in stream {
            switch e.kind {
            case "accepted":
                accepted = true
                print("▶ An die laufende App übergeben – live im Agent-Tab (abbrechen dort mit ■)")
            case "busy":
                print("✗ \(e.text)")
                return 1
            case "line":
                print(e.text)
            case "done":
                return Int32(e.code)
            case "timeout" where !accepted:
                print("ℹ︎ Die laufende App antwortet nicht (ältere Version?) – starte ohne Oberfläche.\n")
                return nil
            case "gone":
                print("✗ Die App wurde beendet.")
                return 1
            default:
                break
            }
        }
        return nil
    }

    // MARK: App-Seite

    @MainActor
    static func listen(_ app: AppState) {
        DistributedNotificationCenter.default().addObserver(forName: request, object: nil, queue: .main) { n in
            guard let id = n.object as? String, let u = n.userInfo, let task = u["task"] as? String else { return }
            let workspace = u["workspace"] as? String
            let yolo = u["yolo"] as? Bool ?? false
            let mode = (u["mode"] as? String).flatMap(WorkMode.init(rawValue:))
            let maxTokens = u["maxTokens"] as? Int
            let steps = u["steps"] as? Int
            let attach = (u["attach"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }
            MainActor.assumeIsolated {
                accept(id: id, task: task, mode: mode, workspace: workspace, yolo: yolo, maxTokens: maxTokens, steps: steps,
                       attach: attach, app: app)
            }
        }
    }

    @MainActor
    private static func accept(id: String, task: String, mode: WorkMode?, workspace: String?, yolo: Bool,
                               maxTokens: Int?, steps: Int?, attach: [URL], app: AppState) {
        func post(_ kind: String, _ text: String = "", code: Int32 = 0) {
            DistributedNotificationCenter.default().postNotificationName(
                event, object: id, userInfo: ["kind": kind, "text": text, "code": Int(code)], deliverImmediately: true)
        }
        let session = app.session
        guard !session.isRunning, !app.talkMode else {
            post("busy", "Der Agent in der App ist gerade beschäftigt. Später erneut versuchen oder mit --headless ohne Oberfläche starten.")
            return
        }
        post("accepted")
        app.requestedScreen = .agent
        // Mit Ordner: ins Projekt dieses Ordners (wird bei Bedarf angelegt), sonst im aktuellen Projekt.
        if let workspace {
            let url = URL(fileURLWithPath: workspace)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            session.switchProject(session.projects.project(forFolder: url))
        } else {
            session.switchProject(session.project)
        }
        session.modeOverride = mode
        // YOLO gilt nur für diesen Auftrag; Freigaben erteilt der Nutzer in der App.
        let previousYOLO = session.autoApprove
        session.autoApprove = yolo
        Task { @MainActor in
            await app.server.probe()
            if !app.server.state.isUp && !app.selectedIsCloud {
                post("line", "▶ Engine wird gestartet …")
                app.server.start()
                for _ in 0..<240 where !app.server.state.isUp { try? await Task.sleep(for: .milliseconds(500)) }
                guard app.server.state.isUp else {
                    session.autoApprove = previousYOLO
                    post("line", "✗ Engine startet nicht")
                    post("done", code: 1)
                    return
                }
            }
            session.documents = attach
            session.input = task
            app.send { context in
                if let maxTokens { context.maxTokens = maxTokens }
                if let steps { context.maxSteps = steps }
            }
            post("line", "▶ Modell: \(app.selectedModelName) · \(session.project?.name ?? "ohne Projekt") · \(session.mode.title) · Ordner: \(session.workspace.path) · \(yolo ? "YOLO" : "mit Freigabe")\n")
            let code = await HeadlessAgent.follow(session, autoDeny: false) { post("line", $0) }
            session.autoApprove = previousYOLO
            post("done", code: code)
        }
    }
}
