import Foundation
import Observation

/// Ein MLX-Repo auf Hugging Face mit allem, was für die Bewertung nötig ist.
struct HubModel: Identifiable, Hashable {
    let id: String          // "owner/name"
    let downloads: Int
    let likes: Int
    let modelType: String
    let sizeGB: Double
    let totalParamsB: Double?
    let activeParamsB: Double?
    let vision: Bool
    let license: String
    let lastModified: String

    var name: String { String(id.split(separator: "/").last ?? Substring(id)) }
    var author: String { String(id.split(separator: "/").first ?? "") }
    var isMoE: Bool { (activeParamsB ?? 0) < (totalParamsB ?? 0) }

    /// GB, die pro Token gelesen werden müssen.
    var activeGB: Double {
        guard let t = totalParamsB, let a = activeParamsB, t > 0 else { return sizeGB }
        return sizeGB * a / t
    }

    func estimatedTokS(_ hw: Hardware) -> Double? {
        hw.bandwidthGBs.map { ModelFit.tokS(activeGB: activeGB, bandwidth: $0) }
    }

    func rating(_ hw: Hardware) -> ModelFit.Rating {
        ModelFit.rate(sizeGB: sizeGB, tokS: estimatedTokS(hw), hw: hw)
    }

    func asModelInfo() -> ModelInfo {
        let total = totalParamsB ?? sizeGB * 2
        return ModelInfo(id: name, repo: id, name: name, summary: "Von Hugging Face (\(author)) · \(modelType)",
                         sizeGB: sizeGB, activeParamsB: activeParamsB ?? total,
                         bitsPerWeight: total > 0 ? sizeGB * 8 / total : 4.5, measuredTokSOnM4: nil,
                         hasMTP: name.lowercased().contains("mtp"), license: license, vision: vision, origin: "Hugging Face")
    }
}

@MainActor @Observable
final class HubBrowser {
    enum Sort: String, CaseIterable, Identifiable {
        case trendingScore, downloads, likes, lastModified
        var id: String { rawValue }
        var label: String {
            switch self {
            case .trendingScore: return "Im Trend"
            case .downloads: return "Downloads"
            case .likes: return "Likes"
            case .lastModified: return "Neueste"
            }
        }
    }

    var query = ""
    var sort: Sort = .trendingScore
    var onlyFitting = true
    var onlyVision = false
    private(set) var results: [HubModel] = []
    private(set) var loading = false
    private(set) var error: String?
    private var task: Task<Void, Never>?

    func search(hw: Hardware) {
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: .milliseconds(300))   // Tippen abwarten
            guard !Task.isCancelled else { return }
            loading = true
            error = nil
            do {
                let found = try await Self.fetch(query: query, sort: sort)
                guard !Task.isCancelled else { return }
                results = found.filter { m in
                    (!onlyFitting || m.rating(hw) >= .tight) && (!onlyVision || m.vision)
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            loading = false
        }
    }

