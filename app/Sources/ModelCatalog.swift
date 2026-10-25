import Foundation

struct ModelInfo: Identifiable, Hashable, Codable {
    /// Ordnername unter ~/.strata-lite/models und zugleich die Modell-ID in oMLX.
    let id: String
    let repo: String
    let name: String
    let summary: String
    let sizeGB: Double
    let activeParamsB: Double
    let bitsPerWeight: Double
    /// Gemessen auf einem M4 (120 GB/s) in oMLX, Chat ohne Beschleuniger.
    let measuredTokSOnM4: Double?
    let hasMTP: Bool
    let license: String
    var vision = false
    /// "Katalog", "Hugging Face" oder "Lokal".
    var origin = "Katalog"

    var folder: URL { Paths.models.appendingPathComponent(id) }

    /// Gewichte plus Luft für Prompt-Verarbeitung und KV-Cache.
    var neededGPUGB: Double { sizeGB + 1.5 }

    func fits(_ hw: Hardware) -> Bool { neededGPUGB <= hw.gpuLimitGB }

    /// tok/s auf dieser Hardware: gemessen auf M4 und mit der Bandbreite skaliert,
    /// sonst aus den aktiven Gewichten geschätzt (Wirkungsgrad aus der Ornith-Messung).
    func estimatedTokS(_ hw: Hardware) -> Double? {
        guard let bw = hw.bandwidthGBs else { return nil }
        if let m = measuredTokSOnM4 { return m * bw / 120 }
        return ModelFit.tokS(activeGB: activeParamsB * bitsPerWeight / 8, bandwidth: bw)
    }

    var isInstalled: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.appendingPathComponent("config.json").path),
              !fm.fileExists(atPath: folder.appendingPathComponent(Downloads.incompleteMarker).path),
              let files = try? fm.contentsOfDirectory(atPath: folder.path) else { return false }
        return files.contains { $0.hasSuffix(".safetensors") }
    }
}

