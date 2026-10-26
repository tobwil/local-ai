import Foundation
import Observation
import ServiceManagement
import UserNotifications

@MainActor @Observable
final class AutomationCenter: NSObject {
    static let file = Paths.base.appendingPathComponent("automations.json")
    static let runsFile = Paths.base.appendingPathComponent("automation-runs.json")
    static let outputDir = Paths.home.appendingPathComponent("Documents/KI lokal")

    private(set) var automations: [Automation] = []
    private(set) var runs: [AutomationRun] = []
    private(set) var running: Set<UUID> = []
    private var timer: Task<Void, Never>?
    /// Führt den Auftrag aus und liefert den Text (vom AppState gesetzt).
    var runner: ((Automation) async throws -> String)?
    var speak: ((String) -> Void)?

    override init() {
        super.init()
        load()
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() } catch {}
        }
    }

    func start() {
        guard timer == nil else { return }
        UNUserNotificationCenter.current().delegate = self
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func tick() async {
        let now = Date()
        for a in automations where a.enabled && !running.contains(a.id) {
            // Fällig, wenn der nächste Termin seit dem letzten Lauf erreicht ist.
            let reference = a.lastRun ?? now.addingTimeInterval(-60)
            if let due = a.nextRun(after: reference), due <= now { await run(a) }
        }
    }

    func run(_ automation: Automation) async {
        guard let runner, !running.contains(automation.id) else { return }
        running.insert(automation.id)
        if automation.isWatch {
            await runWatch(automation, runner: runner)
            running.remove(automation.id)
            return
        }
        var record = AutomationRun(automationID: automation.id, name: automation.name, started: Date(), result: "")
        do {
            record.result = try await runner(automation)
        } catch {
            record.result = "Fehler: \(error.localizedDescription)"
            record.failed = true
        }
        record.finished = Date()
        if let i = automations.firstIndex(where: { $0.id == automation.id }) { automations[i].lastRun = record.started }
        runs.insert(record, at: 0)
        if runs.count > 50 { runs.removeLast(runs.count - 50) }
        running.remove(automation.id)
        save()
        deliver(record, outputs: automation.outputs)
    }

    /// Überwachung: Der Prüfbefehl läuft ohne Modell (Sekundenbruchteile, kein Speicher, kein Akku). Nur wenn der
    /// Auslöser greift, arbeitet der Agent mit der Ausgabe – oder es kommt ohne Auftrag direkt eine Mitteilung.
    private func runWatch(_ a: Automation, runner: (Automation) async throws -> String) async {
        let started = Date()
        let raw: String
        // Den Befehl hat der Nutzer selbst geschrieben – er läuft wie im Terminal (ohne Agenten-Sandbox).
        do { raw = try await Shell.run(a.watchCommand, cwd: Paths.home, timeout: 60) } catch { raw = "Exit-Code 1\n\(error.localizedDescription)" }
        let (status, output) = WatchCheck.parse(raw)
        let outcome = WatchCheck.evaluate(trigger: a.watchTrigger, status: status, output: output, previous: a.lastWatchOutput)
        ActionLog.log(context: "Überwachung: \(a.name)", tool: "run_shell", source: "Automation", arguments: a.watchCommand,
                      approval: "unbeaufsichtigt", ok: status == 0, started: started, result: output)
        if let i = automations.firstIndex(where: { $0.id == a.id }) {
            automations[i].lastRun = started
            automations[i].lastCheck = started
            automations[i].lastCheckNote = outcome.note
            automations[i].lastWatchOutput = String(output.prefix(20_000))
        }
        save()
        guard outcome.fired else { return }
        var record = AutomationRun(automationID: a.id, name: a.name, started: started, result: "")
        if a.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let shown = output.trimmingCharacters(in: .whitespacesAndNewlines)
            record.result = "\(a.name): \(outcome.note)" + (shown.isEmpty ? "" : "\n\n" + String(shown.prefix(2_000)))
        } else {
            var task = a
            task.prompt = WatchCheck.prompt(for: a, output: output, previous: a.lastWatchOutput)
            do { record.result = try await runner(task) } catch {
                record.result = "Fehler: \(error.localizedDescription)"
                record.failed = true
            }
        }
        record.finished = Date()
        runs.insert(record, at: 0)
        if runs.count > 50 { runs.removeLast(runs.count - 50) }
        save()
        deliver(record, outputs: a.outputs)
    }

    private func deliver(_ run: AutomationRun, outputs: Set<Automation.Output>) {
        if outputs.contains(.notify) { notify(title: run.name, body: run.result) }
        if outputs.contains(.speak), !run.failed { speak?(run.result) }
        if outputs.contains(.file) {
            try? FileManager.default.createDirectory(at: Self.outputDir, withIntermediateDirectories: true)
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH-mm"
            let url = Self.outputDir.appendingPathComponent("\(run.name) \(f.string(from: run.started)).md")
            try? "# \(run.name)\n\n\(run.result)\n".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = String(VoiceController.plain(body).prefix(240))
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: Verwaltung

    func upsert(_ a: Automation) {
        if let i = automations.firstIndex(where: { $0.id == a.id }) { automations[i] = a } else { automations.append(a) }
        save()
    }

    func remove(_ a: Automation) {
        automations.removeAll { $0.id == a.id }
        save()
    }

    private func load() {
        let dec = JSONDecoder()
        if let d = try? Data(contentsOf: Self.file), let list = try? dec.decode([Automation].self, from: d) { automations = list }
        if let d = try? Data(contentsOf: Self.runsFile), let list = try? dec.decode([AutomationRun].self, from: d) { runs = list }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Paths.base, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        try? enc.encode(automations).write(to: Self.file, options: .atomic)
        try? enc.encode(runs).write(to: Self.runsFile, options: .atomic)
    }
}

extension AutomationCenter: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }
}
