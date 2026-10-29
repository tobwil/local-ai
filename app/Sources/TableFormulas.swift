import Foundation

/// „Das Modell versteht, die App rechnet“: In Markdown-Tabellen schreibt der Agent Formeln wie in Excel
/// (=C2*D2, =SUM(E2:E6), =E7*0.19) statt selbst gerechneter Beträge. Die App rechnet sie aus – in Excel bleiben sie
/// Formeln (mit Wert), in Word, PDF & Co. stehen die fertigen Zahlen – und meldet die Werte an den Agenten zurück.
/// Zeilen zählen wie in Excel: Kopfzeile = 1, die Trennlinie |---| zählt nicht.
enum TableFormulas {
    struct Result {
        var markdown: String
        /// „Netto · Gesamt = 3.054,25 €“ – für die Rückmeldung an den Agenten
        var values: [String]
    }

    /// Formeln in allen Tabellen ausrechnen. `replace`: Formelzellen durch Zahlen ersetzen (Word, PDF, CSV).
    static func apply(_ markdown: String, replace: Bool) -> Result {
        var lines = markdown.components(separatedBy: "\n")
        var values: [String] = []
        var i = 0
        while i < lines.count {
            guard isRow(lines[i]) else { i += 1; continue }
            var block: [Int] = []
            while i < lines.count, isRow(lines[i]) { block.append(i); i += 1 }
            let dataLines = block.filter { !isSeparator(lines[$0]) }
            let grid = dataLines.map { cells(lines[$0]) }
            guard grid.contains(where: { $0.contains { $0.plain.hasPrefix("=") } }) else { continue }
            var cache: [String: Double] = [:]
            func number(_ r: Int, _ c: Int, depth: Int = 0) -> Double? {
                guard r >= 1, r <= grid.count, c >= 0, c < grid[r - 1].count, depth < 30 else { return nil }
                let key = "\(r)|\(c)"
                if let v = cache[key] { return v }
                let text = grid[r - 1][c].plain
                let v = text.hasPrefix("=")
                    ? OfficeFiles.evaluate(String(text.dropFirst())) { number($0, $1, depth: depth + 1) }
                    : OfficeFiles.cellNumber(text)?.0
                if let v { cache[key] = v }
                return v
            }
            let header = grid.first?.map(\.plain) ?? []
            for (r, row) in grid.enumerated() where r > 0 {
                let label = row.first { !$0.plain.isEmpty && !$0.plain.hasPrefix("=") }?.plain ?? "Zeile \(r + 1)"
                var newCells = row.map(\.raw)
                for (c, cell) in row.enumerated() where cell.plain.hasPrefix("=") {
                    guard let v = number(r + 1, c) else { continue }
                    let euro = isEuroColumn(grid, c)
                    let shown = format(v, euro: euro)
                    let name = c < header.count && !header[c].isEmpty ? header[c] : "Spalte \(c + 1)"
                    values.append("\(label) · \(name) = \(shown)")
                    if replace { newCells[c] = cell.bold ? "**\(shown)**" : shown }
                }
                if replace { lines[dataLines[r]] = "| " + newCells.joined(separator: " | ") + " |" }
            }
        }
        return Result(markdown: lines.joined(separator: "\n"), values: values)
    }