/// Bewertung, ob und wie gut ein Modell auf diesem Mac läuft.
enum ModelFit {
    enum Rating: Int, Comparable {
        case tooBig, tight, slow, good
        static func < (a: Rating, b: Rating) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .good: return "Läuft gut"
            case .slow: return "Läuft, aber langsam"
            case .tight: return "Knapp – nur kurzer Kontext"
            case .tooBig: return "Zu groß"
            }
        }
        var icon: String {
            switch self {
            case .good: return "checkmark.circle.fill"
            case .slow: return "tortoise.fill"
            case .tight: return "exclamationmark.triangle.fill"
            case .tooBig: return "xmark.circle.fill"
            }
        }
    }

    /// Wirkungsgrad aus der Messung: Ornith 3 Bit, 1,42 GB aktive Gewichte, 43 tok/s bei 120 GB/s.
    static func tokS(activeGB: Double, bandwidth: Double) -> Double {
        guard activeGB > 0 else { return 0 }
        return bandwidth / activeGB * 0.5
    }

    static func rate(sizeGB: Double, tokS: Double?, hw: Hardware) -> Rating {
        if sizeGB + 1.5 <= hw.gpuLimitGB { return (tokS ?? 30) >= 20 ? .good : .slow }
        if sizeGB + 0.6 <= hw.gpuLimitGB { return .tight }
        return .tooBig
    }

    /// Liest "35B-A3B" / "24B-A2B" / "27B" aus dem Namen: (gesamt, aktiv) in Milliarden.
    static func params(fromName name: String) -> (total: Double, active: Double)? {
        let s = name.replacingOccurrences(of: "_", with: "-")
        if let m = WebSearch.matches(s, #"(\d+(?:\.\d+)?)B-A(\d+(?:\.\d+)?)B"#).first,
           let t = Double(m[0]), let a = Double(m[1]) { return (t, a) }
        if let m = WebSearch.matches(s, #"(?:^|[-/])(\d+(?:\.\d+)?)B(?:[-_.]|$)"#).first, let t = Double(m[0]) { return (t, t) }
        return nil
    }
}

enum ModelCatalog {
    /// Nach Qualität sortiert: die Empfehlung ist das erste Modell, das passt.
    static let builtin: [ModelInfo] = [
        ModelInfo(id: "Ornith-1.5-35B-A3B-MLX-4bit", repo: "ornith-ai/Ornith-1.5-35B-A3B-MLX-4bit",
                  name: "Ornith 1.5 35B · 4 Bit",
                  summary: "Wie unten, aber in 4 Bit genauer und mit Bildverständnis. Ab 32 GB Arbeitsspeicher.",
                  sizeGB: 19.51, activeParamsB: 3.0, bitsPerWeight: 4.5, measuredTokSOnM4: nil,
                  hasMTP: false, license: "MIT", vision: true),
        ModelInfo(id: "Ornith-1.5-35B-A3B-oQ3e-mtp", repo: "mlx-works/Ornith-1.5-35B-A3B-oQ3e-mtp",
                  name: "Ornith 1.5 35B · 3 Bit",
                  summary: "Stärkstes Modell für 24 GB: Coding und Agenten (SWE-bench Verified 79 laut Hersteller). Mit MTP für schnelle Code-Edits.",
                  sizeGB: 16.59, activeParamsB: 3.0, bitsPerWeight: 3.5, measuredTokSOnM4: 43.1,
                  hasMTP: true, license: "MIT"),
        ModelInfo(id: "Qwen3.6-35B-A3B-UD-MLX-3bit", repo: "unsloth/Qwen3.6-35B-A3B-UD-MLX-3bit",
                  name: "Qwen 3.6 35B · 3 Bit · Vision",
                  summary: "Versteht Bilder (Screenshots, Fotos, Diagramme). Für Bilder die beste Wahl auf 24 GB; Text-Kontext in oMLX nur kurz.",
                  sizeGB: 17.39, activeParamsB: 3.0, bitsPerWeight: 3.5, measuredTokSOnM4: 36.4,
                  hasMTP: false, license: "Apache 2.0", vision: true),
        ModelInfo(id: "gemma-4-26b-a4b-it-4bit", repo: "mlx-community/gemma-4-26b-a4b-it-4bit",
                  name: "Gemma 4 26B · 4 Bit · Vision",
                  summary: "Googles MoE-Modell mit Bildverständnis und viel Weltwissen; schwächer beim Coden.",
                  sizeGB: 15.34, activeParamsB: 4.0, bitsPerWeight: 4.5, measuredTokSOnM4: nil,
                  hasMTP: false, license: "Apache 2.0", vision: true),
        ModelInfo(id: "LFM2.5-24B-A2B-MLX-4bit", repo: "LiquidAI/LFM2.5-24B-A2B-MLX-4bit",
                  name: "LFM2.5 24B · 4 Bit",
                  summary: "Schnelles Agenten-Modell von Liquid AI mit viel Speicherreserve für langen Kontext.",
                  sizeGB: 13.57, activeParamsB: 2.45, bitsPerWeight: 4.5, measuredTokSOnM4: nil,
                  hasMTP: false, license: "LFM Open (frei bis 10 Mio. $ Umsatz)"),
        ModelInfo(id: "Mellum2.1-12B-A2.5B-Thinking-6bit", repo: "mlx-community/Mellum2.1-12B-A2.5B-Thinking-6bit",
                  name: "Mellum 2.1 12B · 6 Bit",
                  summary: "Kleines Coding-Modell von JetBrains für Macs mit 16 GB.",
                  sizeGB: 9.87, activeParamsB: 2.5, bitsPerWeight: 6.5, measuredTokSOnM4: nil,
                  hasMTP: false, license: "Apache 2.0"),
    ]

    /// Katalog + selbst von Hugging Face hinzugefügte + sonst lokal gefundene Modelle.
    static var all: [ModelInfo] {
        let custom = CustomModels.load()
        let known = Set((builtin + custom).map(\.id))
        return builtin + custom + LocalModels.scan().filter { !known.contains($0.id) }
    }

    static func recommended(for hw: Hardware) -> ModelInfo? {
        builtin.filter { !$0.vision || $0.id.hasPrefix("Ornith") }.first { $0.fits(hw) }
    }

    static func model(id: String) -> ModelInfo? {
        all.first { $0.id == id }
    }
}

/// Von Hugging Face hinzugefügte Modelle (UserDefaults).
enum CustomModels {
    static func load() -> [ModelInfo] {
        guard let data = UserDefaults.standard.data(forKey: "customModels") else { return [] }
        return (try? JSONDecoder().decode([ModelInfo].self, from: data)) ?? []
    }

    static func add(_ model: ModelInfo) {
        var list = load().filter { $0.id != model.id }
        list.append(model)
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: "customModels") }
    }
}

/// Modellordner, die ohne die App dort gelandet sind (z. B. per tools/ oder hf download).
enum LocalModels {
    static func scan() -> [ModelInfo] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Paths.models, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir -> ModelInfo? in
            let cfgURL = dir.appendingPathComponent("config.json")
            guard let data = try? Data(contentsOf: cfgURL),
                  let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            // DFlash-/Draft-Modelle sind keine Chat-Modelle.
            if (cfg["dflash_config"] != nil) || dir.lastPathComponent.contains("DFlash") { return nil }
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let bytes = files.filter { $0.pathExtension == "safetensors" }
                .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            guard bytes > 0 else { return nil }
            let size = Double(bytes) / 1e9
            let bits = ((cfg["quantization"] as? [String: Any])?["bits"] as? Double) ?? 16
            let p = ModelFit.params(fromName: dir.lastPathComponent)
            let active = p?.active ?? size * 8 / (bits + 0.5)
            return ModelInfo(id: dir.lastPathComponent, repo: "", name: dir.lastPathComponent,
                             summary: "Lokal gefunden in \(Paths.models.lastPathComponent)/",
                             sizeGB: size, activeParamsB: active, bitsPerWeight: bits + 0.5, measuredTokSOnM4: nil,
                             hasMTP: dir.lastPathComponent.lowercased().contains("mtp"), license: "–",
                             vision: cfg["vision_config"] != nil, origin: "Lokal")
        }
    }
}
