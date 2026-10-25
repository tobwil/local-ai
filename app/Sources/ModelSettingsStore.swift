import Foundation

/// Liest und schreibt die Beschleunigung pro Modell in ~/.omlx/model_settings.json
/// (dasselbe wie tools/mode.py). oMLX liest die Datei beim Start.
enum Acceleration: String, CaseIterable, Identifiable {
    case plain, auto, mtp
    var id: String { rawValue }
    var label: String {
        switch self {
        case .plain: return "Aus"
        case .auto: return "Automatisch"
        case .mtp: return "Immer MTP"
        }
    }
}

enum ModelSettingsStore {
    static func acceleration(for modelID: String) -> Acceleration {
        let models = load()["models"] as? [String: Any]
        let s = models?[modelID] as? [String: Any]
        guard (s?["mtp_enabled"] as? Bool) == true else { return .plain }
        return UserDefaults.standard.bool(forKey: "mtpAlways.\(modelID)") ? .mtp : .auto
    }

    static func setAcceleration(_ acc: Acceleration, for modelID: String) throws {
        var root = load()
        var models = root["models"] as? [String: Any] ?? [:]
        var s = models[modelID] as? [String: Any] ?? [:]
        s["mtp_enabled"] = acc != .plain
        UserDefaults.standard.set(acc == .mtp, forKey: "mtpAlways.\(modelID)")
        s["dflash_enabled"] = false
        models[modelID] = s
        root["models"] = models
        root["version"] = root["version"] ?? 1
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: Paths.omlxModelSettings.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: Paths.omlxModelSettings, options: .atomic)
    }

    /// KV-Cache-Kompression (TurboQuant, 4 Bit): ~32k Kontext auf 24 GB bei gleichem Tempo.
    static func longContext(for modelID: String) -> Bool {
        let s = (load()["models"] as? [String: Any])?[modelID] as? [String: Any]
        return s?["turboquant_kv_enabled"] as? Bool ?? false
    }

    static func setLongContext(_ on: Bool, for modelID: String) throws {
        var root = load()
        var models = root["models"] as? [String: Any] ?? [:]
        var s = models[modelID] as? [String: Any] ?? [:]
        s["turboquant_kv_enabled"] = on
        s["turboquant_kv_scheme"] = "turboquant"
        s["turboquant_kv_bits"] = 4
        models[modelID] = s
        root["models"] = models
        root["version"] = root["version"] ?? 1
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Paths.omlxModelSettings, options: .atomic)
    }

    /// Speicherwächter von oMLX so einstellen, dass er erst knapp vor dem Metal-Limit eingreift
    /// (Standard 0,85/0,95 bricht lange Kontexte unnötig früh ab).
    static func tuneServerSettings(lan: Bool = false) {
        let url = Paths.home.appendingPathComponent(".omlx/settings.json")
        guard let data = try? Data(contentsOf: url),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var memory = root["memory"] as? [String: Any] ?? [:]
        memory["soft_threshold"] = 0.94
        memory["hard_threshold"] = 0.99
        root["memory"] = memory
        // Lokal (nur 127.0.0.1) dürfen Programme ohne Schlüssel chatten; im Heimnetz nur mit Schlüssel.
        var auth = root["auth"] as? [String: Any] ?? [:]
        auth["allow_unauthenticated_inference"] = !lan
        root["auth"] = auth
        if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: url, options: .atomic)
        }
    }

    private static func load() -> [String: Any] {
        guard let data = try? Data(contentsOf: Paths.omlxModelSettings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }
}
