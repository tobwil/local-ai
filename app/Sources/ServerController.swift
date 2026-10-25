import Foundation
import Observation

/// Startet und überwacht oMLX als Kindprozess.
@MainActor @Observable
final class ServerController {
    enum State: Equatable {
        case stopped, starting, running, external
        case failed(String)

        var isUp: Bool { self == .running || self == .external }
    }

    private(set) var state: State = .stopped
    private(set) var log: [String] = []
    private(set) var servedModels: [String] = []
    private var process: Process?
    private let maxLogLines = 800

    var engineInstalled: Bool { FileManager.default.isExecutableFile(atPath: Paths.omlx.path) }

    /// Prüft, ob schon ein Server läuft (z. B. aus dem Terminal gestartet).
    func probe() async {
        let models = await fetchModels()
        if let models {
            servedModels = models
            if process == nil { state = .external }
        } else if process == nil, state.isUp {
            state = .stopped
        }
    }

    /// Feste Obergrenze für oMLX in GiB. "aggressive" richtet sich nach dem gerade freien RAM
    /// und lehnt das Modell ab, sobald andere Apps viel belegen; das Metal-Limit ist die echte Grenze.
    var memoryCeilingGiB: Double = 17.7

    func start() {
        guard process == nil else { return }
        guard engineInstalled else {
            state = .failed("oMLX nicht gefunden unter \(Paths.omlx.path)")
            return
        }
        try? FileManager.default.createDirectory(at: Paths.models, withIntermediateDirectories: true)
        ModelSettingsStore.tuneServerSettings(lan: HomeNetwork.enabled)

        let p = Process()
        p.executableURL = Paths.omlx
        p.arguments = [
            "serve", "--model-dir", Paths.models.path, "--port", String(Paths.port),
            // Mit Guard drosselt oMLX die Prompt-Häppchen bei langem Kontext, statt abzustürzen.
            "--memory-guard-gb", String(format: "%.1f", memoryCeilingGiB),
            "--paged-ssd-cache-dir", Paths.kvCache.path, "--paged-ssd-cache-max-size", "10GB",
        ]
        // Adresse immer ausdrücklich angeben: oMLX merkt sich --host in settings.json, und ein einmal
        // freigegebener Server dürfte sonst später ohne Schlüssel im Netz lauschen.
        if let key = HomeNetwork.key {
            p.arguments! += ["--host", "0.0.0.0", "--api-key", key]   // Heimnetz, nur mit Schlüssel
        } else {
            // Nur lokal: Schlüssel schützt Verwaltung/Statistik, Chatten geht ohne (allow_unauthenticated_inference)
            p.arguments! += ["--host", "127.0.0.1", "--api-key", HomeNetwork.localKey]
        }
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.appendLog(text) }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.processEnded(status: proc.terminationStatus) }
        }

        do {
            try p.run()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        process = p
        state = .starting
        appendLog("▶ oMLX gestartet (PID \(p.processIdentifier))\n")

        Task {
            for _ in 0..<180 {
                try? await Task.sleep(for: .seconds(1))
                guard process === p else { return }
                if let models = await fetchModels() {
                    servedModels = models
                    state = .running
                    return
                }
            }
            if process === p { state = .failed("Server antwortet nicht – siehe Protokoll") }
        }
    }

    func stop() {
        guard let p = process else { return }
        appendLog("■ oMLX wird beendet …\n")
        p.terminate()
    }

    func restart() async {
        if let p = process {
            stop()
            while p.isRunning { try? await Task.sleep(for: .milliseconds(200)) }
        }
        start()
    }

    /// Eine außerhalb gestartete Engine (z. B. tools/serve.sh) beenden und selbst neu starten –
    /// nötig, damit Einstellungen wie die Heimnetz-Freigabe (--host 0.0.0.0) greifen.
    func takeOver() async {
        guard process == nil, state == .external else { return }
        appendLog("■ Extern gestartete Engine wird übernommen …\n")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-t", "-iTCP:\(Paths.port)", "-sTCP:LISTEN"]
        let out = Pipe()
        p.standardOutput = out
        let pids = ((try? await p.runAndRead(out))?.0).flatMap { String(data: $0, encoding: .utf8) }?
            .split(whereSeparator: \.isNewline).compactMap { Int32($0) } ?? []
        for pid in pids { kill(pid, SIGTERM) }
        for _ in 0..<60 {
            if await fetchModels() == nil { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        state = .stopped
        start()
    }

    /// Beim Beenden der App: Server synchron mitnehmen.
    func shutdownSync() {
        guard let p = process, p.isRunning else { return }
        p.terminate()
        p.waitUntilExit()
    }

    private func processEnded(status: Int32) {
        process = nil
        servedModels = []
        appendLog("■ oMLX beendet (Status \(status))\n")
        if case .failed = state { return }
        state = (status == 0 || status == 15) ? .stopped : .failed("oMLX ist abgestürzt (Status \(status))")
    }

    private func appendLog(_ text: String) {
        log.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
        if log.count > maxLogLines { log.removeFirst(log.count - maxLogLines) }
    }

    private func fetchModels() async -> [String]? {
        var req = URLRequest(url: Paths.openAIBase.appendingPathComponent("models"))
        req.timeoutInterval = 2
        HomeNetwork.authorize(&req)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return nil }
        return list.compactMap { $0["id"] as? String }
    }
}
