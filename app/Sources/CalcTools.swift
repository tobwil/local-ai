import Foundation

/// Rechnen und Datumsrechnung als Werkzeuge ohne Freigabe – das Modell rechnet nicht im Kopf (dabei vertut es sich
/// um Cent-Beträge und Monate), und für eine Summe soll niemand eine Shell-Freigabe bestätigen müssen.
extension BuiltinTools {
    static func math(_ workspace: @escaping () -> URL = { Paths.home }) -> [AgentTool] {
        [
            AgentTool(name: "calculate",
                      description: "Rechnet Ausdrücke exakt aus (+ - * / Klammern, %, SUM/AVERAGE/MIN/MAX mit Zahlen), z. B. \"(1846+520+60)*60\" oder \"3215*0.95\". Für jede Summe, Differenz, Prozent- und Durchschnittsrechnung benutzen – nie im Kopf rechnen.",
                      parameters: schema([("expressions", "array", "Liste von Ausdrücken, z. B. [\"59+186.33+139.9+298\", \"28*3/5\"]")], required: ["expressions"]),
                      needsApproval: false, source: "Eingebaut") { args in
                let list = (args["expressions"] as? [Any])?.map { "\($0)" } ?? (args["expressions"] as? String).map { [$0] } ?? []
                guard !list.isEmpty else { throw ToolError.invalid("expressions fehlt") }
                return list.prefix(40).map { expr in
                    guard let v = OfficeFiles.evaluate(expr, value: { _, _ in nil }) else { return "\(expr) = (nicht berechenbar)" }
                    return "\(expr) = \(TableFormulas.format(v, euro: false))"
                }.joined(separator: "\n")
            },
            AgentTool(name: "table_summary",
                      description: "Rechnet eine Tabelle (Excel .xlsx oder .csv) exakt aus, ohne Zahlen abzutippen: Summen je Gruppe (z. B. je Bereich oder Monat) und abgeleitete Spalten wie \"Gewinn = Umsatz - Kosten\". Für jede Auswertung von Tabellen zuerst benutzen.",
                      parameters: schema([("path", "string", "Datei (.xlsx oder .csv)"),
                                          ("group_by", "string", "Spalte zum Gruppieren, z. B. \"Bereich\" oder \"Monat\" (leer = nur Gesamt)"),
                                          ("sum", "array", "Zahlenspalten zum Summieren, z. B. [\"Umsatz\", \"Kosten\"] (leer = alle Zahlenspalten)"),
                                          ("derived", "array", "Abgeleitete Spalten, z. B. [\"Gewinn = Umsatz - Kosten\"]")], required: ["path"]),
                      needsApproval: false, source: "Eingebaut") { args in
                let url = resolve(try string(args, "path"), in: workspace())
                return try TableSummary.run(url: url, groupBy: args["group_by"] as? String,
                                            sum: (args["sum"] as? [Any])?.map { "\($0)" } ?? [],
                                            derived: (args["derived"] as? [Any])?.map { "\($0)" } ?? [])
            },
            AgentTool(name: "date_calc",
                      description: "Datumsrechnung mit Wochentag: Jahre, Monate, Tage zu einem Datum addieren oder abziehen, z. B. Kündigungsfrist „31.12.2031 minus 12 Monate“, oder nur den Wochentag eines Datums bestimmen. Für Fristen und „bis Freitag“ benutzen – nie im Kopf rechnen.",
                      parameters: schema([("date", "string", "Datum als TT.MM.JJJJ"),
                                          ("years", "integer", "Jahre (negativ = zurück)"),
                                          ("months", "integer", "Monate (negativ = zurück)"),
                                          ("days", "integer", "Tage (negativ = zurück)")], required: ["date"]),
                      needsApproval: false, source: "Eingebaut") { args in
                let raw = try string(args, "date").trimmingCharacters(in: .whitespaces)
                let f = DateFormatter()
                f.locale = Locale(identifier: "de_DE")
                f.calendar = Calendar(identifier: .gregorian)
                f.dateFormat = "dd.MM.yyyy"
                guard let start = f.date(from: raw) ?? { f.dateFormat = "yyyy-MM-dd"; return f.date(from: raw) }() else {
                    throw ToolError.invalid("Datum als TT.MM.JJJJ angeben, z. B. 31.12.2031")
                }
                var c = DateComponents()
                c.year = int(args["years"]); c.month = int(args["months"]); c.day = int(args["days"])
                guard let result = Calendar(identifier: .gregorian).date(byAdding: c, to: start) else { throw ToolError.invalid("Nicht berechenbar") }
                f.dateFormat = "dd.MM.yyyy"
                let weekday = DateFormatter()
                weekday.locale = Locale(identifier: "de_DE")
                weekday.dateFormat = "EEEE"
                let change = [c.year.map { "\($0) Jahre" }, c.month.map { "\($0) Monate" }, c.day.map { "\($0) Tage" }].compactMap { $0 }
                return "\(f.string(from: start))\(change.isEmpty ? "" : " " + change.joined(separator: ", ")) → \(f.string(from: result)) (\(weekday.string(from: result)))"
            },
        ]
    }
}

