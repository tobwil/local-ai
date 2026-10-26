import SwiftUI

/// Gesprächsliste links vom Chat (wie bei Claude/ChatGPT): Suche über alle Gespräche, nach Datum gruppiert,
/// Umbenennen, Löschen und „Als Skill speichern“ per Rechtsklick. Ohne Projekt zeigt sie alle Gespräche.
struct ChatList: View {
    @Environment(AppState.self) private var app
    @State private var query = ""
    @State private var allProjects = false
    @State private var renaming: ChatStore.Entry?
    @State private var newTitle = ""
    @State private var skillFrom: ChatStore.Entry?

    var body: some View {
        let session = app.session
        let _ = session.historyVersion
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        // Ohne Projekt: alle Gespräche. Im Projekt: nur dessen Gespräche (mit „Alle anzeigen“). Suche: immer alle.
        let current = session.project?.id
        let onlyProject = current != nil && !allProjects && !searching
        let chats = (searching ? ChatStore.search(query) : ChatStore.list()).filter { !onlyProject || $0.projectID == current }
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Alle Gespräche durchsuchen", text: $query).textFieldStyle(.plain)
                    if searching {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                if let p = session.project, !searching {
                    HStack {
                        Label(allProjects ? "Alle Gespräche" : p.name, systemImage: allProjects ? "tray.full" : "folder")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button(allProjects ? "Nur „\(p.name)“" : "Alle anzeigen") { allProjects.toggle() }
                            .buttonStyle(.borderless).font(.caption)
                    }
                }
            }
            .padding(10)

            List {
                if chats.isEmpty {
                    Text(searching ? "Nichts gefunden." : "Noch keine Gespräche.").foregroundStyle(.secondary).font(.callout)
                }
                ForEach(groups(chats), id: \.0) { title, entries in
                    Section(title) {
                        ForEach(entries) { e in row(e, showProject: !onlyProject) }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(.background.secondary)
        .alert("Gespräch umbenennen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Titel", text: $newTitle)
            Button("Umbenennen") { if let r = renaming { session.rename(chatID: r.id, to: newTitle) } }
            Button("Abbrechen", role: .cancel) {}
        }
        .sheet(item: $skillFrom) { SkillFromChatSheet(chatID: $0.id, chatTitle: $0.title) }
    }

    private func row(_ e: ChatStore.Entry, showProject: Bool) -> some View {
        let session = app.session
        let active = e.id == session.chatID
        return Button {
            if !session.isRunning { session.load(id: e.id) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if e.angeheftet { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Theme.gold) }
                    Text(e.title).lineLimit(1).fontWeight(active ? .semibold : .regular)
                }
                if let snippet = e.snippet {
                    Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if showProject, let p = session.projects.project(id: e.projectID) {
                    Label(p.name, systemImage: "folder").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(active ? RoundedRectangle(cornerRadius: 6).fill(Theme.primary.opacity(0.18)) : nil)
        .contextMenu {
            Button(e.angeheftet ? "Lösen" : "Anheften") { session.anheften(chatID: e.id, !e.angeheftet) }
            Button("Umbenennen …") { newTitle = e.title; renaming = e }
            Button("Als Skill speichern …") { skillFrom = e }
            Button("Als Assistent speichern") { saveAssistant(e) }
            Divider()
            Button("In den Papierkorb", role: .destructive) { session.deleteChat(id: e.id) }
        }
        .help(e.title)
    }

    /// Die erste Nachricht des Gesprächs wird zum wiederverwendbaren Assistenten (Galerie „Assistenten“).
    private func saveAssistant(_ e: ChatStore.Entry) {
        guard let json = ChatStore.load(id: e.id),
              let first = (json["items"] as? [[String: Any]])?.first(where: { $0["k"] as? String == "user" })?["text"] as? String else { return }
        let prompt = first.components(separatedBy: "\n").filter { !$0.hasPrefix("📎") }.joined(separator: "\n")
        app.assistants.add(Assistant(id: UUID().uuidString, name: String(e.title.prefix(40)), icon: "star", summary: String(prompt.prefix(120)),
                                     category: "Eigene", prompt: prompt))
        app.notice = "Als Assistent gespeichert – zu finden unter „Assistenten“."
    }

    /// Heute · Gestern · Letzte 7 Tage · Letzte 30 Tage · nach Monat.
    private func groups(_ entries: [ChatStore.Entry]) -> [(String, [ChatStore.Entry])] {
        let cal = Calendar.current
        let now = Date()
        func bucket(_ d: Date) -> String {
            if cal.isDateInToday(d) { return "Heute" }
            if cal.isDateInYesterday(d) { return "Gestern" }
            let days = cal.dateComponents([.day], from: d, to: now).day ?? 0
            if days < 7 { return "Letzte 7 Tage" }
            if days < 30 { return "Letzte 30 Tage" }
            return d.formatted(.dateTime.month(.wide).year())
        }
        var order: [String] = []
        var map: [String: [ChatStore.Entry]] = [:]
        for e in entries {
            let b = e.angeheftet ? "Angeheftet" : bucket(e.date)
            if map[b] == nil { order.append(b) }
            map[b, default: []].append(e)
        }
        // Angeheftete Gespräche immer ganz oben
        if let i = order.firstIndex(of: "Angeheftet"), i > 0 { order.remove(at: i); order.insert("Angeheftet", at: 0) }
        return order.map { ($0, map[$0]!) }
    }
}

/// Aus einem Gespräch einen wiederverwendbaren Skill machen („Kochbuch“): Das Modell schreibt einen Entwurf,
/// du prüfst und speicherst ihn – danach nutzt der Agent ihn bei passenden Aufgaben von selbst.
struct SkillFromChatSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let chatID: String
    let chatTitle: String
    /// Weitere Gespräche mit ähnlichem Auftrag – fließen in denselben Entwurf ein.
    var moreChats: [String] = []
    @State private var draft = ""
    @State private var working = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Als Skill speichern").font(.title2.bold())
            Text("Aus „\(chatTitle)“\(moreChats.isEmpty ? "" : " und \(moreChats.count) ähnlichen Gesprächen") wird eine Anleitung, die der Agent künftig bei ähnlichen Aufgaben selbst lädt. Prüfe den Entwurf und passe ihn bei Bedarf an.")
                .font(.callout).foregroundStyle(.secondary)
            if working {
                HStack { ProgressView().controlSize(.small); Text("Das Modell schreibt den Entwurf …").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, minHeight: 320)
            } else {
                TextEditor(text: $draft).font(.system(.callout, design: .monospaced)).frame(minHeight: 320)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            HStack {
                Text("Wird gespeichert unter ~/.kilokal/skills/<name>/SKILL.md").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Abbrechen") { dismiss() }
                Button("Skill speichern") {
                    do {
                        let name = try app.saveSkill(markdown: draft)
                        app.session.input = ""
                        error = nil
                        dismiss()
                        app.notice = "Skill „\(name)“ gespeichert – der Agent nutzt ihn ab jetzt bei passenden Aufgaben."
                    } catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || draft.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 680)
        .task {
            do { draft = try await app.draftSkill(fromChats: [chatID] + moreChats) } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}
