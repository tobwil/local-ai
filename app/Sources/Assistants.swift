import Foundation
import Observation

/// Ein Assistent ist eine fertige Funktion für Menschen: Name, Symbol, Auftrag an den Agenten und welche Eingabe
/// er braucht (nichts, Text oder Dateien). Darunter arbeiten Skills und Werkzeuge; als Automation läuft er nach Zeitplan.
struct Assistant: Codable, Identifiable, Hashable {
    enum Input: String, Codable { case none, text, files }

    var id: String
    var name: String
    var icon: String
    var summary: String
    var category: String
    /// Auftrag an den Agenten. Bei `text` wird die Eingabe des Nutzers angehängt.
    var prompt: String
    var input: Input = .none
    /// Erlaubte Dateiendungen bei `files` (leer = alle).
    var fileTypes: [String] = []
    /// Hinweis, was der Nutzer eingeben soll (bei `text`).
    var placeholder = ""
    var builtin = false

    var canAutomate: Bool { input == .none }
}

@MainActor @Observable
final class AssistantStore {
    static let file = Paths.base.appendingPathComponent("assistants.json")
    private(set) var own: [Assistant] = []

    init() {
        if let d = try? Data(contentsOf: Self.file), let list = try? JSONDecoder().decode([Assistant].self, from: d) { own = list }
    }

    var all: [Assistant] { Self.builtin + own }

    var categories: [String] {
        var seen: [String] = []
        for a in all where !seen.contains(a.category) { seen.append(a.category) }
        return seen
    }

    func add(_ a: Assistant) {
        own.removeAll { $0.id == a.id }
        own.append(a)
        save()
    }

    func remove(_ a: Assistant) {
        own.removeAll { $0.id == a.id }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Paths.base, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        try? enc.encode(own).write(to: Self.file, options: .atomic)
    }

    static let audio = ["m4a", "mp3", "wav", "aiff", "aac", "flac", "caf", "ogg", "opus", "mp4", "mov", "m4v"]
    static let documents = ["pdf", "docx", "doc", "rtf", "odt", "txt", "md", "html", "pages"]