    nonisolated static func fetch(query: String, sort: Sort) async throws -> [HubModel] {
        var comps = URLComponents(string: "https://huggingface.co/api/models")!
        var items = [URLQueryItem(name: "filter", value: "mlx"), URLQueryItem(name: "sort", value: sort.rawValue),
                     URLQueryItem(name: "direction", value: "-1"), URLQueryItem(name: "limit", value: "80")]
        if !query.isEmpty { items.append(URLQueryItem(name: "search", value: query)) }
        for e in ["safetensors", "downloads", "likes", "pipeline_tag", "config", "tags", "lastModified"] {
            items.append(URLQueryItem(name: "expand[]", value: e))
        }
        comps.queryItems = items
        let (data, resp) = try await URLSession.shared.data(from: comps.url!)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw URLError(.badServerResponse)
        }
        return list.compactMap(parse)
    }

    /// Bytes pro Parameter je Datentyp (für nicht quantisierte Tensoren).
    private static let dtypeBytes: [String: Double] = [
        "F32": 4, "BF16": 2, "F16": 2, "U16": 2, "I16": 2, "U8": 1, "I8": 1, "F8_E4M3": 1, "F8_E5M2": 1, "BOOL": 1, "I64": 8, "F64": 8,
    ]

    private nonisolated static func parse(_ m: [String: Any]) -> HubModel? {
        guard let id = m["id"] as? String,
              let params = (m["safetensors"] as? [String: Any])?["parameters"] as? [String: Any] else { return nil }
        let cfg = m["config"] as? [String: Any] ?? [:]
        // Hugging Face zählt bei MLX-Quantisierung die entpackten Gewichte (unter U32).
        // Größe = Gewichte × Bits/8 + Skalen/Biases (bf16 je 64er-Gruppe = 4 Byte / 64 Gewichte).
        let bits = ((cfg["quantization_config"] as? [String: Any])?["bits"] as? Double)
            ?? ((cfg["quantization"] as? [String: Any])?["bits"] as? Double)
        var bytes = 0.0
        for (dtype, count) in params {
            let n = count as? Double ?? 0
            if dtype == "U32" || dtype == "I32" {
                bytes += bits.map { n * ($0 / 8 + 4.0 / 64) } ?? n * 4
            } else {
                bytes += n * (dtypeBytes[dtype] ?? 2)
            }
        }
        guard bytes > 0 else { return nil }
        let totalParams = (m["safetensors"] as? [String: Any])?["total"] as? Double
        let template = cfg["chat_template_jinja"] as? String ?? ""
        let tags = m["tags"] as? [String] ?? []
        let vision = (m["pipeline_tag"] as? String) == "image-text-to-text"
            || template.contains("image_pad") || template.contains("<image>") || template.contains("<start_of_image>")
        // Gesamtzahl exakt aus den Metadaten, Anteil aktiver Parameter aus dem Namen ("35B-A3B").
        let p = ModelFit.params(fromName: id)
        let total = totalParams.map { $0 / 1e9 } ?? p?.total
        let active = p.flatMap { p in total.map { $0 * p.active / p.total } } ?? total
        return HubModel(id: id, downloads: m["downloads"] as? Int ?? 0, likes: m["likes"] as? Int ?? 0,
                        modelType: cfg["model_type"] as? String ?? "?", sizeGB: bytes / 1e9,
                        totalParamsB: total, activeParamsB: active, vision: vision,
                        license: tags.first { $0.hasPrefix("license:") }.map { String($0.dropFirst(8)) } ?? "–",
                        lastModified: String((m["lastModified"] as? String ?? "").prefix(10)))
    }
}

/// Welche Architekturen (model_type) die installierte oMLX-Engine kennt – aus mlx-lm und mlx-vlm gelesen.
enum EngineSupport {
    static let modelTypes: Set<String> = {
        let fm = FileManager.default
        let lib = Paths.base.appendingPathComponent("omlx-venv/lib")
        guard let py = (try? fm.contentsOfDirectory(atPath: lib.path))?.first(where: { $0.hasPrefix("python") }) else { return [] }
        let site = lib.appendingPathComponent(py).appendingPathComponent("site-packages")
        var types = Set<String>()
        for file in (try? fm.contentsOfDirectory(atPath: site.appendingPathComponent("mlx_lm/models").path)) ?? []
        where file.hasSuffix(".py") { types.insert(String(file.dropLast(3))) }
        for dir in (try? fm.contentsOfDirectory(atPath: site.appendingPathComponent("mlx_vlm/models").path)) ?? [] {
            types.insert(dir)
        }
        return types
    }()

    /// nil = unbekannt (Engine nicht gefunden).
    static func supports(_ modelType: String) -> Bool? {
        guard !modelTypes.isEmpty else { return nil }
        let t = modelType.lowercased()
        return modelTypes.contains(t) || modelTypes.contains(t.replacingOccurrences(of: "_text", with: ""))
    }
}
