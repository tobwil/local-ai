import Foundation
import Observation
import ServiceManagement
import UserNotifications

/// Geplante Aufgaben: ein Auftrag an den Agenten, der zu festen Zeiten von selbst läuft (z. B. das Morgen-Briefing).
struct Automation: Codable, Identifiable, Hashable {
    enum Output: String, Codable, CaseIterable, Identifiable {
        case notify, speak, file
        var id: String { rawValue }
        var label: String {
            switch self {
            case .notify: return "Mitteilung"
            case .speak: return "Vorlesen"
            case .file: return "Als Datei speichern"
            }
        }
    }

    var id = UUID()
    var name: String
    var prompt: String
    var enabled = true
    /// Uhrzeit (Stunde/Minute) und Wochentage (1 = Sonntag … 7 = Samstag, leer = täglich).
    var hour = 7
    var minute = 30
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    /// Alternativ: alle N Minuten (0 = aus, dann gilt die Uhrzeit).
    var intervalMinutes = 0
    var outputs: Set<Output> = [.notify]
    /// Darf schreiben/Shell/Browser-Aktionen ausführen (läuft unbeaufsichtigt, also ohne Rückfrage).
    var allowActions = false
    var lastRun: Date?

    /// Nächster Termin nach `date`.
    func nextRun(after date: Date) -> Date? {
        guard enabled else { return nil }
        if intervalMinutes > 0 {
            return (lastRun ?? date.addingTimeInterval(-Double(intervalMinutes) * 60)).addingTimeInterval(Double(intervalMinutes) * 60)
        }
        let cal = Calendar.current
        for offset in 0..<8 {
            guard let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: date)),
                  let at = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { continue }
            if at <= date { continue }
            if weekdays.isEmpty || weekdays.contains(cal.component(.weekday, from: at)) { return at }
        }
        return nil
    }

    var scheduleText: String {
        if intervalMinutes > 0 { return "alle \(intervalMinutes) min" }
        let days: String
        switch weekdays {
        case []: days = "täglich"
        case [2, 3, 4, 5, 6]: days = "Mo–Fr"
        case [1, 7]: days = "Wochenende"
        default:
            let names = ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"]
            days = weekdays.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }.map { names[$0 - 1] }.joined(separator: ", ")
        }
        return "\(days) um \(String(format: "%02d:%02d", hour, minute))"
    }

    static func briefing(location: String) -> Automation {
        Automation(name: "Morgen-Briefing", prompt: """
        Erstelle mein Morgen-Briefing für heute. Nutze die Werkzeuge:
        1. Termine heute (calendar_events, days_ahead 0) – Uhrzeit und Titel.
        2. Fällige oder überfällige Erinnerungen (reminders_list).
        3. Bis zu 5 wichtige ungelesene E-Mails (mail_recent mit unread_only) – nur Absender und Betreff.
        4. Wetter heute in \(location) (web_search).
        5. Drei wichtige Nachrichten des Tages (fetch_url https://www.tagesschau.de).
        Fasse alles kurz, freundlich und übersichtlich zusammen. Lass Abschnitte weg, zu denen es nichts gibt.
        """, hour: 7, minute: 30, weekdays: [2, 3, 4, 5, 6], outputs: [.notify, .speak])
    }
}

struct AutomationRun: Codable, Identifiable {
    var id = UUID()
    let automationID: UUID
    let name: String
    let started: Date
    var finished: Date?
    var result: String
    var failed = false
}

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
