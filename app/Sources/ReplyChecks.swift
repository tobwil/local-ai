import Foundation

/// Prüfungen der fertigen Antwort, bevor der Nutzer ihr glaubt. Kleine Modelle behaupten gern Dinge, die nicht
/// passiert sind („Die Datei bericht.pdf ist gespeichert“, „Ich habe die Fotos umbenannt“), fragen trotz klarem
/// Auftrag „Soll ich loslegen?“ oder hören mitten in der Arbeit wortlos auf. Dann bekommt das Modell einmal einen
/// Hinweis und macht es richtig. Angelehnt an Hob (github.com/FrigadeHQ/hob, MIT).
enum ReplyCheck: Equatable {
    /// Behauptet Umbenennen, Verschieben oder Löschen – ohne dass ein ändernder Werkzeug-Aufruf lief.
    case claim
    /// Nennt Dateien als erstellt oder vorhanden, die es nicht gibt.
    case missing([String])
    /// Fragt, ob es loslegen soll, obwohl der Nutzer einen klaren Auftrag gab.
    case proceed
    /// Endet ohne ein Wort, nachdem schon Werkzeuge liefen.
    case unfinished

    /// Hinweis an das Modell (beginnt wie alle Hinweise der App, damit „Bearbeiten“ ihn nicht für eine Nutzernachricht hält).
    func note(ran: [String]) -> String {
        let done = ran.isEmpty ? "nichts" : ran.joined(separator: "; ")
        switch self {
        case .claim:
            return "(Hinweis der App: Deine Antwort sagt, Dateien seien umbenannt, verschoben oder gelöscht worden – in diesem Auftrag wurde aber keine Datei geändert. Was tatsächlich lief: \(done). Mach die Änderung jetzt mit den Werkzeugen (z. B. run_shell mit mv) und sag dann, was du getan hast. Geht es nicht, sag klar, dass es nicht erledigt ist und warum. Behaupte es nicht noch einmal, ohne dass ein Werkzeug-Ergebnis es zeigt.)"
        case let .missing(names):
            return "(Hinweis der App: Deine Antwort nennt \(names.joined(separator: ", ")), aber diese Datei gibt es nicht. Wolltest du sie anlegen, mach das jetzt mit den Werkzeugen (write_file für Text, create_document für PDF/Word/Excel) und sag dann, was du getan hast. Hast du den Namen nur erwähnt, gib deine Antwort noch einmal, ohne zu sagen, dass etwas gespeichert wurde.)"
        case .proceed:
            return "(Hinweis der App: Der Nutzer hat dir den Auftrag schon gegeben – frag nicht, ob du loslegen sollst, und zeig keinen Plan zur Freigabe. Mach es jetzt mit den Werkzeugen von Anfang bis Ende; vor riskanten Änderungen fragt die App den Nutzer ohnehin. Sag danach kurz, was du getan hast.)"
        case .unfinished:
            return "(Hinweis der App: Du hast aufgehört, bevor die Aufgabe fertig war, ohne etwas zu sagen. Bisher lief: \(done). Mach an dieser Stelle weiter und bring die Aufgabe mit den Werkzeugen zu Ende. Sag dann kurz, was du getan hast – oder klar, was nicht geklappt hat und warum.)"
        }
    }

    /// Kurzer Hinweis im Chat (Qualitäts-Check), wenn die App nachhakt.
    var label: String {
        switch self {
        case .claim: return "Antwort behauptete Änderungen an Dateien, die nicht passiert sind – der Agent holt sie nach."
        case let .missing(names): return "Antwort nannte \(names.prefix(3).joined(separator: ", ")), die es nicht gibt – der Agent korrigiert."
        case .proceed: return "Der Agent wollte nachfragen, obwohl der Auftrag klar war – er macht weiter."
        case .unfinished: return "Der Agent hat mittendrin aufgehört – er macht weiter."
        }
    }

    // MARK: Erkennung

    /// Vergangenheit von Umbenennen/Verschieben/Löschen: „Ich habe die Fotos umbenannt.“ „The files have been moved.“
    private static let claimPattern = #"\b(umbenannt|verschoben|gelöscht|in den papierkorb (gelegt|verschoben)|einsortiert|aufgeräumt|in ordner (sortiert|verteilt)|renamed|moved|deleted|trashed|reorgani[sz]ed|sorted (them|the files|everything) into)\b"#
    /// Pläne, Angebote, Fragen und Verneinungen sind keine Behauptungen.
    private static let notAClaim = #"\b(nicht|nie|kein|keine|keinen|konnte|kann|könnte|können|würde|würden|werde|wird|werden|soll|sollte|sollen|möchtest|willst|wenn|falls|bevor|sobald|vorschlag|plan|geplant|not|never|no|couldn't|can't|cannot|would|will|could|should|can|if|want|plan|before|once)\b|n't\b|\?\s*$"#

    static func claimsFileChanges(_ text: String) -> Bool {
        let prose = text.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"`[^`\n]*`"#, with: "X", options: .regularExpression)
        return sentences(prose).contains { s in
            s.range(of: claimPattern, options: [.regularExpression, .caseInsensitive]) != nil
                && s.range(of: notAClaim, options: [.regularExpression, .caseInsensitive]) == nil
        }
    }

    /// Fragt am Ende, ob es weitermachen soll: „Soll ich loslegen?“, „Sag Bescheid, wenn ich fortfahren soll.“
    private static let proceedPattern = #"\b(soll ich|darf ich|möchtest du,? dass ich|willst du,? dass ich|shall i|should i|want me to)\b[^.!?\n]*\?|\b(sag|gib) (mir )?(bitte )?bescheid\b[^.!?\n]*\b(loslegen|fortfahren|weitermachen|beginnen|starten|umsetzen|ausführen)\b|\bbitte (bestätige|bestätigen|freigeben|gib .{0,20}frei)\b|\b(let me know|tell me)\b[^.!?\n]*\b(proceed|go ahead|continue|start)\b|\bplease (approve|confirm)\b"#

