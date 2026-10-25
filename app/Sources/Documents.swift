import AppKit
import Foundation
import WebKit

/// Dokumente erzeugen (PDF, Word, RTF, HTML aus Markdown) und angehängte Dokumente als Text lesen.
enum Documents {
    // MARK: Anhänge

    static let attachable: Set<String> = Store.textExtensions.union(Store.richExtensions).union(["pages", "key", "numbers"])

    /// Inhalt einer angehängten Datei für die Nachricht: Text aus PDF/Word/Excel/PowerPoint/Text, ZIP entpackt mit
    /// Inhaltsverzeichnis, alles andere mit Typ und Größe. Lange Inhalte gekürzt, mit Hinweis auf read_file.
    static func attachmentText(_ url: URL, limit: Int) -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "zip" {
            guard let dir = try? OfficeFiles.unpack(url) else { return "📎 \(url.lastPathComponent) – ZIP ließ sich nicht entpacken." }
            let files = (FileManager.default.enumerator(atPath: dir.path)?.allObjects as? [String] ?? []).filter { !$0.hasPrefix("__MACOSX") }
            return "📎 Angehängt: \(url.lastPathComponent) – entpackt nach \(dir.path) (\(files.count) Einträge). "
                + "Dateien mit read_file/list_directory öffnen.\n" + files.prefix(150).map { "- \($0)" }.joined(separator: "\n")
                + (files.count > 150 ? "\n…" : "")
        }
        if Transcription.audioExtensions.contains(ext) {
            return "📎 Angehängt: Aufnahme \(url.lastPathComponent) (\(url.path)) – mit dem Werkzeug transcribe lokal in Text umwandeln."
        }
        let extracted: String? = switch ext {
        case "xlsx", "xlsm": OfficeFiles.xlsxText(url)
        case "pptx": OfficeFiles.pptxText(url)
        default: Store.textExtensions.contains(ext) || Store.richExtensions.contains(ext) ? Store.extract(url) : nil
        }
        let text = (extracted ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return "📎 Angehängt: \(url.lastPathComponent) (\(url.path), \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))"
                + " – kein Text direkt lesbar. Bei Bedarf mit run_shell untersuchen (z. B. file, unzip -l, strings)."
        }
        let cut = text.count > limit
        return "📎 Angehängt: \(url.lastPathComponent) (\(url.path))\(cut ? " – gekürzt auf \(limit) von \(text.count) Zeichen, Rest mit read_file lesen" : "")\n"
            + "<dokument name=\"\(url.lastPathComponent)\">\n\(text.prefix(limit))\n</dokument>"
    }

    // MARK: Canvas

    static func canvasTool(_ workspace: @escaping () -> URL, onOpen: @escaping @MainActor (URL) -> Void) -> AgentTool {
        AgentTool(name: "open_canvas",
                  description: "Öffnet rechts neben dem Chat einen bearbeitbaren Canvas mit Markdown-Text – für Entwürfe, Briefe, Konzepte, Angebote, Artikel oder Code, die der Nutzer weiter bearbeiten will (auch wenn er „Canvas“ oder „editierbar“ sagt). Der Nutzer tippt direkt darin und kann als PDF/Word exportieren. Spätere Änderungen mit edit_file – vorher read_file, weil der Nutzer selbst geändert haben kann.",
                  parameters: schema([("title", "string", "Titel, wird zum Dateinamen"),
                                      ("content", "string", "Inhalt als Markdown (oder Code)"),
                                      ("extension", "string", "Dateiendung, Standard md (z. B. md, txt, html, py)")],
                                     required: ["title", "content"]),
                  needsApproval: false, source: "Canvas") { args in
            let title = try BuiltinTools.string(args, "title")
            let ext = (args["extension"] as? String).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }.flatMap { $0.isEmpty ? nil : $0 } ?? "md"
            let base = title.replacing(/[\/:*?"<>|]+/, with: "-").trimmingCharacters(in: .whitespaces)
            // Nie eine bestehende Datei überschreiben: bei Bedarf „Titel 2.md“
            var url = workspace().appendingPathComponent("\(base.isEmpty ? "Canvas" : base).\(ext)")
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = workspace().appendingPathComponent("\(base) \(n).\(ext)"); n += 1
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try BuiltinTools.string(args, "content").write(to: url, atomically: true, encoding: .utf8)
            await onOpen(url)
            return "Canvas geöffnet: \(url.path). Der Nutzer kann ihn jetzt bearbeiten; für Änderungen erst read_file, dann edit_file."
        }
    }

    // MARK: Erzeugen

    static func tool(_ workspace: @escaping () -> URL, onCreated: @escaping @MainActor (URL) -> Void) -> AgentTool {
        AgentTool(name: "create_document",
                  description: "Erstellt ein Dokument aus Markdown: PDF (A4, mit Seitenumbrüchen), Word (.docx), Excel (.xlsx – jede Markdown-Tabelle wird ein Tabellenblatt), CSV, RTF oder HTML – im KIsruptiv-Stil. Das Format ergibt sich aus der Dateiendung. Für Berichte, Angebote, Zusammenfassungen, Handouts, Tabellen.",
                  parameters: schema([("path", "string", "Zieldatei, z. B. bericht.pdf, angebot.docx, kosten.xlsx (relativ zum Arbeitsordner)"),
                                      ("content", "string", "Inhalt als Markdown (# Überschriften, Listen, | Tabellen |, **fett**)"),
                                      ("title", "string", "Dokumenttitel (optional, sonst erste Überschrift)")],
                                     required: ["path", "content"]),
                  needsApproval: true, source: "Dokumente") { args in
            let url = BuiltinTools.resolve(try BuiltinTools.string(args, "path"), in: workspace())
            let markdown = try BuiltinTools.string(args, "content")
            let title = args["title"] as? String
            try await create(markdown: markdown, title: title, at: url)
            await onCreated(url)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            var info = "Erstellt: \(url.path) (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))"
            if url.pathExtension.lowercased() == "pdf", let pages = PDFPageCount.of(url) { info += ", \(pages) Seite(n)" }
            return info + ". Die Vorschau zeigt das Dokument."
        }
    }

    @MainActor
    static func create(markdown: String, title: String?, at url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let html = MarkdownHTML.page(markdown, title: title)
        switch url.pathExtension.lowercased() {
        case "pdf":
            try await PDFRenderer.render(html: html, to: url)
        case "docx", "rtf", "odt":
            let attributed = try NSAttributedString(data: Data(html.utf8),
                                                    options: [.documentType: NSAttributedString.DocumentType.html,
                                                              .characterEncoding: String.Encoding.utf8.rawValue],
                                                    documentAttributes: nil)
            let type: NSAttributedString.DocumentType = switch url.pathExtension.lowercased() {
            case "docx": .officeOpenXML
            case "odt": .openDocument
            default: .rtf
            }
            let data = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                           documentAttributes: [.documentType: type])
            try data.write(to: url, options: .atomic)
        case "html", "htm":
            try html.write(to: url, atomically: true, encoding: .utf8)
        case "xlsx":
            try OfficeFiles.writeXLSX(markdown: markdown, to: url)
        case "csv":
            // Markdown-Tabelle → CSV (Semikolon, wie Excel in Deutschland es erwartet)
            let rows = markdown.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("|") && !$0.allSatisfy { "|-: ".contains($0) } }
                .map { line in line.split(separator: "|").map { "\"" + $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ";") }
            try (rows.isEmpty ? markdown : rows.joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8)
        case "md", "markdown", "txt":
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        default:
            throw ToolError.invalid("Unbekanntes Format .\(url.pathExtension) – möglich: pdf, docx, xlsx, csv, rtf, odt, html, md")
        }
    }
}