    static let builtin: [Assistant] = [
        Assistant(id: "transkribieren", name: "Transkribieren", icon: "waveform", summary: "Audio, Video oder WhatsApp-Sprachnachricht in Text – lokal, nichts verlässt den Mac.",
                  category: "Sprache & Meetings",
                  prompt: "Transkribiere die angehängte Aufnahme mit dem Werkzeug transcribe. Gib danach eine kurze Übersicht (Dauer, Themen) und den Speicherort des Transkripts an.",
                  input: .files, fileTypes: audio, builtin: true),
        Assistant(id: "meeting-protokoll", name: "Meeting-Protokoll", icon: "person.3.sequence", summary: "Aus einer Aufnahme: Zusammenfassung, Entscheidungen, Aufgaben mit Verantwortlichen.",
                  category: "Sprache & Meetings",
                  prompt: "Transkribiere die angehängte Meeting-Aufnahme mit transcribe. Erstelle daraus ein Protokoll: Teilnehmende (soweit erkennbar), Zusammenfassung, Entscheidungen, Aufgaben als Tabelle (Aufgabe | Wer | Bis wann), offene Fragen. Speichere es mit create_document als Word-Datei (Protokoll <Datum>.docx) und zeige die Kernpunkte im Chat.",
                  input: .files, fileTypes: audio, builtin: true),
        Assistant(id: "zusammenfassen", name: "Dokument zusammenfassen", icon: "doc.text.magnifyingglass", summary: "PDF, Word & Co.: Kernaussagen, Zahlen, offene Punkte.",
                  category: "Dokumente",
                  prompt: "Fasse die angehängten Dokumente zusammen: 5 Kernaussagen, wichtige Zahlen und Fristen, offene Fragen oder Risiken. Kurz und klar gegliedert.",
                  input: .files, fileTypes: documents, builtin: true),
        Assistant(id: "excel-auswerten", name: "Excel auswerten", icon: "tablecells", summary: "Tabellen verstehen: Summen, Auffälligkeiten, Bericht als PDF.",
                  category: "Dokumente",
                  prompt: "Werte die angehängte Tabelle aus: Was steht drin, Summen und Durchschnitte der wichtigsten Spalten, Auffälligkeiten und Ausreißer, drei Empfehlungen. Erstelle danach mit create_document einen kurzen Bericht als PDF.",
                  input: .files, fileTypes: ["xlsx", "xlsm", "csv", "numbers"], builtin: true),
        Assistant(id: "handout", name: "Präsentation → Handout", icon: "rectangle.on.rectangle.angled", summary: "Aus Folien ein lesbares Handout als PDF.",
                  category: "Dokumente",
                  prompt: "Mache aus der angehängten Präsentation ein Handout: pro Folie die Kernaussage in ganzen Sätzen, am Ende eine Zusammenfassung. Erstelle es mit create_document als PDF.",
                  input: .files, fileTypes: ["pptx", "key", "pdf"], builtin: true),
        Assistant(id: "uebersetzen", name: "Übersetzen", icon: "character.bubble", summary: "Deutsch ↔ Englisch (und mehr), Ton und Fachbegriffe bleiben.",
                  category: "Schreiben",
                  prompt: "Übersetze den folgenden Text. Ist er deutsch, ins Englische, sonst ins Deutsche. Behalte Ton, Formatierung und Fachbegriffe bei. Text:\n\n",
                  input: .text, placeholder: "Text zum Übersetzen einfügen …", builtin: true),
        Assistant(id: "mail-antwort", name: "E-Mail beantworten", icon: "envelope.badge", summary: "Freundliche, klare Antwort als bearbeitbarer Entwurf.",
                  category: "Schreiben",
                  prompt: "Schreibe eine freundliche, klare Antwort auf diese E-Mail und öffne sie mit open_canvas, damit ich sie bearbeiten kann. Wichtige Punkte nicht vergessen, keine Floskeln. E-Mail:\n\n",
                  input: .text, placeholder: "E-Mail einfügen (und ggf. was du antworten willst) …", builtin: true),
        Assistant(id: "text-ueberarbeiten", name: "Text überarbeiten", icon: "wand.and.stars", summary: "Klarer, kürzer, ohne Fehler – als Canvas zum Weiterarbeiten.",
                  category: "Schreiben",
                  prompt: "Überarbeite diesen Text: klarer, kürzer, aktive Sprache, Rechtschreibung korrigieren, Sinn unverändert. Öffne das Ergebnis mit open_canvas und nenne darunter die drei wichtigsten Änderungen. Text:\n\n",
                  input: .text, placeholder: "Text einfügen …", builtin: true),
        Assistant(id: "linkedin", name: "LinkedIn-Beitrag", icon: "megaphone", summary: "Beitrag im KIsruptiv-Ton: nahbar, konkret, mit Hook.",
                  category: "Schreiben",
                  prompt: "Schreibe einen LinkedIn-Beitrag im Ton von KIsruptiv (nahbar, konkret, optimistisch, ohne Buzzword-Bingo): starker erster Satz, 3–5 kurze Absätze, eine Frage zum Mitdiskutieren, 3 passende Hashtags. Öffne ihn mit open_canvas. Thema:\n\n",
                  input: .text, placeholder: "Thema oder Stichpunkte …", builtin: true),
        Assistant(id: "recherche", name: "Recherche-Bericht", icon: "globe.europe.africa", summary: "Thema im Web recherchieren, mit Quellen, als PDF.",
                  category: "Recherche",
                  prompt: "Recherchiere gründlich im Web (mehrere Quellen lesen) und erstelle einen Bericht mit Überblick, wichtigsten Fakten, Pro/Contra und Quellenliste mit Links. Speichere ihn mit create_document als PDF. Thema:\n\n",
                  input: .text, placeholder: "Thema oder Frage …", builtin: true),
        Assistant(id: "tagesplan", name: "Mein Tag", icon: "sun.horizon", summary: "Termine, Erinnerungen und Mails von heute auf einen Blick.",
                  category: "Recherche",
                  prompt: "Gib mir einen Überblick über meinen Tag: Termine heute (calendar_events), fällige Erinnerungen (reminders_list), die 5 wichtigsten ungelesenen Mails (mail_recent). Kurz und übersichtlich, mit Vorschlag, womit ich anfangen sollte.",
                  builtin: true),
        Assistant(id: "code-review", name: "Code prüfen", icon: "checkmark.seal", summary: "Projektordner auf Fehler, Risiken und Verbesserungen prüfen.",
                  category: "Code",
                  prompt: "Prüfe das Projekt im Arbeitsordner: Aufbau verstehen, dann Fehler, Sicherheitsrisiken und die drei wichtigsten Verbesserungen nennen – mit Datei und Zeile. Nichts ändern, nur berichten.",
                  builtin: true),
    ]
}