    static func asksToProceed(_ text: String) -> Bool {
        let end = String(text.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines).suffix(400))
        // Nur Fragen nach dem Ob – „Soll ich die Tabelle noch nach Datum sortieren?“ (ein Zusatz) zählt nicht.
        guard end.range(of: proceedPattern, options: [.regularExpression, .caseInsensitive]) != nil else { return false }
        return end.range(of: #"\b(loslegen|leg(e)? ich los|anfang|beginn|start|fortfahr|weitermach|umsetz|ausführ|durchführ|so mach|das mach|go ahead|proceed|continue|do it|run it)|bestätig|freigeb|approve|confirm"#,
                         options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Sagt die Antwort, dass etwas gespeichert oder angelegt wurde? Nur dann zählen genannte Dateinamen als Behauptung –
    /// eine Erklärung wie „leg eine index.html an“ soll keinen Extra-Durchlauf kosten.
    static func mentionsSaving(_ text: String) -> Bool {
        text.range(of: #"\b(gespeichert|abgelegt|angelegt|erstellt|erzeugt|geschrieben|exportiert|liegt (jetzt )?(unter|in|im)|findest du (unter|in|im)|saved|created|wrote|written|exported)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let extensions = "txt|md|csv|tsv|json|pdf|docx?|xlsx?|pptx?|rtf|png|jpe?g|gif|svg|html?|js|ts|py|swift|sh|zip"

    /// Dateinamen, die die Antwort nennt und die `exists` nicht findet. Prüft die Dateien statt der Worte –
    /// das funktioniert in jeder Sprache. Links und Code-Blöcke zählen nicht.
    static func missingFiles(_ reply: String, exists: (String) -> Bool) -> [String] {
        let prose = reply.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\[[^\]]*\]\([^)]*\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "`", with: "")
        // In Anführungszeichen dürfen Leerzeichen vorkommen („Bericht Oktober.pdf“), sonst nicht.
        let quoted = #"["“„'«»]([^"“”'«»\n]{1,80}\.(?:\#(extensions)))["”“'»«]"#
        let bare = #"(?<![\w./~-])((?:~|/)?[\w./~-]*[\w-]\.(?:\#(extensions)))(?![\w])"#
        func groups(_ pattern: String, in s: String) -> [String] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
            return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range(at: 1), in: s).map { String(s[$0]) } }
        }
        let rest = prose.replacingOccurrences(of: quoted, with: " ", options: [.regularExpression, .caseInsensitive])
        let names = groups(quoted, in: prose) + groups(bare, in: rest)
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted && !exists($0) }
    }

    private static func sentences(_ text: String) -> [String] {
        text.components(separatedBy: "\n").flatMap { line in
            line.replacingOccurrences(of: #"([.!?])\s+"#, with: "$1\u{1}", options: .regularExpression).components(separatedBy: "\u{1}")
        }
    }
}

/// Ein Modell, das sich festgefahren hat, schreibt denselben langen Absatz immer wieder. Erkannt wird das am Ende
/// des Textes: dieselben ≥ 160 Zeichen dreimal direkt hintereinander. Zweimal kommt in echten Antworten vor
/// (derselbe Termin an zwei Tagen), dreimal am Stück nicht.
enum RepeatGuard {
    static let window = 160
    static let copies = 3

    /// Stelle (in UTF-16-Einheiten), ab der sich der Text wiederholt (Beginn der zweiten Kopie), sonst nil.
    static func cut(_ text: String, window: Int = window, copies: Int = copies) -> Int? {
        let u = Array(text.utf16)
        guard u.count >= 2 * window else { return nil }
        let end = u.count - window
        let tail = u[end...]
        // letzte frühere Stelle mit genau diesem Ende
        var prev = -1
        var i = end - 1
        while i >= 0 {
            if u[i] == tail.first!, u[i..<min(i + window, u.count)].elementsEqual(tail) { prev = i; break }
            i -= 1
        }
        guard prev >= 0 else { return nil }
        let period = end - prev
        // zurück zum Anfang des sich wiederholenden Musters; die zweite Kopie beginnt eine Periode später
        var start = prev
        while start > 0, u[start - 1] == u[start - 1 + period] { start -= 1 }
        guard u.count - start >= copies * period else { return nil }
        return start + period
    }

    /// Text bis zur Stelle `utf16Offset`.
    static func prefix(_ text: String, utf16Offset: Int) -> String {
        let idx = String.Index(utf16Offset: utf16Offset, in: text)
        return String(text[..<idx])
    }
}

/// Uhrzeit an jeder Nachricht statt im Systemprompt: Dort würde sie jede Minute den Anfang ändern, und die Engine
/// müsste das ganze Gespräch neu einlesen. Angehängt an den Text, den nur das Modell sieht.
enum MessageNote {
    static func time(_ now: Date = Date()) -> String {
        "\n\n[Gesendet: \(now.formatted(date: .complete, time: .shortened)), Zeitzone \(TimeZone.current.identifier)]"
    }

    /// Frühere Zeitvermerke entfernen (z. B. wenn eine Nachricht bearbeitet und neu geschickt wird).
    static func strip(_ text: String) -> String {
        text.replacingOccurrences(of: #"\n*\[Gesendet: [^\]\n]*\]"#, with: "", options: .regularExpression)
    }
}
