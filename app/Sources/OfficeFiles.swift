import Foundation

/// Excel und PowerPoint lesen, Excel schreiben, ZIP entpacken – ohne zusätzliche Bibliotheken
/// (Office-Dateien sind ZIP-Archive mit XML; entpackt wird mit den Bordmitteln von macOS).
enum OfficeFiles {
    // MARK: ZIP

    /// Einen Eintrag aus einem ZIP-Archiv lesen (unzip -p).
    static func entry(_ archive: URL, _ path: String) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", archive.path, path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard let data = try? p.runAndReadBlocking(out), p.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    static func entries(_ archive: URL) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        p.arguments = ["-1", archive.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard let data = try? p.runAndReadBlocking(out) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// ZIP nach ~/.kilokal/anhaenge/<name>/ entpacken (ditto, wie der Finder) und den Ordner liefern.
    static func unpack(_ archive: URL) throws -> URL {
        let dest = Paths.base.appendingPathComponent("anhaenge")
            .appendingPathComponent(archive.deletingPathExtension().lastPathComponent + "-" + String(Int(Date().timeIntervalSince1970)))
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", archive.path, dest.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ToolError.invalid("ZIP ließ sich nicht entpacken") }
        return dest
    }

    // MARK: Excel lesen

    /// Alle Tabellenblätter als Markdown-Tabellen (höchstens `maxRows` Zeilen je Blatt).
    static func xlsxText(_ url: URL, maxRows: Int = 400) -> String? {
        let shared = entry(url, "xl/sharedStrings.xml").map { SharedStrings.parse($0) } ?? []
        guard let workbook = entry(url, "xl/workbook.xml") else { return nil }
        let names = XMLValues.attributes(workbook, element: "sheet", attribute: "name")
        var out = ""
        var index = 1
        while let sheet = entry(url, "xl/worksheets/sheet\(index).xml") {
            let rows = SheetRows.parse(sheet, shared: shared)
            let name = index <= names.count ? names[index - 1] : "Blatt \(index)"
            out += "## \(name)\n"
            if rows.isEmpty { out += "(leer)\n\n" } else {
                let width = rows.map(\.count).max() ?? 0
                for (i, row) in rows.prefix(maxRows).enumerated() {
                    let cells = row + Array(repeating: "", count: width - row.count)
                    out += "| " + cells.map { $0.replacingOccurrences(of: "|", with: "/") }.joined(separator: " | ") + " |\n"
                    if i == 0 { out += "|" + String(repeating: " --- |", count: width) + "\n" }
                }
                if rows.count > maxRows { out += "… \(rows.count - maxRows) weitere Zeilen\n" }
                out += "\n"
            }
            index += 1
        }
        return index == 1 ? nil : out
    }

    // MARK: PowerPoint lesen

