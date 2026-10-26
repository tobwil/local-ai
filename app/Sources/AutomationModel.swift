import Foundation

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

    // MARK: Überwachung ohne Modell
    /// Prüfbefehl (Shell), der zu jedem Termin läuft – ohne Modell. Leer = normale Automation.
    /// Nur wenn der Auslöser greift, arbeitet der Agent (mit der Ausgabe als Kontext) oder es kommt direkt eine Mitteilung.
    var watchCommand = ""
    var watchTrigger: WatchTrigger = .changed
    /// Letzte Ausgabe des Prüfbefehls (Vergleich für „geändert“).
    var lastWatchOutput: String?
    var lastCheck: Date?
    var lastCheckNote: String?

    var isWatch: Bool { !watchCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

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

    /// Vorlagen für Überwachungen: Der Befehl läuft alle paar Minuten ohne Modell, der Agent nur bei Bedarf.
    static let watchTemplates: [Automation] = [
        Automation(name: "Webseite beobachten",
                   prompt: "Die beobachtete Seite hat sich geändert. Fasse in zwei, drei Sätzen zusammen, was neu ist.",
                   intervalMinutes: 60, outputs: [.notify],
                   watchCommand: "curl -sL https://example.com | sed -e 's/<[^>]*>//g' | tr -s ' \\n' | head -c 20000",
                   watchTrigger: .changed),
        Automation(name: "Dienst erreichbar?", prompt: "", intervalMinutes: 15, outputs: [.notify],
                   watchCommand: "curl -sf -o /dev/null -m 10 https://example.com", watchTrigger: .failed),
        Automation(name: "Speicherplatz knapp", prompt: "", intervalMinutes: 120, outputs: [.notify],
                   watchCommand: "df -g / | awk 'NR==2 && $4 < 20 {print \"Nur noch \" $4 \" GB frei\"}'", watchTrigger: .output),
    ]
}

/// Wann eine Überwachung anschlägt.
enum WatchTrigger: String, Codable, CaseIterable, Identifiable {
    /// Ausgabe anders als beim letzten Mal (der erste Lauf legt nur den Vergleichsstand an).
    case changed
    /// Exit-Code ungleich 0 (Dienst nicht erreichbar, Test rot …).
    case failed
    /// Der Befehl hat überhaupt etwas ausgegeben (z. B. ein Filter mit grep).
    case output
    var id: String { rawValue }
    var label: String {
        switch self {
        case .changed: return "Ausgabe hat sich geändert"
        case .failed: return "Befehl schlägt fehl (Exit-Code ≠ 0)"
        case .output: return "Befehl gibt etwas aus"
        }
    }
}

enum WatchCheck {
    struct Outcome: Equatable {
        var fired: Bool
        /// Kurzer Stand für die Liste („keine Änderung“, „geändert“ …).
        var note: String
    }

    /// `Shell.run` liefert „Exit-Code N\n<Ausgabe>“.
    static func parse(_ shellOutput: String) -> (status: Int32, output: String) {
        guard shellOutput.hasPrefix("Exit-Code ") else { return (0, shellOutput) }
        let firstLine = shellOutput.prefix { $0 != "\n" }
        let status = Int32(firstLine.dropFirst("Exit-Code ".count)) ?? 0
        return (status, String(shellOutput.dropFirst(firstLine.count + 1)))
    }

    static func evaluate(trigger: WatchTrigger, status: Int32, output: String, previous: String?) -> Outcome {
        let now = normalize(output)
        switch trigger {
        case .changed:
            guard let previous else { return Outcome(fired: false, note: "Vergleichsstand angelegt") }
            return normalize(previous) == now ? Outcome(fired: false, note: "keine Änderung") : Outcome(fired: true, note: "geändert")
        case .failed:
            return status != 0 ? Outcome(fired: true, note: "fehlgeschlagen (Exit-Code \(status))") : Outcome(fired: false, note: "in Ordnung")
        case .output:
            return now.isEmpty ? Outcome(fired: false, note: "nichts gemeldet") : Outcome(fired: true, note: "meldet etwas")
        }
    }

    /// Leerraum vereinheitlichen, damit Zeilenumbrüche oder Einrückung allein nicht als Änderung zählen.
    static func normalize(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Auftrag an den Agenten, wenn die Überwachung anschlägt: Prompt plus Ausgabe (und vorheriger Stand bei „geändert“).
    static func prompt(for a: Automation, output: String, previous: String?) -> String {
        var s = a.prompt + "\n\n(Überwachung „\(a.name)“ hat angeschlagen: \(a.watchTrigger.label).)\nBefehl: \(a.watchCommand)\nAusgabe jetzt:\n```\n\(output.prefix(8_000))\n```"
        if a.watchTrigger == .changed, let previous {
            s += "\nAusgabe vorher:\n```\n\(previous.prefix(6_000))\n```"
        }
        return s
    }
}

// Eigener Decoder in einer Erweiterung (die memberweise Initialisierung bleibt erhalten): Ältere automations.json
// kennen neuere Felder nicht – sie bekommen dann den Standardwert, statt dass die ganze Liste nicht lädt.
extension Automation {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name), prompt: try c.decode(String.self, forKey: .prompt))
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? id
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        hour = try c.decodeIfPresent(Int.self, forKey: .hour) ?? hour
        minute = try c.decodeIfPresent(Int.self, forKey: .minute) ?? minute
        weekdays = try c.decodeIfPresent(Set<Int>.self, forKey: .weekdays) ?? weekdays
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? intervalMinutes
        outputs = try c.decodeIfPresent(Set<Output>.self, forKey: .outputs) ?? outputs
        allowActions = try c.decodeIfPresent(Bool.self, forKey: .allowActions) ?? allowActions
        lastRun = try c.decodeIfPresent(Date.self, forKey: .lastRun)
        watchCommand = try c.decodeIfPresent(String.self, forKey: .watchCommand) ?? ""
        watchTrigger = try c.decodeIfPresent(WatchTrigger.self, forKey: .watchTrigger) ?? .changed
        lastWatchOutput = try c.decodeIfPresent(String.self, forKey: .lastWatchOutput)
        lastCheck = try c.decodeIfPresent(Date.self, forKey: .lastCheck)
        lastCheckNote = try c.decodeIfPresent(String.self, forKey: .lastCheckNote)
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
