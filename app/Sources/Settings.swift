import Foundation
import Observation

@MainActor @Observable
final class AppSettings {
    var searchProvider: WebSearch.Provider {
        didSet { UserDefaults.standard.set(searchProvider.rawValue, forKey: "searchProvider") }
    }
    var searxngURL: String {
        didSet { UserDefaults.standard.set(searxngURL, forKey: "searxngURL") }
    }
    var braveKey: String {
        didSet { Keychain.set("braveKey", braveKey) }
    }
    var maxSteps: Int {
        didSet { UserDefaults.standard.set(maxSteps, forKey: "maxSteps") }
    }
    var customInstructions: String {
        didSet { UserDefaults.standard.set(customInstructions, forKey: "customInstructions") }
    }
    var maxTokens: Int {
        didSet { UserDefaults.standard.set(maxTokens, forKey: "maxTokens") }
    }
    /// Modell-Router: pro Thema ein Modell ("" = das oben gewählte Modell).
    var routerEnabled: Bool {
        didSet { UserDefaults.standard.set(routerEnabled, forKey: "routerEnabled") }
    }
    var routes: [String: String] {
        didSet { UserDefaults.standard.set(routes, forKey: "routes") }
    }
    // Externe Modelle (optional). Schlüssel liegen im Schlüsselbund.
    var anthropicKey: String { didSet { Keychain.set("anthropicKey", anthropicKey) } }
    var openaiKey: String { didSet { Keychain.set("openaiKey", openaiKey) } }
    var openaiBaseURL: String { didSet { UserDefaults.standard.set(openaiBaseURL, forKey: "openaiBaseURL") } }
    var anthropicEffort: String { didSet { UserDefaults.standard.set(anthropicEffort, forKey: "anthropicEffort") } }
    /// Cloud-Modell, das der lokale Agent über ask_expert befragen darf ("" = aus).
    var expertModel: String { didSet { UserDefaults.standard.set(expertModel, forKey: "expertModel") } }
    /// Browser-Steuerung über JXA (aus, bis der Nutzer sie einschaltet).
    var browserEnabled: Bool { didSet { UserDefaults.standard.set(browserEnabled, forKey: "browserEnabled") } }
    var browserApp: String { didSet { UserDefaults.standard.set(browserApp, forKey: "browserApp") } }
    var readAloud: Bool { didSet { UserDefaults.standard.set(readAloud, forKey: "readAloud") } }
    /// Kalender, Erinnerungen, Kontakte, Mail.
    var pimEnabled: Bool { didSet { UserDefaults.standard.set(pimEnabled, forKey: "pimEnabled") } }
    /// Bildschirmfotos für den Agenten (look_at_screen) und im Gesprächsmodus.
    var screenEnabled: Bool { didSet { UserDefaults.standard.set(screenEnabled, forKey: "screenEnabled") } }
    /// Ort für Wetter im Briefing.
    var homeLocation: String { didSet { UserDefaults.standard.set(homeLocation, forKey: "homeLocation") } }
    var lanEnabled: Bool {
        didSet {
            UserDefaults.standard.set(lanEnabled, forKey: "lanEnabled")
            if lanEnabled && Keychain.get("lanKey") == nil { lanKey = HomeNetwork.newKey() }
        }
    }
    private(set) var lanKey: String
    func regenerateLanKey() { lanKey = HomeNetwork.newKey() }

    init() {
        let d = UserDefaults.standard
        searchProvider = WebSearch.provider
        searxngURL = d.string(forKey: "searxngURL") ?? ""
        braveKey = Keychain.get("braveKey") ?? ""
        // Früher 24 Schritte – zu knapp für echte Aufgaben; einmalig auf 50 anheben (Code-Projekte bekommen das Doppelte).
        if !d.bool(forKey: "maxStepsV2") { if (d.object(forKey: "maxSteps") as? Int ?? 24) <= 24 { d.set(50, forKey: "maxSteps") }; d.set(true, forKey: "maxStepsV2") }
        maxSteps = d.object(forKey: "maxSteps") as? Int ?? 50
        customInstructions = d.string(forKey: "customInstructions") ?? ""
        maxTokens = d.object(forKey: "maxTokens") as? Int ?? 8192
        routerEnabled = d.bool(forKey: "routerEnabled")
        routes = d.dictionary(forKey: "routes") as? [String: String] ?? [:]
        anthropicKey = Keychain.get("anthropicKey") ?? ""
        openaiKey = Keychain.get("openaiKey") ?? ""
        openaiBaseURL = d.string(forKey: "openaiBaseURL") ?? Endpoint.openAIDefaultBase.absoluteString
        anthropicEffort = d.string(forKey: "anthropicEffort") ?? "high"
        expertModel = d.string(forKey: "expertModel") ?? ""
        browserEnabled = d.bool(forKey: "browserEnabled")
        browserApp = d.string(forKey: "browserApp") ?? "Brave Browser"
        readAloud = d.bool(forKey: "readAloud")
        pimEnabled = d.bool(forKey: "pimEnabled")
        screenEnabled = d.object(forKey: "screenEnabled") as? Bool ?? true
        homeLocation = d.string(forKey: "homeLocation") ?? ""
        lanEnabled = d.bool(forKey: "lanEnabled")
        lanKey = Keychain.get("lanKey") ?? ""
    }
}

