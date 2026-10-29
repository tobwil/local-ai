import AppKit
import Foundation
import Observation

/// Sucht auf GitHub nach einer neueren Version (öffentliches Repo tobwil/local-ai) und bietet sie in der Seitenleiste an.
/// Fragt nur die Release-Liste ab – keine Daten über dich oder deine Gespräche. Abschaltbar in den Einstellungen.
@MainActor @Observable
final class UpdateChecker {
    struct Release: Equatable {
        let version: String
        let page: URL
        let dmg: URL?
    }

    static let latestURL = URL(string: "https://api.github.com/repos/tobwil/local-ai/releases/latest")!
    private(set) var available: Release?
    private(set) var lastResult = ""
    @ObservationIgnored private var lastCheck: Date?

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "updateCheck") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "updateCheck"); if !newValue { available = nil } }
    }

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// Beim Start und wenn die App nach vorne kommt – höchstens alle 6 Stunden (`force` für „Jetzt prüfen“).
    func check(force: Bool = false) async {
        guard enabled || force else { return }
        if !force, let lastCheck, Date().timeIntervalSince(lastCheck) < 6 * 3600 { return }
        lastCheck = Date()
        var req = URLRequest(url: Self.latestURL, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("KI-lokal/\(Self.current)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
            lastResult = "Keine Verbindung zu GitHub."
            return
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let dmg = (json["assets"] as? [[String: Any]] ?? [])
            .compactMap { $0["browser_download_url"] as? String }
            .first { $0.hasSuffix(".dmg") }
            .flatMap(URL.init(string:))
        guard Self.isNewer(version, than: Self.current) else {
            available = nil
            lastResult = "Du hast die neueste Version (\(Self.current))."
            return
        }
        lastResult = "Version \(version) ist verfügbar."
        // Einmal ausgeblendet: erst bei der nächsten Version wieder zeigen (außer beim manuellen Prüfen).
        if force || UserDefaults.standard.string(forKey: "updateDismissed") != version {
            available = Release(version: version, page: page, dmg: dmg)
        }
    }

    func dismiss() {
        if let v = available?.version { UserDefaults.standard.set(v, forKey: "updateDismissed") }
        available = nil
    }

    /// DMG im Browser laden (landet in „Downloads“); ohne DMG die Release-Seite öffnen.
    func download() {
        guard let r = available else { return }
        NSWorkspace.shared.open(r.dmg ?? r.page)
    }

    /// 0.10.0 > 0.9.1 – numerisch je Stelle.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
