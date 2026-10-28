import SwiftUI

/// Die eine Seitenleiste der App (wie bei ChatGPT): oben „Neues Gespräch“ und Suche, darunter Assistenten, Wissen und
/// Automationen, dann angeheftete Gespräche, Projekte als aufklappbare Ordner und alle übrigen Gespräche.
/// Modelle, Einstellungen und Werkzeuge liegen im Menü ganz unten.
struct AppSidebar: View {
    @Environment(AppState.self) private var app
    @Binding var screen: Screen
    @State private var query = ""
    @State private var renaming: ChatStore.Entry?
    @State private var newTitle = ""
    @State private var skillFrom: ChatStore.Entry?
    @State private var editing: Project?
    @FocusState private var searchFocused: Bool
    /// Projekte (bzw. „Gespräche“ als nil), deren Gespräche vollständig statt nur die neuesten angezeigt werden.
    @State private var allShown: Set<UUID?> = []
    /// Aufgeklappte Projektordner (gemerkt).
    @AppStorage("offeneProjekte") private var openRaw = ""

    static let navigation: [Screen] = [.assistants, .knowledge, .automations]
    private static let preview = 5
    private static let previewLoose = 20

    var body: some View {
        let session = app.session
        let _ = session.historyVersion
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let chats = searching ? ChatStore.search(query) : ChatStore.list()
        List(selection: Binding(get: { Self.navigation.contains(screen) ? screen : nil }, set: { if let s = $0 { screen = s } })) {
            Section {
                ForEach(Self.navigation) { s in Label(s.title, systemImage: s.icon).tag(s) }
            }
            if searching {
                Section("Suchergebnisse") {
                    if chats.isEmpty { Text("Nichts gefunden.").foregroundStyle(.secondary).font(.callout) }
                    ForEach(chats) { row($0, showProject: true) }
                }
            } else {
                overview(chats)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { header(searching).background(.bar) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                SidebarMenu(screen: $screen)
            }
            .background(.bar)
        }
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

    private func header(_ searching: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Wordmark(size: 22).padding(.horizontal, 6)
            Button { newChat(in: nil) } label: {
                Label("Neues Gespräch", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 7)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(app.session.isRunning)
            .keyboardShortcut("n", modifiers: .command)
            .help("Neues Gespräch (⌘N oder ⇧⌘O)")
            .background {
                // Weitere Tastenkürzel wie bei ChatGPT: ⇧⌘O neues Gespräch, ⌘K Suche
                Button("") { newChat(in: nil) }.keyboardShortcut("o", modifiers: [.command, .shift]).opacity(0)
                Button("") { searchFocused = true }.keyboardShortcut("k", modifiers: .command).opacity(0)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Suchen  ⌘K", text: $query).textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onExitCommand { query = ""; searchFocused = false }
                if searching {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 6)
    }

    // MARK: Angeheftet · Projekte · Gespräche

    @ViewBuilder private func overview(_ chats: [ChatStore.Entry]) -> some View {
        let store = app.session.projects
        let pinned = chats.filter(\.angeheftet)
        let inProject = Dictionary(grouping: chats.filter { !$0.angeheftet && store.project(id: $0.projectID) != nil }) { $0.projectID! }
        let automated = chats.filter { !$0.angeheftet && $0.automation != nil && store.project(id: $0.projectID) == nil }
        let loose = chats.filter { !$0.angeheftet && $0.automation == nil && store.project(id: $0.projectID) == nil }
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
                Label("Neues Projekt", systemImage: "folder.badge.plus").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(app.session.isRunning)
            .help("Ein Projekt bündelt Gespräche, einen Ordner und eigene Anweisungen.")
        }
        if !automated.isEmpty { automationFolder(automated) }
        Section("Gespräche") {
            if loose.isEmpty { Text("Noch keine.").font(.callout).foregroundStyle(.tertiary) }
            let all = allShown.contains(nil)
            ForEach(all ? loose : Array(loose.prefix(Self.previewLoose))) { row($0) }
            if loose.count > Self.previewLoose { moreButton(nil, total: loose.count, all: all, indent: false) }
        }
    }

    /// Projektordner: Klick klappt auf/zu; aufgeklappt steht „Neues Gespräch“ oben, Rechtsklick für Bearbeiten und Finder.
    @ViewBuilder private func projectFolder(_ p: Project, _ entries: [ChatStore.Entry]) -> some View {
        let session = app.session
        let current = session.project?.id == p.id && screen == .agent
        let isOpen = open.contains(p.id.uuidString)
        HStack(spacing: 6) {
            Image(systemName: isOpen ? "folder.fill" : "folder").foregroundStyle(Theme.gold).frame(width: 18)
            Text(p.name).lineLimit(1).fontWeight(current ? .semibold : .regular)
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { setOpen(p.id, !isOpen) } }
        .help(p.folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? p.name)
        .contextMenu {
            Button("Neues Gespräch in „\(p.name)“") { newChat(in: p) }.disabled(session.isRunning)
            Button("Projekt bearbeiten …") { editing = p }
            if let url = p.folderURL { Button("Ordner im Finder öffnen") { NSWorkspace.shared.open(url) } }
        }
        if isOpen {
            Button { newChat(in: p) } label: {
                Label("Neues Gespräch", systemImage: "plus").font(.callout).foregroundStyle(.secondary)
                    .padding(.leading, 24).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(session.isRunning)
            let all = allShown.contains(p.id)
            ForEach(all ? entries : Array(entries.prefix(Self.preview))) { row($0, indent: true) }
            if entries.count > Self.preview { moreButton(p.id, total: entries.count, all: all, indent: true) }
        }
    }

    /// Ergebnisse der Automationen als Gespräche – aufklappbar wie ein Projektordner.
    @ViewBuilder private func automationFolder(_ entries: [ChatStore.Entry]) -> some View {
        let isOpen = open.contains("automationen")
        let unread = entries.filter { $0.date > lastSeenAutomation }.count
        Section {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.checkmark").foregroundStyle(Theme.primary).frame(width: 18)
                Text("Automationen").lineLimit(1)
                if unread > 0 {
                    Text("\(unread) neu").font(.caption2.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Theme.primary, in: Capsule())
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.snappy(duration: 0.2)) { openRaw = (isOpen ? open.subtracting(["automationen"]) : open.union(["automationen"])).sorted().joined(separator: ",") }
                lastSeenAutomationRaw = Date().timeIntervalSince1970
            }
            .help("Jedes Ergebnis einer Automation als Gespräch – zum Nachfragen.")
            if isOpen {
                let all = allShown.contains(Self.automationKey)
                ForEach(all ? entries : Array(entries.prefix(Self.preview))) { row($0, indent: true) }
                if entries.count > Self.preview { moreButton(Self.automationKey, total: entries.count, all: all, indent: true) }
            }
        }
    }

    private static let automationKey = UUID(uuidString: "00000000-0000-0000-0000-00000000A070")
    @AppStorage("automationenGesehen") private var lastSeenAutomationRaw = 0.0
    private var lastSeenAutomation: Date { Date(timeIntervalSince1970: lastSeenAutomationRaw) }

    private func moreButton(_ id: UUID?, total: Int, all: Bool, indent: Bool) -> some View {
        Button(all ? "Weniger anzeigen" : "Alle \(total) anzeigen") {
            if all { allShown.remove(id) } else { allShown.insert(id) }
        }
        .buttonStyle(.borderless).font(.caption)
        .padding(.leading, indent ? 24 : 0)
    }

    private func newChat(in p: Project?) {
        guard !app.session.isRunning else { return }
        app.session.switchProject(p)
        app.session.newChat()
        if let p { setOpen(p.id, true) }
        screen = .agent
    }

    // MARK: Zeile

    private func row(_ e: ChatStore.Entry, indent: Bool = false, showProject: Bool = false) -> some View {
        let session = app.session
        let active = e.id == session.chatID && screen == .agent
        let project = showProject ? session.projects.project(id: e.projectID) : nil
        return Button {
            if !session.isRunning || e.id == session.chatID { session.load(id: e.id); screen = .agent }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if e.angeheftet { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Theme.gold) }
                    if e.laeuft { Image(systemName: "arrow.clockwise.circle.fill").font(.caption).foregroundStyle(Theme.gold) }
                    if e.id == session.chatID && session.isRunning { ProgressView().controlSize(.mini) }
                    Text(e.title).lineLimit(1).fontWeight(active ? .semibold : .regular)
                }
                if let snippet = e.snippet {
                    Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let project {
                    Label(project.name, systemImage: "folder").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, indent ? 24 : 0)
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
        .help(session.isRunning && e.id != session.chatID
              ? "Der Agent arbeitet gerade – erst stoppen oder warten, dann wechseln."
              : "\(e.title) – \(e.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "de_DE"))))")
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

/// Menü ganz unten in der Seitenleiste (wie das Profil-Menü bei ChatGPT): Zustand der Engine und das aktive Modell,
/// darin Übersicht, Modelle, Skills, Werkzeuge, Verbinden und Einstellungen.
struct SidebarMenu: View {
    @Environment(AppState.self) private var app
    @Binding var screen: Screen

    static let screens: [Screen] = [.overview, .models, .extensions, .tools, .connect, .settings]

    var body: some View {
        Menu {
            ForEach(Self.screens) { s in
                Button { screen = s } label: { Label(s.title, systemImage: s.icon) }
            }
            Button { app.showSetup = true } label: { Label("Einrichtung & Berechtigungen …", systemImage: "checklist") }
            Divider()
            Button { screen = .compare } label: { Label(Screen.compare.title, systemImage: Screen.compare.icon) }
            Button { screen = .log } label: { Label(Screen.log.title, systemImage: Screen.log.icon) }
            Divider()
            switch app.server.state {
            case .running, .starting:
                Button { app.server.stop() } label: { Label("Engine stoppen", systemImage: "power") }
            case .external:
                EmptyView()
            default:
                Button { app.server.start() } label: { Label("Engine starten", systemImage: "power") }
                    .disabled(!app.server.engineInstalled)
            }
        } label: {
            HStack(spacing: 8) {
                StatusDot(state: app.server.state)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.selectedModelName).font(.callout.weight(.medium)).lineLimit(1)
                    Text(app.server.state.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "gearshape").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Self.screens.contains(screen) || screen == .compare || screen == .log
                        ? AnyShapeStyle(Theme.primary.opacity(0.15)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .help("Übersicht, Modelle, Skills, Werkzeuge, Verbinden und Einstellungen")
        .padding(8)
    }
}

/// Modellwahl oben in der Mitte (wie bei ChatGPT): lokale Modelle, Cloud-Modelle, „Modelle verwalten“.
struct ModelPicker: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Menu {
            Section("Auf diesem Mac – privat") {
                ForEach(app.installedModels, id: \.id) { m in
                    Button { app.selectedModelID = m.id } label: {
                        Label(m.name + (m.vision ? " · versteht Bilder" : ""),
                              systemImage: app.selectedModelID == m.id ? "checkmark" : "desktopcomputer")
                    }
                }
            }
            if !CloudModels.all.isEmpty {
                Section("Cloud – Daten verlassen den Mac") {
                    ForEach(CloudModels.all, id: \.self) { id in
                        Button { app.selectedModelID = id } label: {
                            Label(CloudModels.displayName(id), systemImage: app.selectedModelID == id ? "checkmark" : "cloud")
                        }
                    }
                }
            }
            Divider()
            Button("Modelle verwalten …") { app.requestedScreen = .models }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: app.selectedIsCloud ? "cloud" : "desktopcomputer")
                    .foregroundStyle(app.selectedIsCloud ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                Text(app.selectedModelName).fontWeight(.semibold).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(app.session.isRunning)
        .help(app.selectedIsCloud ? "Cloud-Modell: Gespräche gehen an den Anbieter." : "Modell wählen – lokale Modelle bleiben auf diesem Mac.")
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
