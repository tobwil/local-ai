import Foundation

struct ModelInfo: Identifiable, Hashable {
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

    var folder: URL { Paths.models.appendingPathComponent(id) }

    /// Gewichte plus Luft für Prompt-Verarbeitung und KV-Cache.
    var neededGPUGB: Double { sizeGB + 1.5 }

    func fits(_ hw: Hardware) -> Bool { neededGPUGB <= hw.gpuLimitGB }

    /// tok/s auf dieser Hardware: gemessen auf M4 und mit der Bandbreite skaliert,
    /// sonst aus den aktiven Gewichten geschätzt (Wirkungsgrad aus der Ornith-Messung).
    func estimatedTokS(_ hw: Hardware) -> Double? {
        guard let bw = hw.bandwidthGBs else { return nil }
        if let m = measuredTokSOnM4 { return m * bw / 120 }
        let gbPerToken = activeParamsB * bitsPerWeight / 8
        return bw / gbPerToken * 0.47
    }

    var isInstalled: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.appendingPathComponent("config.json").path),
              !fm.fileExists(atPath: folder.appendingPathComponent(Downloads.incompleteMarker).path),
              let files = try? fm.contentsOfDirectory(atPath: folder.path) else { return false }
        return files.contains { $0.hasSuffix(".safetensors") }
    }
}

enum ModelCatalog {
    /// Nach Qualität sortiert: die Empfehlung ist das erste Modell, das passt.
    static let all: [ModelInfo] = [
        ModelInfo(id: "Ornith-1.5-35B-A3B-MLX-4bit", repo: "ornith-ai/Ornith-1.5-35B-A3B-MLX-4bit",
                  name: "Ornith 1.5 35B · 4 Bit",
                  summary: "Wie unten, aber in 4 Bit etwas genauer. Ab 32 GB Arbeitsspeicher.",
                  sizeGB: 19.51, activeParamsB: 3.0, bitsPerWeight: 4.5, measuredTokSOnM4: nil,
                  hasMTP: false, license: "MIT"),
        ModelInfo(id: "Ornith-1.5-35B-A3B-oQ3e-mtp", repo: "mlx-works/Ornith-1.5-35B-A3B-oQ3e-mtp",
                  name: "Ornith 1.5 35B · 3 Bit",
                  summary: "Stärkstes Modell für 24 GB: Coding und Agenten (SWE-bench Verified 79 laut Hersteller). Mit MTP für schnelle Code-Edits.",
                  sizeGB: 16.59, activeParamsB: 3.0, bitsPerWeight: 3.5, measuredTokSOnM4: 43.1,
                  hasMTP: true, license: "MIT"),
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

    static func recommended(for hw: Hardware) -> ModelInfo? {
        all.first { $0.fits(hw) }
    }

    static func model(id: String) -> ModelInfo? {
        all.first { $0.id == id }
    }
}
