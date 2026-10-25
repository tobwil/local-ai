import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Galerie fertiger Funktionen: ein Klick, Datei oder Text dazu, fertig. Eigene Assistenten entstehen aus Gesprächen.
struct AssistantsView: View {
    @Environment(AppState.self) private var app
    @State private var textInput: Assistant?
    @State private var text = ""

    var body: some View {
        let store = app.assistants
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Wordmark(suffix: "assistenten", size: 28)
                    Text("Fertige Funktionen für den Alltag – alles läuft auf diesem Mac. Eigene Assistenten speicherst du aus jedem Gespräch (Rechtsklick in der Gesprächsliste).")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.categories, id: \.self) { category in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(category).font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                            ForEach(store.all.filter { $0.category == category }) { card($0) }
                        }
                    }
                }
            }
            .padding(24)
        }
        .sheet(item: $textInput) { a in
            VStack(alignment: .leading, spacing: 12) {
                Label(a.name, systemImage: a.icon).font(.title2.bold())
                Text(a.summary).foregroundStyle(.secondary)
                TextEditor(text: $text).font(.body).frame(minHeight: 220)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty { Text(a.placeholder).foregroundStyle(.tertiary).padding(6).allowsHitTesting(false) }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                HStack {
                    Spacer()
                    Button("Abbrechen") { textInput = nil }
                    Button("Starten") {
                        let input = text
                        textInput = nil
                        run(a, text: input, files: [])
                    }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(22).frame(width: 600)
        }
    }

    private func card(_ a: Assistant) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: a.icon).font(.title2).foregroundStyle(Theme.brand).frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(a.name).font(.headline)
                    Text(a.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            HStack {
                Text(inputHint(a)).font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if a.canAutomate {
                    Button { automate(a) } label: { Image(systemName: "clock.badge.checkmark") }
                        .buttonStyle(.borderless).help("Als Automation nach Zeitplan ausführen")
                }
                if !a.builtin {
                    Button(role: .destructive) { app.assistants.remove(a) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Assistent löschen")
                }
                Button("Starten") { start(a) }.buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }

    private func inputHint(_ a: Assistant) -> String {
        switch a.input {
        case .none: return a.builtin ? "ohne Eingabe" : "eigener Assistent"
        case .text: return "Text eingeben"
        case .files: return a.fileTypes.isEmpty ? "Datei wählen" : a.fileTypes.prefix(4).joined(separator: ", ") + (a.fileTypes.count > 4 ? " …" : "")
        }
    }

    private func start(_ a: Assistant) {
        if a.input == .text { text = ""; textInput = a } else { AssistantRunner.start(a, app: app) }
    }

    private func run(_ a: Assistant, text: String, files: [URL]) { AssistantRunner.run(a, text: text, files: files, app: app) }

    private func automate(_ a: Assistant) {
        var automation = Automation(name: a.name, prompt: a.prompt, outputs: [.notify, .file])
        automation.enabled = false
        app.automations.upsert(automation)
        app.requestedScreen = .automations
        app.notice = "„\(a.name)“ als Automation angelegt – Zeitplan einstellen und einschalten."
    }
}

/// Startet einen Assistenten: Datei wählen (falls nötig), neues Gespräch, Auftrag abschicken.
/// Bei Text-Eingabe kommt der Auftrag ins Eingabefeld – der Nutzer ergänzt seinen Text und schickt ab.
@MainActor
enum AssistantRunner {
    static func start(_ a: Assistant, app: AppState) {
        switch a.input {
        case .none: run(a, text: "", files: [], app: app)
        case .text:
            app.session.newChat()
            app.session.input = a.prompt
            app.requestedScreen = .agent
        case .files:
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.message = a.summary
            if !a.fileTypes.isEmpty { panel.allowedContentTypes = a.fileTypes.compactMap { UTType(filenameExtension: $0) } }
            if panel.runModal() == .OK, !panel.urls.isEmpty { run(a, text: "", files: panel.urls, app: app) }
        }
    }

    static func run(_ a: Assistant, text: String, files: [URL], app: AppState) {
        let session = app.session
        guard !session.isRunning else { app.notice = "Der Agent arbeitet gerade – bitte kurz warten."; return }
        session.newChat()
        session.documents = files
        session.input = a.prompt + text
        app.requestedScreen = .agent
        app.send()
    }
}