/// Prüft sichtbare Rechnungen in einer Antwort („28 × 3/5 = 18“, „1.490 + 180 = 1.670 €“) mit dem eigenen Rechner.
enum ArithmeticCheck {
    struct Error { let text: String; let correct: String }

    static func firstError(in raw: String) -> Error? {
        // LaTeX-Schreibweise in normale Rechnung übersetzen: \frac{3}{5} \times 28 = 20,4 → 3/5 × 28 = 20,4
        var answer = raw
        answer = answer.replacingOccurrences(of: #"\\[dt]?frac\{([^{}]+)\}\{([^{}]+)\}"#, with: "$1/$2", options: .regularExpression)
        for (latex, plain) in [("\\times", "×"), ("\\cdot", "·"), ("\\div", "÷"), ("\\,", ""), ("\\text{", "{"), ("$$", " "), ("$", " ")] {
            answer = answer.replacingOccurrences(of: latex, with: plain)
        }
        answer = answer.replacingOccurrences(of: #"\{([^{}]*)\}"#, with: "$1", options: .regularExpression)
        // Zahl (deutsch) – mindestens ein Operator – Zahl … = Zahl
        let num = #"\d{1,3}(?:\.\d{3})+(?:,\d+)?|\d+(?:,\d+)?"#
        let op = #"\s*[+\-−×x*·/÷]\s*"#
        let pattern = "(?<![\\d.,])((?:\(num))(?:\(op)(?:\(num)))+)\\s*=\\s*(\(num))(?![\\d])"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        for m in re.matches(in: answer, range: NSRange(answer.startIndex..., in: answer)) {
            guard let lhsR = Range(m.range(at: 1), in: answer), let rhsR = Range(m.range(at: 2), in: answer),
                  let whole = Range(m.range, in: answer) else { continue }
            let lhs = String(answer[lhsR]), rhsText = String(answer[rhsR])
            // „x“ nur als Mal-Zeichen zwischen Leerzeichen (nicht in Wörtern)
            if lhs.contains("x") && !lhs.contains(" x ") { continue }
            let expr = normalize(lhs)
            guard let want = OfficeFiles.evaluate(expr, value: { _, _ in nil }), let got = number(rhsText) else { continue }
            let tolerance = rhsText.contains(",") ? max(0.011, abs(want) * 0.0005) : 0.5   // ganze Zahl = gerundet erlaubt
            if abs(want - got) > tolerance {
                return Error(text: String(answer[whole]), correct: TableFormulas.format(want, euro: false))
            }
        }
        return nil
    }

    private static func number(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: "."))
    }

    private static func normalize(_ s: String) -> String {
        var out = ""
        // Zahlen deutsch → Punkt-Dezimal, Operatoren vereinheitlichen
        let re = try! NSRegularExpression(pattern: #"\d{1,3}(?:\.\d{3})+(?:,\d+)?|\d+(?:,\d+)?|[+\-−×x*·/÷]"#)
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            let t = String(s[Range(m.range, in: s)!])
            switch t {
            case "×", "x", "·": out += "*"
            case "÷": out += "/"
            case "−": out += "-"
            case "+", "-", "*", "/": out += t
            default: out += number(t).map { "\($0)" } ?? t
            }
        }
        return out
    }
}


