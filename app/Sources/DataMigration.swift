import Foundation

/// Einmaliger Umzug der Daten aus dem früheren Ordner ~/.strata-lite nach ~/.kilokal.
/// Umbenennen auf derselben Platte geht sofort (auch mit vielen GB Modellen); danach werden die absoluten
/// Pfade in den Python-Umgebungen der Engine und in den oMLX-Einstellungen angepasst.
enum DataMigration {
    static let legacy = Paths.home.appendingPathComponent(".strata-lite")

    static func run() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: Paths.base.path) else { return }
        do { try fm.moveItem(at: legacy, to: Paths.base) } catch { return }
        for dir in [Paths.base.appendingPathComponent("omlx-venv"), Paths.base.appendingPathComponent("venv"),
                    Paths.home.appendingPathComponent(".omlx")] {
            replacePaths(in: dir, from: legacy.path, to: Paths.base.path)
        }
    }

    /// In allen Textdateien (bis 2 MB) des Ordners `from` durch `to` ersetzen – an Ort und Stelle, damit
    /// Ausführrechte (Skripte in bin/) erhalten bleiben.
    private static func replacePaths(in dir: URL, from: String, to: String) {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) else { return }
        let needle = Data(from.utf8)
        while let url = e.nextObject() as? URL {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard v?.isRegularFile == true, v?.isSymbolicLink != true, (v?.fileSize ?? 0) < 2_000_000,
                  let data = try? Data(contentsOf: url), data.range(of: needle) != nil,
                  let text = String(data: data, encoding: .utf8) else { continue }
            try? Data(text.replacingOccurrences(of: from, with: to).utf8).write(to: url)
        }
    }
}
