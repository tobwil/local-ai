import AppKit
import Foundation

/// Protokoll aller Werkzeug-Aufrufe (auch im YOLO-Modus und in Automationen) als JSON Lines.
enum ActionLog {
    static let file = Paths.base.appendingPathComponent("logs/actions.jsonl")
    private static let queue = DispatchQueue(label: "de.kisruptiv.kilokal.actionlog")

    struct Entry: Codable, Identifiable {
        var id: String { "\(time.timeIntervalSince1970)-\(tool)" }
        let time: Date
        let context: String      // "Chat", "Automation: …", "Sub-Agent"
        let tool: String
        let source: String
        let arguments: String
        /// "frei", "freigegeben", "abgelehnt", "YOLO", "Notbremse → freigegeben", "unbeaufsichtigt"
        let approval: String
        let ok: Bool
        let seconds: Double
        let result: String
    }

    static func append(_ e: Entry) {
        queue.async {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            guard var line = try? enc.encode(e) else { return }
            line.append(0x0A)
            if let h = try? FileHandle(forWritingTo: file) {
                h.seekToEndOfFile()
                h.write(line)
                try? h.close()
            } else {
                try? line.write(to: file)
            }
            rotateIfNeeded()
        }
    }

    static func log(context: String, tool: String, source: String, arguments: String, approval: String,
                    ok: Bool, started: Date, result: String) {
        append(Entry(time: started, context: context, tool: tool, source: source,
                     arguments: String(arguments.prefix(2000)), approval: approval, ok: ok,
                     seconds: Date().timeIntervalSince(started), result: String(result.prefix(500))))
    }

    static func recent(_ n: Int = 300) -> [Entry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).suffix(n).compactMap { try? dec.decode(Entry.self, from: Data($0)) }.reversed()
    }

    /// Ab 5 MB in actions.1.jsonl verschieben.
    private static func rotateIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard size > 5_000_000 else { return }
        let old = file.deletingPathExtension().appendingPathExtension("1.jsonl")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: file, to: old)
    }
}

/// Absturzberichte von macOS (DiagnosticReports) erkennen und zusammenfassen.
enum CrashReports {
    struct Report: Identifiable {
        let url: URL
        let date: Date
        let exception: String
        let frames: [String]
        var id: String { url.path }

        var summary: String {
            "**\(exception)** am \(date.formatted(date: .abbreviated, time: .shortened))\n\n```\n\(frames.joined(separator: "\n"))\n```"
        }
    }

    static let dir = Paths.home.appendingPathComponent("Library/Logs/DiagnosticReports")

    /// Neue Berichte seit dem letzten Prüfen (nur Berichte dieser App).
    static func unseen() -> [Report] {
        let last = UserDefaults.standard.double(forKey: "crashCheck")
        // Erster Start: alte Berichte (z. B. aus Entwicklungsversionen) nicht anzeigen.
        if last == 0 { markSeen(); return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("KI lokal") && $0.pathExtension == "ips" }
            .compactMap { url -> Report? in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                guard date.timeIntervalSince1970 > last else { return nil }
                return parse(url, date: date)
            }
            .sorted { $0.date > $1.date }
    }

    static func markSeen() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "crashCheck")
    }

    /// Ausnahme und die obersten Stack-Frames des abgestürzten Threads – ohne persönliche Daten.
    static func parse(_ url: URL, date: Date) -> Report? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8), let nl = raw.firstIndex(of: "\n"),
              let body = try? JSONSerialization.jsonObject(with: Data(raw[raw.index(after: nl)...].utf8)) as? [String: Any] else { return nil }
        // Nur Abstürze der normal gestarteten App melden – nicht von Läufen aus dem Terminal (Selbsttest, --agent).
        if let parent = body["parentProc"] as? String, parent != "launchd" { return nil }
        let exc = body["exception"] as? [String: Any]
        let exception = [exc?["type"] as? String, exc?["signal"] as? String].compactMap { $0 }.joined(separator: " / ")
        let images = body["usedImages"] as? [[String: Any]] ?? []
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = body["faultingThread"] as? Int ?? 0
        let frames = (faulting < threads.count ? threads[faulting]["frames"] as? [[String: Any]] : nil) ?? []
        let lines = frames.prefix(12).map { f -> String in
            let img = (f["imageIndex"] as? Int).flatMap { $0 < images.count ? images[$0]["name"] as? String : nil } ?? "?"
            return "\(img)  \(f["symbol"] as? String ?? "?")"
        }
        return Report(url: url, date: date, exception: exception.isEmpty ? "Absturz" : exception, frames: lines)
    }

    /// Vorausgefülltes GitHub-Issue (der Nutzer sieht es vor dem Absenden und schickt es selbst ab).
    static func issueURL(_ r: Report) -> URL? {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let body = """
        **Version:** \(version) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(Hardware.detect().chip)

        \(r.summary)

        **Was hast du gerade gemacht?**

        """
        var c = URLComponents(string: "https://github.com/tobwil/local-ai/issues/new")!
        c.queryItems = [URLQueryItem(name: "title", value: "Absturz: \(r.exception)"), URLQueryItem(name: "body", value: body)]
        return c.url
    }
}
