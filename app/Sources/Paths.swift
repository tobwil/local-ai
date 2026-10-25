import Foundation

/// Wo die Engine, die Modelle und die oMLX-Einstellungen liegen.
/// Die Struktur entspricht den Skripten in tools/ (~/.kilokal).
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let base = home.appendingPathComponent(".kilokal")
    static let models = base.appendingPathComponent("models")
    static let omlx = base.appendingPathComponent("omlx-venv/bin/omlx")
    static let kvCache = base.appendingPathComponent("kv-cache")
    static let omlxModelSettings = home.appendingPathComponent(".omlx/model_settings.json")

    static let port = 8000
    static let server = URL(string: "http://127.0.0.1:\(port)")!
    static let openAIBase = server.appendingPathComponent("v1")
}
