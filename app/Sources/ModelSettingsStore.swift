import Foundation

/// Liest und schreibt die Beschleunigung pro Modell in ~/.omlx/model_settings.json
/// (dasselbe wie tools/mode.py). oMLX liest die Datei beim Start.
enum Acceleration: String, CaseIterable, Identifiable {
    case plain, mtp
    var id: String { rawValue }
    var label: String { self == .plain ? "Aus · bester Chat" : "MTP · schnelle Code-Edits" }
}

enum ModelSettingsStore {
    static func acceleration(for modelID: String) -> Acceleration {
        let models = load()["models"] as? [String: Any]
        let s = models?[modelID] as? [String: Any]
        return (s?["mtp_enabled"] as? Bool) == true ? .mtp : .plain
    }

    static func setAcceleration(_ acc: Acceleration, for modelID: String) throws {
        var root = load()
        var models = root["models"] as? [String: Any] ?? [:]
        var s = models[modelID] as? [String: Any] ?? [:]
        s["mtp_enabled"] = acc == .mtp
        s["dflash_enabled"] = false
        models[modelID] = s
        root["models"] = models
        root["version"] = root["version"] ?? 1
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: Paths.omlxModelSettings.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: Paths.omlxModelSettings, options: .atomic)
    }

    private static func load() -> [String: Any] {
        guard let data = try? Data(contentsOf: Paths.omlxModelSettings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }
}
