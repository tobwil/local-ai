import Foundation

/// Wohin eine Anfrage geht: lokal (oMLX), Anthropic oder ein OpenAI-kompatibler Dienst.
/// Externe Modelle haben IDs der Form "anthropic:claude-opus-5-5" bzw. "openai:gpt-5.5".
enum Endpoint {
    case local
    case anthropic(key: String, base: URL)
    case openai(key: String, base: URL)

    static let anthropicBase = URL(string: "https://api.anthropic.com")!
    static let openAIDefaultBase = URL(string: "https://api.openai.com/v1")!

    static func resolve(_ modelID: String) -> (endpoint: Endpoint, model: String) {
        if modelID.hasPrefix("anthropic:") {
            return (.anthropic(key: Keychain.get("anthropicKey") ?? "", base: anthropicBase), String(modelID.dropFirst(10)))
        }
        if modelID.hasPrefix("openai:") {
            let base = URL(string: UserDefaults.standard.string(forKey: "openaiBaseURL") ?? "") ?? openAIDefaultBase
            return (.openai(key: Keychain.get("openaiKey") ?? "", base: base), String(modelID.dropFirst(7)))
        }
        return (.local, modelID)
    }

    var isCloud: Bool { if case .local = self { return false }; return true }
}

enum CloudModels {
    static func isCloud(_ id: String) -> Bool { id.hasPrefix("anthropic:") || id.hasPrefix("openai:") }

    static func displayName(_ id: String) -> String {
        if id.hasPrefix("anthropic:") { return "Anthropic · " + id.dropFirst(10) }
        if id.hasPrefix("openai:") {
            let host = URL(string: UserDefaults.standard.string(forKey: "openaiBaseURL") ?? "")?.host ?? "OpenAI"
            return (host == "api.openai.com" ? "OpenAI" : host) + " · " + id.dropFirst(7)
        }
        return ModelCatalog.model(id: id)?.name ?? id
    }

    /// Zuletzt geladene Modelllisten (für Auswahlfelder).
    static var anthropic: [String] { UserDefaults.standard.stringArray(forKey: "anthropicModels") ?? [] }
    static var openai: [String] { UserDefaults.standard.stringArray(forKey: "openaiModels") ?? [] }
    static var all: [String] { anthropic.map { "anthropic:\($0)" } + openai.map { "openai:\($0)" } }

    /// GET /v1/models beim jeweiligen Anbieter; speichert die Liste.
    static func refresh(anthropic: Bool) async throws -> [String] {
        var req: URLRequest
        if anthropic {
            req = URLRequest(url: Endpoint.anthropicBase.appendingPathComponent("v1/models"))
            req.setValue(Keychain.get("anthropicKey") ?? "", forHTTPHeaderField: "x-api-key")
            req.setValue(AnthropicClient.version, forHTTPHeaderField: "anthropic-version")
        } else {
            let base = URL(string: UserDefaults.standard.string(forKey: "openaiBaseURL") ?? "") ?? Endpoint.openAIDefaultBase
            req = URLRequest(url: base.appendingPathComponent("models"))
            req.setValue("Bearer \(Keychain.get("openaiKey") ?? "")", forHTTPHeaderField: "Authorization")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.http(status, String(decoding: data, as: UTF8.self))
        }
        let ids = (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }.sorted()
        UserDefaults.standard.set(ids, forKey: anthropic ? "anthropicModels" : "openaiModels")
        return ids
    }
}
