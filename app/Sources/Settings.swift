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

    init() {
        let d = UserDefaults.standard
        searchProvider = WebSearch.provider
        searxngURL = d.string(forKey: "searxngURL") ?? ""
        braveKey = Keychain.get("braveKey") ?? ""
        maxSteps = d.object(forKey: "maxSteps") as? Int ?? 24
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
    }
}

/// Gespeicherte Gespräche unter ~/.strata-lite/chats.
enum ChatStore {
    static let dir = Paths.base.appendingPathComponent("chats")

    struct Entry: Identifiable {
        let id: String
        let title: String
        let date: Date
    }

    static func list() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return Entry(id: url.deletingPathExtension().lastPathComponent, title: json["title"] as? String ?? "Gespräch",
                         date: Date(timeIntervalSince1970: json["updated"] as? Double ?? 0))
        }
        .sorted { $0.date > $1.date }
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

    static func delete(id: String) {
        try? FileManager.default.trashItem(at: dir.appendingPathComponent("\(id).json"), resultingItemURL: nil)
    }
}
