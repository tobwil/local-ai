import Foundation
import Observation

/// Vorschau-Panel neben dem Chat (wie Artifacts/Canvas bei Claude): zeigt Dateien, die der Agent schreibt –
/// HTML und Spiele live, Markdown gerendert, Bilder/PDF per QuickLook, Code mit Zeilennummern.
@MainActor @Observable
final class PreviewStore {
    enum Kind { case web, markdown, quickLook, code }

    private(set) var files: [URL] = []
    private(set) var selected: URL?
    var isOpen = false
    /// Canvas: die gezeigte Text-/Markdown-/Code-Datei direkt bearbeiten.
    var editing = false
    /// Canvas für Markdown: formatiert (false) oder als Markdown-Quelltext (true).
    var sourceMode = false
    /// Steigt, wenn die gezeigte Datei (oder ein Skript/Stylesheet daneben) neu geschrieben wurde → neu laden.
    private(set) var revision = 0
    /// Fehler aus der Browser-Konsole der gezeigten Seite.
    var consoleErrors: [String] = []
    var autoOpen = UserDefaults.standard.object(forKey: "previewAutoOpen") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoOpen, forKey: "previewAutoOpen") }
    }

    static let snippetDir = Paths.base.appendingPathComponent("previews")

    static func kind(of url: URL) -> Kind {
        switch url.pathExtension.lowercased() {
        case "html", "htm", "svg": return .web
        case "md", "markdown": return .markdown
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "pdf", "mp4", "mov", "mp3", "m4a", "wav",
             "docx", "xlsx", "pptx", "key", "pages", "numbers", "rtf": return .quickLook
        default: return .code
        }
    }

    /// Lohnt eine sichtbare Vorschau (im Gegensatz zu reinem Code)?
    static func isVisual(_ url: URL) -> Bool { kind(of: url) != .code }

    func show(_ url: URL) {
        add(url)
        if selected == url { revision += 1 } else { select(url) }
        isOpen = true
    }

    func select(_ url: URL) {
        if url != selected { editing = false }
        selected = url
        consoleErrors = []
        revision += 1
        seenModified = Self.modified(url)
    }

    /// Änderungsdatum der gezeigten Datei beim letzten Laden – erkennt Änderungen per Shell (sed, cp …).
    @ObservationIgnored private var seenModified: Date?

    /// Eigene Änderung im Canvas gespeichert – nicht als fremde Änderung neu laden.
    func noteOwnWrite() { seenModified = selected.flatMap(Self.modified) }

    /// Kann diese Datei im Canvas bearbeitet werden (Text statt Bild/PDF)?
    static func isEditable(_ url: URL) -> Bool {
        let k = kind(of: url)
        return k == .markdown || k == .code || ["html", "htm", "svg"].contains(url.pathExtension.lowercased())
    }

    /// Canvas mit einem neuen Markdown-Dokument öffnen (Werkzeug open_canvas).
    func openCanvas(_ url: URL) {
        show(url)
        editing = true
    }

    /// Nach jedem Werkzeug-Schritt: Hat sich die gezeigte Datei geändert, neu laden.
    func reloadIfChanged() {
        guard let sel = selected, let m = Self.modified(sel), m != seenModified else { return }
        seenModified = m
        consoleErrors = []
        revision += 1
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Vom Agenten geschrieben oder geändert.
    func fileWritten(_ url: URL) {
        add(url)
        if url == selected {
            revision += 1
            seenModified = Self.modified(url)
        } else if let sel = selected, Self.kind(of: sel) == .web, Self.kind(of: url) == .code,
                  url.path.hasPrefix(sel.deletingLastPathComponent().path + "/") {
            // Skript oder Stylesheet der gezeigten Seite: Seite neu laden, statt auf den Code zu wechseln.
            consoleErrors = []
            revision += 1
        } else if Self.isVisual(url) || selected == nil {
            select(url)
            if autoOpen && Self.isVisual(url) { isOpen = true }
        }
    }

    /// Code-Block aus dem Chat (HTML, SVG, Markdown) als Datei ablegen und zeigen.
    func showSnippet(_ code: String, language: String) {
        let ext: String
        switch language.lowercased() {
        case "svg": ext = "svg"
        case "md", "markdown": ext = "md"
        default: ext = "html"
        }
        try? FileManager.default.createDirectory(at: Self.snippetDir, withIntermediateDirectories: true)
        let url = Self.snippetDir.appendingPathComponent("vorschau-\(String(UInt(bitPattern: code.hashValue), radix: 36)).\(ext)")
        try? code.write(to: url, atomically: true, encoding: .utf8)
        show(url)
    }

    func close(_ url: URL) {
        files.removeAll { $0 == url }
        if selected == url {
            selected = files.last
            consoleErrors = []
            revision += 1
        }
        if files.isEmpty { isOpen = false }
    }

    func reload() {
        consoleErrors = []
        revision += 1
    }

    func clear() {
        files = []
        selected = nil
        consoleErrors = []
        isOpen = false
    }

    private func add(_ url: URL) {
        files.removeAll { $0 == url }
        files.append(url)
        if files.count > 12 { files.removeFirst(files.count - 12) }
    }

    /// Pfad aus den Argumenten von write_file/edit_file (JSON-Text, wie im Chat gezeigt).
    static func writtenPath(tool: String, arguments: String, workspace: URL) -> URL? {
        guard tool == "write_file" || tool == "edit_file",
              let json = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
              let path = json["path"] as? String else { return nil }
        return BuiltinTools.resolve(path, in: workspace)
    }
}