enum PDFPageCount {
    static func of(_ url: URL) -> Int? {
        guard let doc = CGPDFDocument(url as CFURL) else { return nil }
        return doc.numberOfPages
    }
}

/// HTML → PDF mit echten A4-Seiten: WebKit druckt in eine Datei (ohne Dialog, in einem unsichtbaren Fenster).
@MainActor
final class PDFRenderer: NSObject, WKNavigationDelegate {
    private var loaded: CheckedContinuation<Void, Error>?
    private var printed: CheckedContinuation<Void, Never>?
    private static var active: [PDFRenderer] = []

    static func render(html: String, to url: URL) async throws {
        let r = PDFRenderer()
        active.append(r)
        defer { active.removeAll { $0 === r } }
        try await r.run(html: html, to: url)
    }

    private func run(html: String, to url: URL) async throws {
        let a4 = NSSize(width: 595, height: 842)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: a4),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let web = WKWebView(frame: NSRect(origin: .zero, size: a4))
        web.navigationDelegate = self
        window.contentView = web
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loaded = c
            web.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
        }
        try? FileManager.default.removeItem(at: url)
        let info = NSPrintInfo()
        info.paperSize = a4
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 0; info.rightMargin = 0
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let op = web.printOperation(with: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = web.bounds
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            printed = c
            op.runModal(for: window, delegate: self, didRun: #selector(printDone(_:success:contextInfo:)), contextInfo: nil)
        }
        window.close()
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError.invalid("PDF konnte nicht erzeugt werden") }
    }

    @objc private func printDone(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        printed?.resume()
        printed = nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { loaded?.resume(); loaded = nil }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { loaded?.resume(throwing: error); loaded = nil }
    }
}

