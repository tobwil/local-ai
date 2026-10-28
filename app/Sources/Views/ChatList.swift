import SwiftUI

/// Gesprächsliste links vom Chat (wie bei Claude/ChatGPT): oben „Neues Gespräch“ und Suche, darunter angeheftete Gespräche,
/// die Projekte als aufklappbare Ordner mit ihren Gesprächen und zuletzt die Gespräche ohne Projekt.
/// Rechtsklick: Anheften, Umbenennen, als Skill/Assistent speichern, Papierkorb.
struct ChatList: View {
    @Environment(AppState.self) private var app
    @State private var query = ""
    @State private var renaming: ChatStore.Entry?
    @State private var newTitle = ""
    @State private var skillFrom: ChatStore.Entry?
    @State private var editing: Project?
    @State private var hoverProject: UUID?
    /// Projekte (bzw. „Ohne Projekt“ als nil), deren Gespräche vollständig statt nur die neuesten angezeigt werden.
    @State private var allShown: Set<UUID?> = []
    /// Aufgeklappte Projektordner (gemerkt).
    @AppStorage("offeneProjekte") private var openRaw = ""

    private static let preview = 5
    private static let previewLoose = 15
    private static let de = Locale(identifier: "de_DE")

    var body: some View {
        let session = app.session
        let _ = session.historyVersion
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let chats = searching ? ChatStore.search(query) : ChatStore.list()
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Button { session.newChat() } label: {
                    Label("Neues Gespräch", systemImage: "square.and.pencil").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered).controlSize(.large)
                .disabled(session.isRunning)
                .help(session.project.map { "Neues Gespräch im Projekt „\($0.name)“" } ?? "Neues Gespräch ohne Projekt")
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Suchen", text: $query).textFieldStyle(.plain)
                    if searching {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(10)

            List {
                if searching {
                    if chats.isEmpty { Text("Nichts gefunden.").foregroundStyle(.secondary).font(.callout) }
                    ForEach(chats) { row($0, showProject: true) }
                } else {
                    overview(chats)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(.background.secondary)
        .onAppear { if let id = session.project?.id { setOpen(id, true) } }
        .onChange(of: session.project?.id) { _, id in if let id { setOpen(id, true) } }
        .task(id: app.server.state.isUp) { if app.server.state.isUp { ChatTitles.backfill(app) } }
        .alert("Gespräch umbenennen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Titel", text: $newTitle)
            Button("Umbenennen") { if let r = renaming { session.rename(chatID: r.id, to: newTitle) } }
            Button("Abbrechen", role: .cancel) {}
        }
        .sheet(item: $skillFrom) { SkillFromChatSheet(chatID: $0.id, chatTitle: $0.title) }
        .sheet(item: $editing) { ProjectEditor(project: $0) }
    }

    // MARK: Übersicht: Angeheftet · Projekte · Ohne Projekt

    @ViewBuilder private func overview(_ chats: [ChatStore.Entry]) -> some View {
        let store = app.session.projects
        let pinned = chats.filter(\.angeheftet)
        let inProject = Dictionary(grouping: chats.filter { !$0.angeheftet && store.project(id: $0.projectID) != nil }) { $0.projectID! }
        let loose = chats.filter { !$0.angeheftet && store.project(id: $0.projectID) == nil }
        // Projekte mit dem jüngsten Gespräch zuerst (angeheftete zählen mit)
        let latest = Dictionary(chats.compactMap { e in e.projectID.map { ($0, e.date) } }, uniquingKeysWith: max)
        let projects = store.projects.sorted { (latest[$0.id] ?? $0.lastUsed) > (latest[$1.id] ?? $1.lastUsed) }

        if !pinned.isEmpty {
            Section("Angeheftet") {
                ForEach(pinned) { row($0, showProject: true) }
            }
        }
        Section("Projekte") {
            ForEach(projects) { p in projectFolder(p, inProject[p.id] ?? []) }
            Button { editing = Project(name: "Neues Projekt") } label: {
                Label("Neues Projekt …", systemImage: "folder.badge.plus").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(app.session.isRunning)
        }
        Section {
            if loose.isEmpty { Text("Noch keine.").font(.callout).foregroundStyle(.tertiary) }
            let all = allShown.contains(nil)
            ForEach(all ? loose : Array(loose.prefix(Self.previewLoose))) { row($0) }
            if loose.count > Self.previewLoose { moreButton(nil, total: loose.count, all: all, indent: false) }
        } header: {
            HStack {
                Text("Ohne Projekt")
                Spacer()
                Button { app.session.switchProject(nil) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).disabled(app.session.isRunning)
                    .help("Neues Gespräch ohne Projekt")
            }
        }
    }

    /// Projektordner: Klick klappt auf/zu, „+“ beginnt ein Gespräch darin, Rechtsklick für Bearbeiten und Finder.
    @ViewBuilder private func projectFolder(_ p: Project, _ entries: [ChatStore.Entry]) -> some View {
        let session = app.session
        let current = session.project?.id == p.id
        let isOpen = open.contains(p.id.uuidString)
        HStack(spacing: 6) {
            Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isOpen ? 90 : 0)).frame(width: 10)
            Image(systemName: isOpen ? "folder.fill" : "folder").foregroundStyle(Theme.gold)
            Text(p.name).lineLimit(1).fontWeight(current ? .semibold : .regular)
            Spacer(minLength: 4)
            if hoverProject == p.id && !session.isRunning {
                Button { session.switchProject(p); setOpen(p.id, true) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("Neues Gespräch in „\(p.name)“")
            } else {
                Text("\(entries.count)").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { setOpen(p.id, !isOpen) } }
        .onHover { hoverProject = $0 ? p.id : (hoverProject == p.id ? nil : hoverProject) }
        .help(p.folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? p.name)
        .contextMenu {
            Button("Neues Gespräch in „\(p.name)“") { session.switchProject(p); setOpen(p.id, true) }.disabled(session.isRunning)
            Button("Projekt bearbeiten …") { editing = p }
            if let url = p.folderURL { Button("Ordner im Finder öffnen") { NSWorkspace.shared.open(url) } }
        }
        if isOpen {
            if entries.isEmpty {
                Text("Noch keine Gespräche").font(.callout).foregroundStyle(.tertiary).padding(.leading, 34)
            }
            let all = allShown.contains(p.id)
            ForEach(all ? entries : Array(entries.prefix(Self.preview))) { row($0, indent: true) }
            if entries.count > Self.preview { moreButton(p.id, total: entries.count, all: all, indent: true) }
        }
    }

    private func moreButton(_ id: UUID?, total: Int, all: Bool, indent: Bool) -> some View {
        Button(all ? "Weniger anzeigen" : "Alle \(total) anzeigen") {
            if all { allShown.remove(id) } else { allShown.insert(id) }
        }
        .buttonStyle(.borderless).font(.caption)
        .padding(.leading, indent ? 34 : 0)
    }

    // MARK: Zeile

    private func row(_ e: ChatStore.Entry, indent: Bool = false, showProject: Bool = false) -> some View {
        let session = app.session
        let active = e.id == session.chatID
        let project = showProject ? session.projects.project(id: e.projectID) : nil
        return Button {
            if !session.isRunning { session.load(id: e.id) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if e.angeheftet { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Theme.gold) }
                    if e.laeuft { Image(systemName: "arrow.clockwise.circle.fill").font(.caption).foregroundStyle(Theme.gold) }
                    Text(e.title).lineLimit(1).fontWeight(active ? .semibold : .regular)
                    Spacer(minLength: 4)
                    Text(Self.shortDate(e.date)).font(.caption).foregroundStyle(.tertiary).monospacedDigit().fixedSize()
                }
                if let snippet = e.snippet {
                    Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let project {
                    Label(project.name, systemImage: "folder").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, indent ? 34 : 0)
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

    /// Heute die Uhrzeit, gestern „Gestern“, in dieser Woche der Wochentag, sonst das Datum.
    static func shortDate(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(de)) }
        if cal.isDateInYesterday(d) { return "Gestern" }
        if let days = cal.dateComponents([.day], from: d, to: .now).day, days < 6 {
            return d.formatted(Date.FormatStyle().weekday(.abbreviated).locale(de))
        }
        return d.formatted(Date.FormatStyle().day(.twoDigits).month(.twoDigits).locale(de))
    }

    private var open: Set<String> { Set(openRaw.split(separator: ",").map(String.init)) }

    private func setOpen(_ id: UUID, _ on: Bool) {
        var s = open
        if on { s.insert(id.uuidString) } else { s.remove(id.uuidString) }
        openRaw = s.sorted().joined(separator: ",")
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