/// Tabellen-Auswertung für `table_summary`: Gruppensummen und abgeleitete Spalten, exakt gerechnet.
enum TableSummary {
    static func run(url: URL, groupBy: String?, sum: [String], derived: [String]) throws -> String {
        let rows = try load(url)
        guard let header = rows.first, rows.count > 1 else { throw ToolError.invalid("Keine Tabelle in \(url.lastPathComponent)") }
        func col(_ name: String) -> Int? {
            let n = name.lowercased().trimmingCharacters(in: .whitespaces)
            return header.firstIndex { $0.lowercased() == n } ?? header.firstIndex { $0.lowercased().contains(n) }
        }
        let data = Array(rows.dropFirst())
        let numeric = header.indices.filter { c in data.filter { c < $0.count && OfficeFiles.cellNumber($0[c]) != nil }.count > data.count / 2 }
        let sumCols = sum.isEmpty ? numeric : sum.compactMap(col)
        guard !sumCols.isEmpty else { throw ToolError.invalid("Keine Zahlenspalten gefunden. Spalten: \(header.joined(separator: ", "))") }
        let groupCol = groupBy.flatMap { $0.isEmpty ? nil : col($0) }
        var order: [String] = []
        var totals: [String: [Double]] = [:]
        for r in data {
            let key = groupCol.map { $0 < r.count ? r[$0] : "–" } ?? "Gesamt"
            if totals[key] == nil { order.append(key); totals[key] = Array(repeating: 0, count: sumCols.count) }
            for (i, c) in sumCols.enumerated() { totals[key]![i] += c < r.count ? OfficeFiles.cellNumber(r[c])?.0 ?? 0 : 0 }
        }
        // Abgeleitete Spalten: „Gewinn = Umsatz - Kosten“ – Spaltennamen werden durch die Summen ersetzt
        let names = sumCols.map { header[$0] }
        func derive(_ values: [Double]) -> [Double?] {
            derived.map { d in
                let parts = d.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                var expr = String(parts[1])
                for (i, n) in names.enumerated().sorted(by: { $0.element.count > $1.element.count }) {
                    expr = expr.replacingOccurrences(of: n, with: "(\(values[i]))", options: .caseInsensitive)
                }
                return OfficeFiles.evaluate(expr) { _, _ in nil }
            }
        }
        let derivedNames = derived.map { String($0.split(separator: "=").first ?? "").trimmingCharacters(in: .whitespaces) }
        let head = [groupCol.map { header[$0] } ?? ""] + names + derivedNames
        var out = "| " + head.joined(separator: " | ") + " |\n|" + String(repeating: " --- |", count: head.count) + "\n"
        var grand = Array(repeating: 0.0, count: sumCols.count)
        for key in order {
            let v = totals[key]!
            for i in v.indices { grand[i] += v[i] }
            out += "| " + ([key] + v.map { TableFormulas.format($0, euro: false) } + derive(v).map { $0.map { TableFormulas.format($0, euro: false) } ?? "–" }).joined(separator: " | ") + " |\n"
        }
        if groupCol != nil {
            out += "| **Gesamt** | " + (grand.map { TableFormulas.format($0, euro: false) } + derive(grand).map { $0.map { TableFormulas.format($0, euro: false) } ?? "–" }).joined(separator: " | ") + " |\n"
        }
        return out + "\n(\(data.count) Zeilen ausgewertet – diese Werte genau so übernehmen.)"
    }

    /// Zeilen aus .xlsx (erstes Blatt) oder .csv (; oder ,)
    static func load(_ url: URL) throws -> [[String]] {
        if ["xlsx", "xlsm"].contains(url.pathExtension.lowercased()) {
            guard let text = OfficeFiles.xlsxText(url, maxRows: 100_000) else { throw ToolError.invalid("Excel-Datei nicht lesbar") }
            var rows: [[String]] = []
            for line in text.components(separatedBy: "\n") {
                if line.hasPrefix("## ") && !rows.isEmpty { break }   // nur das erste Blatt
                guard line.hasPrefix("|"), !line.contains("| --- |") else { continue }
                rows.append(line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) })
            }
            return rows
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let sep: Character = text.contains(";") ? ";" : ","
        return text.components(separatedBy: .newlines).filter { !$0.isEmpty }.map { $0.split(separator: sep, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) } }
    }
}