/// Gespeicherte Gespräche unter ~/.kilokal/chats.
/// Gespräche als JSON-Dateien unter ~/.kilokal/chats. Ein Index im Speicher (nach Änderungsdatum)
/// hält Liste und Volltextsuche schnell, ohne bei jedem Anzeigen alle Dateien neu zu lesen.
@MainActor
enum ChatStore {
    /// Selbsttests setzen hier einen temporären Ordner, damit ihre Gespräche nicht im Verlauf landen.
    static var dir = Paths.base.appendingPathComponent("chats")

    struct Entry: Identifiable {
        let id: String
        let title: String
        let date: Date
        var mode: WorkMode = .work
        var projectID: UUID?
        var angeheftet = false
        /// Kleingeschriebener Text (Titel, Nachrichten, Antworten) für die Suche.
        var searchText = ""
        /// Fundstelle zur Suchanfrage (nur in Suchergebnissen).
        var snippet: String?
    }

    private static var cache: [String: (modified: Date, entry: Entry)] = [:]

    static func list() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var seen = Set<String>()
        var out: [Entry] = []
        for url in files where url.pathExtension == "json" {
            let id = url.deletingPathExtension().lastPathComponent
            seen.insert(id)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if let hit = cache[id], hit.modified == modified { out.append(hit.entry); continue }
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let entry = makeEntry(id: id, json)
            cache[id] = (modified, entry)
            out.append(entry)
        }
        for id in cache.keys where !seen.contains(id) { cache.removeValue(forKey: id) }
        return out.sorted { $0.date > $1.date }
    }

    private static func makeEntry(id: String, _ json: [String: Any]) -> Entry {
        let title = (json["customTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? json["title"] as? String ?? "Gespräch"
        var text = title
        for item in json["items"] as? [[String: Any]] ?? [] where ["user", "assistant"].contains(item["k"] as? String ?? "") {
            text += "\n" + (item["text"] as? String ?? "")
            if text.count > 60_000 { break }
        }
        return Entry(id: id, title: title, date: Date(timeIntervalSince1970: json["updated"] as? Double ?? 0),
                     mode: (json["mode"] as? String).flatMap(WorkMode.init(rawValue:)) ?? .work,
                     projectID: (json["project"] as? String).flatMap(UUID.init(uuidString:)),
                     angeheftet: json["angeheftet"] as? Bool ?? false,
                     searchText: text.lowercased())
    }

    /// Alle Wörter der Anfrage müssen vorkommen; Ergebnis mit Textausschnitt um den ersten Treffer.
    static func search(_ query: String) -> [Entry] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return list() }
        return list().compactMap { e in
            guard terms.allSatisfy({ e.searchText.contains($0) }), let r = e.searchText.range(of: terms[0]) else { return nil }
            var hit = e
            let start = e.searchText.index(r.lowerBound, offsetBy: -40, limitedBy: e.searchText.startIndex) ?? e.searchText.startIndex
            let end = e.searchText.index(r.upperBound, offsetBy: 80, limitedBy: e.searchText.endIndex) ?? e.searchText.endIndex
            hit.snippet = (start > e.searchText.startIndex ? "…" : "")
                + e.searchText[start..<end].replacingOccurrences(of: "\n", with: " ") + (end < e.searchText.endIndex ? "…" : "")
            return hit
        }
    }

    static func save(id: String, _ json: [String: Any]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: json) {
            try? data.write(to: dir.appendingPathComponent("\(id).json"), options: .atomic)
        }
    }

    static func load(id: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(id).json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Eigener Titel (leer = wieder automatisch aus der ersten Nachricht).
    static func rename(id: String, to title: String) {
        guard var json = load(id: id) else { return }
        json["customTitle"] = title.trimmingCharacters(in: .whitespacesAndNewlines)
        save(id: id, json)
    }

    static func anheften(id: String, _ an: Bool) {
        guard var json = load(id: id) else { return }
        json["angeheftet"] = an
        save(id: id, json)
    }

    /// In den Papierkorb (wiederherstellbar).
    static func delete(id: String) {
        try? FileManager.default.trashItem(at: dir.appendingPathComponent("\(id).json"), resultingItemURL: nil)
        cache.removeValue(forKey: id)
    }
}
