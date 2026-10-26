import Foundation

/// Lektionen: Regeln, die der Agent aus Korrekturen und behobenen Fehlern gewonnen hat und künftig beachtet –
/// global oder nur in einem Projektordner. Gerade ein kleines Modell profitiert davon: Was einmal schiefging,
/// steht beim nächsten Mal im Systemprompt. Liegen als JSON in ~/.kilokal/lessons.json, sichtbar und löschbar
/// unter Einstellungen → Gedächtnis & Lektionen.
struct Lesson: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    /// Projektordner, für den die Lektion gilt (nil = überall).
    var folder: String?
    var created = Date()
    /// Woher sie stammt: "Korrektur", "Qualitäts-Check", "Agent", "Nutzer".
    var source = "Agent"
}

enum LessonStore {
    static var file = Paths.base.appendingPathComponent("lessons.json")
    /// So viel Platz bekommen Lektionen im Systemprompt (≈ 700 Tokens).
    static let promptBudget = 2_500

    static func all() -> [Lesson] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Lesson].self, from: data)) ?? []
    }

    static func save(_ lessons: [Lesson]) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(lessons).write(to: file, options: .atomic)
    }

    /// Neue Lektion; eine fast gleiche im selben Geltungsbereich wird ersetzt statt verdoppelt.
    @discardableResult
    static func add(_ text: String, folder: String?, source: String) -> (lesson: Lesson, replaced: Bool) {
        let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        var lessons = all()
        let lesson = Lesson(text: String(clean.prefix(400)), folder: folder, source: source)
        if let i = lessons.firstIndex(where: { $0.folder == folder && similarity($0.text, clean) > 0.6 }) {
            lessons[i] = lesson
            save(lessons)
            return (lesson, true)
        }
        lessons.append(lesson)
        save(lessons)
        return (lesson, false)
    }

    static func remove(_ id: UUID) {
        save(all().filter { $0.id != id })
    }

    /// Lektionen für diesen Ordner: globale und die des Projekts (auch übergeordneter Projektordner), neueste zuerst.
    static func relevant(for folder: String?, in lessons: [Lesson] = all()) -> [Lesson] {
        lessons.filter { l in
            guard let f = l.folder else { return true }
            guard let folder else { return false }
            return folder == f || folder.hasPrefix(f.hasSuffix("/") ? f : f + "/")
        }
        .sorted { $0.created > $1.created }
    }

    /// Abschnitt für den Systemprompt (leer, wenn es nichts gibt). Ändert sich nur, wenn eine Lektion dazukommt.
    static func promptSection(for folder: String?, in lessons: [Lesson] = all()) -> String {
        var lines: [String] = []
        var used = 0
        for l in relevant(for: folder, in: lessons) {
            let line = "- \(l.text)\(l.folder == nil ? "" : " (dieses Projekt)")"
            if used + line.count > promptBudget { break }
            used += line.count
            lines.append(line)
        }
        guard !lines.isEmpty else { return "" }
        return "\n\n## Lektionen aus früheren Aufträgen (unbedingt beachten)\n" + lines.joined(separator: "\n")
    }

    /// Wortähnlichkeit (Jaccard über Wörter ab 3 Buchstaben).
    static func similarity(_ a: String, _ b: String) -> Double {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 })
        }
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    /// Klingt die Nachricht des Nutzers nach einer Korrektur der letzten Antwort?
    static func isCorrection(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count < 1_500 else { return false }
        return t.range(of: #"^(nein|falsch|stopp|halt)\b|\b(das (ist|war) (falsch|nicht richtig|nicht korrekt)|stimmt (so )?nicht|nicht so\b|so nicht|hab(e)? (ich )?(doch )?(gesagt|geschrieben)|ich wollte (aber|doch|eigentlich)|nicht das,? was ich|mach(e)? das (bitte )?nie|nie wieder|immer (bitte )?\w+ statt|statt dessen|stattdessen|du hast .{0,40}(vergessen|übersehen|falsch|ignoriert)|wieder (falsch|nicht)|that'?s (wrong|not right)|you (forgot|missed|ignored))"#,
                       options: .regularExpression) != nil
    }

    /// Werkzeug für den Agenten. `folder` liefert den aktuellen Projektordner (nil = ohne Projekt).
    static func tool(folder: @escaping () -> String?) -> AgentTool {
        AgentTool(name: "learn_lesson",
                  description: "Hält eine dauerhafte Lektion fest, die du künftig beachtest: eine allgemeine Regel aus einer Korrektur des Nutzers oder einem behobenen Fehler (z. B. „Im Projekt X Tests mit npm test starten, nicht mit node“). Ein Satz, als Anweisung formuliert, ohne Einmal-Details. Nicht für Fakten über den Nutzer – dafür remember.",
                  parameters: schema([("rule", "string", "Die Regel als kurze Anweisung"),
                                      ("scope", "string", "\"projekt\" (nur dieses Projekt, Standard wenn eines offen ist) oder \"global\"")],
                                     required: ["rule"]),
                  needsApproval: false, source: "Gedächtnis") { args in
            let rule = try BuiltinTools.string(args, "rule")
            guard rule.count >= 8 else { throw ToolError.invalid("Regel zu kurz – als vollständige Anweisung formulieren.") }
            let project = folder()
            let scoped = (args["scope"] as? String)?.lowercased() != "global" ? project : nil
            let (_, replaced) = add(rule, folder: scoped, source: "Agent")
            return (replaced ? "Ähnliche Lektion ersetzt" : "Lektion gespeichert") + (scoped == nil ? " (gilt überall)." : " (gilt für dieses Projekt).")
        }
    }
}