    static func pptxText(_ url: URL) -> String? {
        let slides = entries(url).filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { Int($0.filter(\.isNumber)) ?? 0 < Int($1.filter(\.isNumber)) ?? 0 }
        guard !slides.isEmpty else { return nil }
        return slides.enumerated().map { i, path in
            let texts = entry(url, path).map { XMLValues.texts($0, element: "a:t") } ?? []
            return "## Folie \(i + 1)\n" + texts.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    // MARK: Excel schreiben

    /// Markdown-Tabellen → .xlsx (eine Tabelle je Blatt; Zahlen werden als Zahlen gespeichert).
    /// Zahl in einer Tabellenzelle: 1.234,56 · 1234,56 · 1234.56 · 186,33 € · -5 – und ob es ein Euro-Betrag ist.
    /// Datumsangaben (18.09.2026), Uhrzeiten und Nummern mit Buchstaben bleiben Text.
    static func cellNumber(_ raw: String) -> (Double, Bool)? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        let euro = s.contains("€") || s.hasSuffix("EUR")
        s = s.replacingOccurrences(of: "€", with: "").replacingOccurrences(of: "EUR", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "").trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.range(of: #"^-?\d{1,3}(\.\d{3})+(,\d+)?$"#, options: .regularExpression) != nil
            || s.range(of: #"^-?\d+,\d+$"#, options: .regularExpression) != nil {
            return Double(s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")).map { ($0, euro) }
        }
        if s.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil { return Double(s).map { ($0, euro) } }
        return nil
    }

    static func writeXLSX(markdown: String, to url: URL) throws {
        var tables: [[[String]]] = []
        var current: [[String]] = []
        for line in markdown.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("|") {
                var cells = l.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.first == "" { cells.removeFirst() }
                if cells.last == "" { cells.removeLast() }
                if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) { continue }
                current.append(cells)
            } else if !current.isEmpty { tables.append(current); current = [] }
        }
        if !current.isEmpty { tables.append(current) }
        if tables.isEmpty {
            // Kein Markdown-Tabellenformat: als CSV/Zeilen deuten.
            let rows = markdown.components(separatedBy: "\n").filter { !$0.isEmpty }
                .map { $0.components(separatedBy: $0.contains(";") ? ";" : ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            if !rows.isEmpty { tables = [rows] }
        }
        guard !tables.isEmpty else { throw ToolError.invalid("Keine Tabelle im Inhalt – bitte als Markdown-Tabelle angeben") }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("xlsx-\(UUID().uuidString)")
        let fm = FileManager.default
        for dir in ["_rels", "xl/_rels", "xl/worksheets"] { try fm.createDirectory(at: tmp.appendingPathComponent(dir), withIntermediateDirectories: true) }
        func write(_ path: String, _ text: String) throws { try text.write(to: tmp.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        let head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        let sheets = tables.indices.map { "sheet\($0 + 1)" }
        try write("[Content_Types].xml", head + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        \(sheets.map { "<Override PartName=\"/xl/worksheets/\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined())\
        </Types>
        """)
        try write("_rels/.rels", head + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
        </Relationships>
        """)
        try write("xl/workbook.xml", head + """
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\
        \(sheets.enumerated().map { "<sheet name=\"Tabelle \($0.offset + 1)\" sheetId=\"\($0.offset + 1)\" r:id=\"rId\($0.offset + 1)\"/>" }.joined())\
        </sheets></workbook>
        """)
        try write("xl/_rels/workbook.xml.rels", head + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        \(sheets.enumerated().map { "<Relationship Id=\"rId\($0.offset + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/\($0.element).xml\"/>" }.joined())\
        <Relationship Id="rId\(sheets.count + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
        </Relationships>
        """)
        // Stil 1 = fette Kopfzeile, 2 = Euro-Betrag, 3 = Euro-Betrag fett (Summenzeilen)
        try write("xl/styles.xml", head + """
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <numFmts count="1"><numFmt numFmtId="164" formatCode="#,##0.00\\ &quot;€&quot;"/></numFmts>\
        <fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>\
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
        <borders count="1"><border/></borders><cellStyleXfs count="1"><xf/></cellStyleXfs>\
        <cellXfs count="4"><xf fontId="0"/><xf fontId="1" applyFont="1"/><xf fontId="0" numFmtId="164" applyNumberFormat="1"/>\
        <xf fontId="1" numFmtId="164" applyFont="1" applyNumberFormat="1"/></cellXfs></styleSheet>
        """)
        for (t, rows) in tables.enumerated() {
            // Zahlenwert einer Zelle (Zeile ab 1, wie in Excel) – Formeln rekursiv ausgerechnet
            func number(_ r: Int, _ c: Int, depth: Int = 0) -> Double? {
                guard r >= 2, r - 1 < rows.count, c < rows[r - 1].count, depth < 20 else { return nil }
                let v = rows[r - 1][c].replacingOccurrences(of: "**", with: "")
                if v.hasPrefix("=") { return Self.evaluate(String(v.dropFirst())) { number($0, $1, depth: depth + 1) } }
                return Self.cellNumber(v)?.0
            }
            var xml = head + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
            for (r, row) in rows.enumerated() {
                xml += "<row r=\"\(r + 1)\">"
                for (c, raw) in row.enumerated() {
                    let ref = column(c) + String(r + 1)
                    let bold = raw.contains("**")
                    let value = raw.replacingOccurrences(of: "**", with: "")
                    if r > 0, value.hasPrefix("="), value.count > 1 {
                        // Formel (englische Namen wie in der Datei: =SUM(E2:E7)) – Excel rechnet selbst, kein Kopfrechnen des Modells
                        let cached = number(r + 1, c).map { "<v>\($0)</v>" } ?? ""
                        // Excel erwartet Dezimalpunkt und englische Namen in der Datei (=E7*0,05 → E7*0.05, SUMME → SUM)
                        let formula = String(value.dropFirst()).replacingOccurrences(of: #"(\d),(\d)"#, with: "$1.$2", options: .regularExpression)
                            .replacingOccurrences(of: "SUMME(", with: "SUM(").replacingOccurrences(of: "MITTELWERT(", with: "AVERAGE(")
                        xml += "<c r=\"\(ref)\" s=\"\(bold ? 3 : 2)\"><f>\(MarkdownHTML.escape(formula))</f>\(cached)</c>"
                    } else if r > 0, let (number, euro) = Self.cellNumber(value) {
                        let v = number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
                        let style = euro ? " s=\"\(bold ? 3 : 2)\"" : bold ? " s=\"1\"" : ""
                        xml += "<c r=\"\(ref)\"\(style)><v>\(v)</v></c>"
                    } else if r == 0 || bold {
                        xml += "<c r=\"\(ref)\" t=\"inlineStr\" s=\"1\"><is><t>\(MarkdownHTML.escape(value))</t></is></c>"
                    } else {
                        xml += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t>\(MarkdownHTML.escape(value))</t></is></c>"
                    }
                }
                xml += "</row>"
            }
            try write("xl/worksheets/\(sheets[t]).xml", xml + "</sheetData></worksheet>")
        }
        try? fm.removeItem(at: url)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = tmp
        p.arguments = ["-q", "-X", "-r", url.path, "[Content_Types].xml", "_rels", "xl"]
        try p.run()
        p.waitUntilExit()
        try? fm.removeItem(at: tmp)
        guard p.terminationStatus == 0 else { throw ToolError.invalid("Excel-Datei konnte nicht gepackt werden") }
    }

    private static func column(_ i: Int) -> String {
        var n = i + 1, s = ""
        while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(65 + r)!) + s; n = (n - 1) / 26 }
        return s
    }
}

// MARK: Kleine XML-Leser

private final class SharedStrings: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var current = ""
    private var inSI = false, inT = false

    static func parse(_ data: Data) -> [String] {
        let d = SharedStrings()
        let p = XMLParser(data: data)
        p.delegate = d
        p.parse()
        return d.strings
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "si" { inSI = true; current = "" }
        if name == "t" { inT = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if inSI && inT { current += string } }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "t" { inT = false }
        if name == "si" { strings.append(current); inSI = false }
    }
}

private final class SheetRows: NSObject, XMLParserDelegate {
    private let shared: [String]
    private var rows: [[String]] = []
    private var row: [String] = []
    private var cellType = "", cellRef = "", value = "", formula = ""
    private var inValue = false, inFormula = false

    init(shared: [String]) { self.shared = shared }

    static func parse(_ data: Data, shared: [String]) -> [[String]] {
        let d = SheetRows(shared: shared)
        let p = XMLParser(data: data)
        p.delegate = d
        p.parse()
        while let last = d.rows.last, last.allSatisfy(\.isEmpty) { d.rows.removeLast() }
        return d.rows
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "row": row = []
        case "c": cellType = attributes["t"] ?? ""; cellRef = attributes["r"] ?? ""; value = ""; formula = ""
        case "v", "t": inValue = true
        case "f": inFormula = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue { value += string } else if inFormula { formula += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "v", "t": inValue = false
        case "f": inFormula = false
        case "c":
            // Lücken (leere Zellen) über die Spaltenbuchstaben auffüllen.
            let letters = cellRef.prefix { $0.isLetter }
            let col = letters.reduce(0) { $0 * 26 + Int($1.asciiValue! - 64) } - 1
            while row.count < col { row.append("") }
            let shown = cellType == "s" ? (Int(value).flatMap { $0 < shared.count ? shared[$0] : nil } ?? value) : value
            // Formeln sichtbar machen (sonst sieht das Modell leere Summenzeilen und hält sie für Platzhalter)
            row.append(formula.isEmpty ? shown : "=\(formula)" + (shown.isEmpty ? "" : " → \(shown)"))
        case "row": rows.append(row)
        default: break
        }
    }
}

enum XMLValues {
    static func attributes(_ data: Data, element: String, attribute: String) -> [String] {
        let d = Collector(element: element, attribute: attribute)
        let p = XMLParser(data: data)
        p.delegate = d
        p.parse()
        return d.values
    }

    static func texts(_ data: Data, element: String) -> [String] {
        let d = Collector(element: element, attribute: nil)
        let p = XMLParser(data: data)
        p.delegate = d
        p.parse()
        return d.values
    }

    private final class Collector: NSObject, XMLParserDelegate {
        let element: String
        let attribute: String?
        var values: [String] = []
        private var inside = false
        private var current = ""

        init(element: String, attribute: String?) { self.element = element; self.attribute = attribute }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            guard name == element || qualifiedName == element else { return }
            if let attribute { if let v = attributes[attribute] { values.append(v) } } else { inside = true; current = "" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { if inside { current += string } }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if inside && (name == element || qualifiedName == element) { values.append(current); inside = false }
        }
    }
}