    /// Summenzeilen baut die App, nicht das Modell: Es sagt nur, was summiert wird (`totals` bei create_document).
    /// - `line`: [Menge, Einzelpreis, Gesamt] – Zeilenbetrag als Formel
    /// - `sum`: Spalten für die Summe; `per_month`: nach Datum sortieren, Zwischensumme je Monat, dann Gesamt
    /// - `discount_percent`, `vat_percent`: Rabatt → Netto, USt → Brutto
    /// Angewendet auf die letzte Tabelle, die alle genannten Spalten hat.
    static func addTotals(_ markdown: String, spec: [String: Any]) -> String {
        var lines = markdown.components(separatedBy: "\n")
        let sumNames = (spec["sum"] as? [String]) ?? (spec["sum"] as? String).map { [$0] } ?? []
        let lineNames = spec["line"] as? [String] ?? []
        let perMonth = spec["per_month"] as? Bool ?? false
        let discount = (spec["discount_percent"] as? NSNumber)?.doubleValue ?? 0
        let vat = (spec["vat_percent"] as? NSNumber)?.doubleValue ?? 0
        // Tabellen finden (Zeilenindizes ohne Trennlinie)
        var tables: [[Int]] = []
        var i = 0
        while i < lines.count {
            guard isRow(lines[i]) else { i += 1; continue }
            var block: [Int] = []
            while i < lines.count, isRow(lines[i]) { block.append(i); i += 1 }
            tables.append(block)
        }
        func col(_ header: [String], _ name: String) -> Int? {
            let n = name.lowercased()
            return header.firstIndex { $0.lowercased() == n } ?? header.firstIndex { $0.lowercased().contains(n) }
        }
        for block in tables.reversed() {
            let rows = block.filter { !isSeparator(lines[$0]) }
            guard let headerLine = rows.first else { continue }
            let header = cells(lines[headerLine]).map(\.plain)
            let sumCols = sumNames.compactMap { col(header, $0) }
            let lineCols = lineNames.compactMap { col(header, $0) }
            guard !sumCols.isEmpty || lineCols.count == 3 else { continue }
            let width = header.count
            func letter(_ c: Int) -> String { String(UnicodeScalar(65 + c)!) }
            func row(_ label: String, _ values: [Int: String], bold: Bool) -> [String] {
                let labelCol = (0..<width).first { !sumCols.contains($0) && !["pos", "pos.", "nr", "nr."].contains(header[$0].lowercased()) } ?? 0
                return (0..<width).map { c in
                    if c == labelCol { return bold ? "**\(label)**" : label }
                    if let v = values[c] { return bold ? "**\(v)**" : v }
                    return ""
                }
            }
            // Datenzeilen (ohne vom Modell selbst gebaute Summenzeilen)
            var data = rows.dropFirst().map { cells(lines[$0]).map(\.raw) }
                .filter { r in !r.contains { $0.lowercased().contains("summe") || $0.lowercased().contains("gesamt") && $0.contains("**") } }
                .map { r in r + Array(repeating: "", count: max(0, width - r.count)) }
            if lineCols.count == 3 {
                for k in data.indices { data[k][lineCols[2]] = "=\(letter(lineCols[0]))\(k + 2)*\(letter(lineCols[1]))\(k + 2)" }
            }
            var out: [[String]] = []
            var subtotalRows: [Int] = []
            let dateCol = header.firstIndex { $0.lowercased().contains("datum") }
            func date(_ r: [String]) -> Date? {
                guard let dc = dateCol else { return nil }
                let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"; f.locale = Locale(identifier: "de_DE")
                return f.date(from: r[dc].replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces))
            }
            if perMonth, dateCol != nil {
                data.sort { (date($0) ?? .distantFuture) < (date($1) ?? .distantFuture) }
                let month = DateFormatter(); month.dateFormat = "LLLL yyyy"; month.locale = Locale(identifier: "de_DE")
                var k = 0
                while k < data.count {
                    let key = date(data[k]).map { month.string(from: $0) } ?? "ohne Datum"
                    let start = out.count + 2
                    while k < data.count, (date(data[k]).map { month.string(from: $0) } ?? "ohne Datum") == key { out.append(data[k]); k += 1 }
                    let end = out.count + 1
                    out.append(row("Summe \(key)", Dictionary(uniqueKeysWithValues: sumCols.map { ($0, "=SUM(\(letter($0))\(start):\(letter($0))\(end))") }), bold: true))
                    subtotalRows.append(out.count + 1)
                }
                out.append(row("Gesamt", Dictionary(uniqueKeysWithValues: sumCols.map { c in (c, "=SUM(" + subtotalRows.map { "\(letter(c))\($0)" }.joined(separator: ",") + ")") }), bold: true))
            } else {
                out = data
                guard !sumCols.isEmpty else { break }
                let last = out.count + 1
                let sumLabel = discount > 0 || vat > 0 ? "Zwischensumme" : "Summe"
                out.append(row(sumLabel, Dictionary(uniqueKeysWithValues: sumCols.map { ($0, "=SUM(\(letter($0))2:\(letter($0))\(last))") }), bold: true))
                var base = out.count + 1   // Zeile mit der Summe
                if discount > 0, let c = sumCols.first {
                    out.append(row("Rabatt \(TableFormulas.format(discount, euro: false)) %", [c: "=-\(letter(c))\(base)*\(discount / 100)"], bold: false))
                    out.append(row("Netto", [c: "=\(letter(c))\(base)+\(letter(c))\(base + 1)"], bold: true))
                    base += 2
                }
                if vat > 0, let c = sumCols.first {
                    out.append(row("USt \(TableFormulas.format(vat, euro: false)) %", [c: "=\(letter(c))\(base)*\(vat / 100)"], bold: false))
                    out.append(row("Brutto", [c: "=\(letter(c))\(base)+\(letter(c))\(base + 1)"], bold: true))
                }
            }
            let newLines = [lines[headerLine], "|" + String(repeating: " --- |", count: width)] + out.map { "| " + $0.joined(separator: " | ") + " |" }
            lines.replaceSubrange(block.first!...block.last!, with: newLines)
            break
        }
        return lines.joined(separator: "\n")
    }

    static func format(_ v: Double, euro: Bool) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .decimal
        f.minimumFractionDigits = euro ? 2 : 0
        f.maximumFractionDigits = 2
        return (f.string(from: NSNumber(value: v)) ?? "\(v)") + (euro ? " €" : "")
    }

    private struct Cell { let raw: String; var plain: String { raw.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces) }
        var bold: Bool { raw.contains("**") } }

    private static func isRow(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).hasPrefix("|") }
    private static func isSeparator(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).range(of: #"^\|?(\s*:?-{2,}:?\s*\|)+\s*:?-*:?\s*$"#, options: .regularExpression) != nil
    }
    private static func cells(_ line: String) -> [Cell] {
        var parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: "|")
        if parts.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { parts.removeFirst() }
        if parts.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { parts.removeLast() }
        return parts.map { Cell(raw: $0.trimmingCharacters(in: .whitespaces)) }
    }
    /// Euro-Spalte: Kopf nennt €/Preis/Betrag/Summe/Netto/Brutto oder eine Zelle enthält €.
    private static func isEuroColumn(_ grid: [[Cell]], _ c: Int) -> Bool {
        let head = grid.first.flatMap { c < $0.count ? $0[c].plain.lowercased() : nil } ?? ""
        if ["€", "eur", "preis", "betrag", "summe", "netto", "brutto", "kosten", "umsatz", "gesamt", "ust"].contains(where: head.contains) { return true }
        return grid.dropFirst().contains { c < $0.count && $0[c].plain.contains("€") }
    }
}