/// Kleiner Markdown→HTML-Umsetzer für Dokumente (Überschriften, Absätze, Listen, Tabellen, Zitate, Code, Links).
enum MarkdownHTML {
    static func page(_ md: String, title: String?) -> String {
        let docTitle = title ?? md.components(separatedBy: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? "Dokument"
        return """
        <!doctype html><html lang="de"><head><meta charset="utf-8"><title>\(escape(docTitle))</title><style>
        @page { size: A4; margin: 18mm 18mm 20mm 18mm; }
        body { font: 11pt/1.5 -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; color: #1d2433; margin: 0 48px; }
        h1 { font-size: 22pt; color: #274060; margin: 0 0 6pt; padding-bottom: 6pt; border-bottom: 3px solid #FCC419; }
        h2 { font-size: 15pt; color: #274060; margin: 18pt 0 6pt; }
        h3 { font-size: 12.5pt; color: #274060; margin: 14pt 0 4pt; }
        p { margin: 0 0 8pt; } ul, ol { margin: 0 0 8pt; padding-left: 18pt; } li { margin: 2pt 0; }
        table { border-collapse: collapse; width: 100%; margin: 8pt 0 12pt; font-size: 10pt; page-break-inside: avoid; }
        th { background: #274060; color: #fff; text-align: left; padding: 5pt 7pt; }
        td { border-bottom: 1px solid #d9dee8; padding: 5pt 7pt; vertical-align: top; }
        tr:nth-child(even) td { background: #f4f6fa; }
        blockquote { margin: 8pt 0; padding: 4pt 10pt; border-left: 3px solid #7590BF; color: #4a5568; background: #f4f6fa; }
        code { font: 9.5pt Menlo, monospace; background: #f0f2f6; padding: 1px 3px; border-radius: 3px; }
        pre { background: #f0f2f6; padding: 8pt; border-radius: 4px; white-space: pre-wrap; page-break-inside: avoid; }
        pre code { background: none; padding: 0; }
        hr { border: none; border-top: 1px solid #d9dee8; margin: 14pt 0; }
        a { color: #274060; }
        .footer { margin-top: 24pt; font-size: 8.5pt; color: #8a94a6; }
        </style></head><body>
        \(body(md))
        <div class="footer">Erstellt mit KI/lokal · kisruptiv.de</div>
        </body></html>
        """
    }

    static func body(_ md: String) -> String {
        var out: [String] = []
        var paragraph: [String] = []
        var list: (ordered: Bool, items: [String])?
        var table: [[String]] = []
        var code: [String]?
        // Zeilenumbrüche innerhalb eines Absatzes bleiben erhalten (so schreiben Sprachmodelle „Wann: …“/„Wo: …“).
        func flushParagraph() { if !paragraph.isEmpty { out.append("<p>\(paragraph.map(inline).joined(separator: "<br>"))</p>"); paragraph = [] } }
        func flushList() {
            if let l = list { out.append("<\(l.ordered ? "ol" : "ul")>" + l.items.map { "<li>\(inline($0))</li>" }.joined() + "</\(l.ordered ? "ol" : "ul")>") }
            list = nil
        }
        func flushTable() {
            guard !table.isEmpty else { return }
            var html = "<table><thead><tr>" + table[0].map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead><tbody>"
            for row in table.dropFirst() { html += "<tr>" + row.map { "<td>\(inline($0))</td>" }.joined() + "</tr>" }
            out.append(html + "</tbody></table>")
            table = []
        }
        func flushAll() { flushParagraph(); flushList(); flushTable() }

        for raw in md.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append("<pre><code>\(escape(c.joined(separator: "\n")))</code></pre>"); code = nil } else { flushAll(); code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if line.hasPrefix("|") {
                flushParagraph(); flushList()
                var cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.first == "" { cells.removeFirst() }
                if cells.last == "" { cells.removeLast() }
                if !cells.isEmpty && cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) { continue }
                table.append(cells)
                continue
            }
            flushTable()
            if line.isEmpty { flushParagraph(); flushList(); continue }
            if let m = line.firstMatch(of: /^(#{1,4})\s+(.+)$/) {
                flushAll(); out.append("<h\(m.1.count)>\(inline(String(m.2)))</h\(m.1.count)>")
            } else if line == "---" || line == "***" {
                flushAll(); out.append("<hr>")
            } else if let m = line.firstMatch(of: /^[-*+]\s+(.+)$/) {
                flushParagraph()
                if list?.ordered == true { flushList() }
                list = (false, (list?.items ?? []) + [String(m.1)])
            } else if let m = line.firstMatch(of: /^\d+[.)]\s+(.+)$/) {
                flushParagraph()
                if list?.ordered == false { flushList() }
                list = (true, (list?.items ?? []) + [String(m.1)])
            } else if let m = line.firstMatch(of: /^>\s?(.*)$/) {
                flushAll(); out.append("<blockquote>\(inline(String(m.1)))</blockquote>")
            } else {
                flushList(); paragraph.append(line)
            }
        }
        if let c = code { out.append("<pre><code>\(escape(c.joined(separator: "\n")))</code></pre>") }
        flushAll()
        return out.joined(separator: "\n")
    }

    static func inline(_ s: String) -> String {
        var t = escape(s)
        t = t.replacing(/`([^`]+)`/) { "<code>\($0.1)</code>" }
        t = t.replacing(/\*\*([^*]+)\*\*/) { "<strong>\($0.1)</strong>" }
        t = t.replacing(/\*([^*\s][^*]*)\*/) { "<em>\($0.1)</em>" }
        t = t.replacing(/\[([^\]]+)\]\(([^)\s]+)\)/) { "<a href=\"\($0.2)\">\($0.1)</a>" }
        return t
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