extension OfficeFiles {
    /// Formel wie in Excel ausrechnen: Grundrechenarten, Klammern, Zellbezüge (E7, $E$7) und SUM/SUMME, AVERAGE,
    /// MIN, MAX über Zellen und Bereiche. Ergebnis auf Cent gerundet; nil, wenn etwas fehlt oder nicht passt.
    static func evaluate(_ formula: String, value: (_ row: Int, _ col: Int) -> Double?) -> Double? {
        var f = formula.uppercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "$", with: "")
        f = f.replacingOccurrences(of: #"(\d),(\d)"#, with: "$1.$2", options: .regularExpression)   // =E7*0,05
        func cell(_ ref: Substring) -> (Int, Int)? {
            let letters = ref.prefix { $0.isLetter }, digits = ref.dropFirst(letters.count)
            guard !letters.isEmpty, letters.count <= 3, let r = Int(digits) else { return nil }
            return (r, letters.reduce(0) { $0 * 26 + Int($1.asciiValue! - 64) } - 1)
        }
        // Funktionen von innen nach außen durch ihren Wert ersetzen
        let fnRe = try! NSRegularExpression(pattern: #"(SUMME|SUM|AVERAGE|MITTELWERT|MIN|MAX)\(([^()]*)\)"#)
        while let m = fnRe.firstMatch(in: f, range: NSRange(f.startIndex..., in: f)),
              let whole = Range(m.range, in: f), let fnR = Range(m.range(at: 1), in: f), let argR = Range(m.range(at: 2), in: f) {
            let fn = String(f[fnR])
            var numbers: [Double] = []
            for arg in f[argR].split(whereSeparator: { $0 == "," || $0 == ";" }) {
                if let n = Double(arg) { numbers.append(n); continue }
                let parts = arg.split(separator: ":")
                guard let a = cell(parts[0]), let b = parts.count > 1 ? cell(parts[1]) : a else { return nil }
                for r in min(a.0, b.0)...max(a.0, b.0) {
                    for c in min(a.1, b.1)...max(a.1, b.1) { if let v = value(r, c) { numbers.append(v) } }
                }
            }
            let result: Double
            switch fn {
            case "AVERAGE", "MITTELWERT": guard !numbers.isEmpty else { return nil }; result = numbers.reduce(0, +) / Double(numbers.count)
            case "MIN": guard let v = numbers.min() else { return nil }; result = v
            case "MAX": guard let v = numbers.max() else { return nil }; result = v
            default: result = numbers.reduce(0, +)
            }
            f.replaceSubrange(whole, with: "(\(result))")
        }
        // Zellbezüge durch Werte ersetzen
        let refRe = try! NSRegularExpression(pattern: #"[A-Z]{1,3}[0-9]+"#)
        for m in refRe.matches(in: f, range: NSRange(f.startIndex..., in: f)).reversed() {
            guard let r = Range(m.range, in: f), let rc = cell(f[r]), let v = value(rc.0, rc.1) else { return nil }
            f.replaceSubrange(r, with: "(\(v))")
        }
        var parser = Arithmetic(Array(f))
        guard let v = parser.parse(), v.isFinite else { return nil }
        return (v * 100).rounded() / 100
    }
}

/// Kleiner Rechner für + - * / und Klammern (bewusst ohne NSExpression – das stürzt bei kaputter Eingabe ab).
private struct Arithmetic {
    let s: [Character]
    var i = 0
    init(_ s: [Character]) { self.s = s }

    mutating func parse() -> Double? {
        guard let v = expr(), i == s.count else { return nil }
        return v
    }
    private mutating func expr() -> Double? {
        guard var v = term() else { return nil }
        while i < s.count, s[i] == "+" || s[i] == "-" {
            let op = s[i]; i += 1
            guard let t = term() else { return nil }
            v = op == "+" ? v + t : v - t
        }
        return v
    }
    private mutating func term() -> Double? {
        guard var v = factor() else { return nil }
        while i < s.count, s[i] == "*" || s[i] == "/" {
            let op = s[i]; i += 1
            guard let f = factor() else { return nil }
            if op == "/" { guard f != 0 else { return nil }; v /= f } else { v *= f }
        }
        return v
    }
    private mutating func factor() -> Double? {
        guard i < s.count else { return nil }
        if s[i] == "-" { i += 1; return factor().map { -$0 } }
        if s[i] == "+" { i += 1; return factor() }
        if s[i] == "(" {
            i += 1
            guard let v = expr(), i < s.count, s[i] == ")" else { return nil }
            i += 1
            return v
        }
        var j = i
        while j < s.count, s[j].isNumber || s[j] == "." || (s[j] == "E" && j > i) || ((s[j] == "-" || s[j] == "+") && j > i && s[j - 1] == "E") { j += 1 }
        guard j > i, let v = Double(String(s[i..<j])) else { return nil }
        i = j
        if i < s.count, s[i] == "%" { i += 1; return v / 100 }
        return v
    }
}
