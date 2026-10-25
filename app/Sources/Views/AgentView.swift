import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AgentView: View {
    @Environment(AppState.self) private var app
    @AppStorage("previewFraction") private var previewFraction = 0.45
    @AppStorage("chatListOpen") private var chatListOpen = true
    @AppStorage("chatListWidth") private var chatListWidth = 260.0
    @State private var dragStartWidth: Double?
    @State private var skillSheet = false

    var body: some View {
        HStack(spacing: 0) {
            if chatListOpen {
                ChatList().frame(width: chatListWidth)
                // Breite per Ziehen ändern (wird gemerkt)
                Rectangle().fill(.separator).frame(width: 1)
                    .overlay { Color.clear.frame(width: 9).contentShape(Rectangle()).onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    } }
                    .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                        let start = dragStartWidth ?? chatListWidth
                        dragStartWidth = start
                        chatListWidth = min(max(start + v.translation.width, 200), 480)
                    }.onEnded { _ in dragStartWidth = nil })
            }
            chatAndPreview
        }
        .sheet(isPresented: $skillSheet) { SkillFromChatSheet(chatID: app.session.chatID, chatTitle: app.session.title) }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { withAnimation { chatListOpen.toggle() } } label: {
                    Label("Gespräche", systemImage: "list.bullet.rectangle")
                }
                .help("Gesprächsliste mit Suche ein-/ausblenden")
            }
            ToolbarItem(placement: .principal) { ProjectPicker() }
            ToolbarItem {
                let preview = app.session.preview
                Button { withAnimation { preview.isOpen.toggle() } } label: {
                    Label("Vorschau", systemImage: preview.isOpen ? "sidebar.right" : "rectangle.righthalf.inset.filled")
                }
                .help(preview.files.isEmpty ? "Vorschau (Seiten, Spiele, Bilder, Dokumente des Agenten)" : "Vorschau – \(preview.files.count) Datei(en)")
            }
            ToolbarItem {
                Button { app.session.newChat() } label: { Label("Neues Gespräch", systemImage: "square.and.pencil") }
                    .help("Neues Gespräch\(app.session.project.map { " in „\($0.name)“" } ?? "")")
            }
        }
    }

    private var chatAndPreview: some View {
        GeometryReader { geo in
            // Chat links, Vorschau rechts; die Trennlinie lässt sich ziehen (Anteil wird gemerkt).
            let previewWidth = min(max(geo.size.width * previewFraction, 320), max(geo.size.width - 420, 320))
            HStack(spacing: 0) {
                chat.frame(maxWidth: .infinity)
                if app.session.preview.isOpen {
                    Rectangle().fill(.separator).frame(width: 1)
                        .overlay { Color.clear.frame(width: 9).contentShape(Rectangle()).onHover { inside in
                            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                        } }
                        .gesture(DragGesture(coordinateSpace: .named("agent")).onChanged { v in
                            previewFraction = min(max(1 - v.location.x / geo.size.width, 0.25), 0.7)
                        })
                    PreviewPane().frame(width: previewWidth)
                }
            }
            .coordinateSpace(name: "agent")
        }
    }

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if app.session.items.isEmpty { EmptyAgent() }
                        // Arbeitsschritte je Auftrag kompakt zusammengefasst, die Antwort groß darunter
                        ForEach(ChatSegment.build(app.session.items)) { segment in
                            switch segment {
                            case let .item(item): ItemView(item: item).id(item.id)
                            case let .steps(items): StepsGroup(items: items).id(items[0].id)
                            }
                        }
                        // Nach einem gelungenen Ablauf mit mehreren Schritten: als wiederverwendbaren Skill anbieten.
                        if !app.session.isRunning, app.session.successfulToolCalls >= 3,
                           case .assistant(let text, _, _)? = app.session.items.last?.kind, !text.isEmpty {
                            Button { skillSheet = true } label: {
                                Label("Diesen Ablauf als Skill speichern – beim nächsten Mal weiß der Agent, wie es geht", systemImage: "lightbulb")
                                    .font(.callout)
                            }
                            .buttonStyle(.borderless).foregroundStyle(Theme.gold)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(24)
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: app.session.items.count) { withAnimation { proxy.scrollTo("bottom") } }
                .onChange(of: lastText) { proxy.scrollTo("bottom") }
            }
            Composer()
        }
    }

    private var lastText: Int {
        guard case let .assistant(text, thinking, _)? = app.session.items.last?.kind else { return 0 }
        return text.count + thinking.count
    }
}

private struct EmptyAgent: View {
    @Environment(AppState.self) private var app

    /// „Guten Morgen, Tobias.“ – Vorname aus dem macOS-Benutzerkonto.
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 5 ? "Gute Nacht" : hour < 11 ? "Guten Morgen" : hour < 17 ? "Hallo" : hour < 22 ? "Guten Abend" : "Gute Nacht"
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "\(part)." : "\(part), \(first)."
    }

    var body: some View {
        let mode = app.session.mode
        let project = app.session.project
        let ideas = mode.ideas
        let quick = ["transkribieren", "zusammenfassen", "mail-antwort", "recherche", "excel-auswerten"]
            .compactMap { id in app.assistants.all.first { $0.id == id } }
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Wordmark(suffix: project.map { $0.name.lowercased() } ?? "agent", size: 22)
                Text(project == nil ? greeting : "Projekt „\(project!.name)“")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                Text(project == nil ? "Was steht an? Fragen, recherchieren, Dateien, Kalender, Browser und Code – alles auf diesem Mac."
                                    : mode == .code ? "Code-Projekt: \(mode.tagline)." : "Gespräche, Ordner und Anweisungen dieses Projekts an einem Ort.")
                    .font(.title3).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(ideas, id: \.text) { icon, text in
                    Button { app.session.input = text } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: icon).foregroundStyle(Theme.primary).frame(width: 18)
                            Text(text).multilineTextAlignment(.leading).foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6)))
                    }
                    .buttonStyle(.plain)
                }
            }
            if !quick.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Assistenten").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    FlowLayout(spacing: 8) {
                        ForEach(quick) { a in
                            Button { AssistantRunner.start(a, app: app) } label: {
                                Label(a.name, systemImage: a.icon).lineLimit(1).fixedSize()
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(Theme.gold.opacity(0.14), in: Capsule())
                                    .overlay(Capsule().strokeBorder(Theme.gold.opacity(0.35)))
                            }
                            .buttonStyle(.plain)
                            .help(a.summary)
                        }
                        Button("Alle …") { app.requestedScreen = .assistants }.buttonStyle(.borderless)
                    }
                }
            }
            Text("\(app.modeTools.count) Werkzeuge · \(app.plugins.skills.count) Skills · \(app.selectedModelName) – läuft auf diesem Mac")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.top, 36)
    }
}

private struct ItemView: View {
    @Environment(AppState.self) private var app
    let item: AgentSession.Item

    var body: some View {
        switch item.kind {
        case let .user(text, images):
            HStack(alignment: .top) {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 6) {
                    if !images.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(images.enumerated()), id: \.offset) { _, data in
                                if let img = NSImage(data: data) {
                                    Image(nsImage: img).resizable().scaledToFill()
                                        .frame(width: 120, height: 90).clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                    }
                    if !text.isEmpty {
                        Text(text)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .foregroundStyle(.white)
                            .background(Theme.brand, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
        case let .assistant(text, thinking, stats):
            VStack(alignment: .leading, spacing: 8) {
                if !thinking.isEmpty {
                    DisclosureGroup {
                        Text(thinking).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    } label: {
                        Label("Gedanken", systemImage: "brain").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if text.isEmpty && stats == nil && app.session.isRunning && item.id == app.session.items.last?.id {
                    TypingDots(thinking: !thinking.isEmpty)
                }
                if !text.isEmpty {
                    RichText(text: text)
                }
                if let stats {
                    HStack(spacing: 10) {
                        Label("\(stats.tokPerSec.oneDecimal) tok/s", systemImage: "bolt.fill")
                        Text("\(stats.tokens) Tokens")
                        Text("erstes Token nach \(String(format: "%.1f", stats.ttft)) s")
                        if !stats.model.isEmpty { Text(CloudModels.displayName(stats.model)) }
                    }
                    .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case let .tool(name, source, arguments, state, result):
            ToolCard(id: item.id, name: name, source: source, arguments: arguments, state: state, result: result)
        case let .error(message) where message.hasPrefix(AgentSession.stepLimitPrefix):
            HStack(spacing: 10) {
                Label(message, systemImage: "pause.circle.fill").foregroundStyle(.orange).font(.callout)
                if !app.session.isRunning && item.id == app.session.items.last?.id {
                    Button("Weitermachen") {
                        app.session.input = "Mach weiter, wo du aufgehört hast."
                        app.send()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(10).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        case let .error(message) where message.hasPrefix(AgentSession.qualityPrefix):
            Label(message, systemImage: "checkmark.seal")
                .font(.callout).foregroundStyle(Theme.primary)
                .padding(10).background(Theme.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        case let .error(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).font(.callout)
                .padding(10).background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct ToolCard: View {
    @Environment(AppState.self) private var app
    let id: UUID
    let name, source, arguments: String
    let state: AgentSession.ToolState
    let result: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.callout.monospaced().weight(.semibold))
                    Text(source).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if state == .done, let url = PreviewStore.writtenPath(tool: name, arguments: arguments, workspace: app.session.workspace) {
                    Button { app.session.preview.show(url) } label: { Label("Vorschau", systemImage: "eye") }
                        .buttonStyle(.borderless).font(.caption)
                        .help(url.path)
                }
                Button { withAnimation { expanded.toggle() } } label: {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(expanded || state == .awaitingApproval ? 90 : 0))
                }
                .buttonStyle(.borderless)
            }
            if state == .awaitingApproval {
                approval
            } else if expanded {
                CodeBlock(code: arguments, language: "Argumente")
            }
            if expanded && !result.isEmpty {
                CodeBlock(code: String(result.prefix(6000)), language: "Ergebnis")
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(state == .awaitingApproval ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.separator.opacity(0.6)),
                          lineWidth: state == .awaitingApproval ? 2 : 1))
    }

    /// Freigabe in Klartext: was, das Wichtigste daraus, warum gefragt wird – und die Wahl.
    @ViewBuilder private var approval: some View {
        let info = ToolExplain.explain(name: name, source: source, arguments: arguments)
        let parsed = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]) ?? [:]
        let danger = AgentSession.dangerReason(tool: name, args: parsed)
        VStack(alignment: .leading, spacing: 10) {
            Text(info.summary).font(.callout.weight(.semibold))
            if let detail = info.detail, !detail.isEmpty { CodeBlock(code: detail, language: info.detailLabel) }
            VStack(alignment: .leading, spacing: 4) {
                Label(info.risk, systemImage: "info.circle").foregroundStyle(.secondary)
                if let danger {
                    Label("Notbremse: \(danger) – deshalb fragt KI/lokal auch im YOLO-Modus.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Label("Du wirst gefragt, weil der YOLO-Modus aus ist. Ordner: \(app.session.workspace.path)", systemImage: "hand.raised")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            HStack {
                Button("Alle Details") { withAnimation { expanded.toggle() } }.buttonStyle(.borderless).font(.caption)
                Spacer()
                Button("Ablehnen") { app.session.approve(id, false) }
                if danger == nil {
                    Button("Für dieses Gespräch alles erlauben") {
                        app.session.autoApprove = true
                        app.session.approve(id, true)
                    }
                    .help("Schaltet YOLO ein: Der Agent fragt nicht mehr nach (die Notbremse bleibt aktiv).")
                }
                Button("Erlauben") { app.session.approve(id, true) }.buttonStyle(.borderedProminent).keyboardShortcut(.return)
            }
            if expanded { CodeBlock(code: arguments, language: "Argumente (vollständig)") }
        }
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .running: ProgressView().controlSize(.small).frame(width: 22)
        case .awaitingApproval: Image(systemName: "hand.raised.fill").foregroundStyle(.orange).frame(width: 22)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 22)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).frame(width: 22)
        case .denied: Image(systemName: "nosign").foregroundStyle(.secondary).frame(width: 22)
        }
    }
}

private struct Composer: View {
    @Environment(AppState.self) private var app
    @FocusState private var focused: Bool
    @State private var captureError: String?

    var body: some View {
        @Bindable var session = app.session
        VStack(spacing: 8) {
            // Statuszeile: Tempo, Cloud-Hinweis, Modell
            HStack(spacing: 10) {
                Spacer()
                if session.isRunning && session.liveTokPerSec > 0 {
                    Label("\(session.liveTokPerSec.oneDecimal) tok/s", systemImage: "bolt.fill")
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.primary)
                        .contentTransition(.numericText())
                }
                if app.selectedIsCloud {
                    Chip(text: "Cloud – Daten verlassen den Mac", systemImage: "cloud", tint: .orange)
                }
                Text(app.selectedModelName).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }

            if app.talkMode { TalkBar() }
            if let captureError { Label(captureError, systemImage: "camera.metering.unknown").font(.caption).foregroundStyle(.orange) }

            if let e = app.voice.error {
                Label(e, systemImage: "mic.slash").font(.caption).foregroundStyle(.orange)
            }

            if !session.documents.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(session.documents, id: \.self) { url in
                            HStack(spacing: 5) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                                Text(url.lastPathComponent).font(.caption).lineLimit(1)
                                Button { session.documents.removeAll { $0 == url } } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.quaternary.opacity(0.6), in: Capsule())
                            .help(url.path)
                        }
                    }
                }
            }
            if !session.attachments.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(session.attachments.enumerated()), id: \.offset) { i, data in
                        if let img = NSImage(data: data) {
                            Image(nsImage: img).resizable().scaledToFill().frame(width: 64, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(alignment: .topTrailing) {
                                    Button { session.attachments.remove(at: i) } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
                                    }
                                    .buttonStyle(.plain).padding(2)
                                }
                        }
                    }
                    if app.selectedModel?.vision != true && !app.selectedIsCloud {
                        Label("Das gewählte Modell versteht keine Bilder – wähle ein Vision-Modell unter Modelle.", systemImage: "eye.slash")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                }
            }

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(suggestions) { c in
                        Button {
                            session.input = "/\(c.name) "
                            focused = true
                        } label: {
                            HStack {
                                Text("/\(c.name)").font(.callout.monospaced().weight(.semibold))
                                Text(c.argumentHint).font(.caption).foregroundStyle(.tertiary)
                                Text(c.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                Text(c.source).font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
            }

            // Eingabe wie bei Claude/ChatGPT: Textfeld über die volle Breite, darunter Schalter und Knöpfe.
            VStack(alignment: .leading, spacing: 8) {
                TextField(app.canSendOrStart ? "Frag etwas oder gib dem Agenten eine Aufgabe …" : "Erst die Engine einrichten (Übersicht)",
                          text: $session.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit { app.send() }
                    .padding(.horizontal, 4).padding(.top, 4)
                HStack(spacing: 10) {
                    ViewThatFits(in: .horizontal) {
                        toggles(compact: false)
                        toggles(compact: true)
                    }
                    .controlSize(.small)
                    Spacer(minLength: 6)
                    Button { app.voice.toggleListening(currentText: session.input) } label: {
                        Image(systemName: app.voice.isListening ? "mic.fill" : "mic").font(.system(size: 20))
                            .symbolEffect(.pulse, isActive: app.voice.isListening)
                    }
                    .buttonStyle(.plain).foregroundStyle(app.voice.isListening ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .help("Diktieren (auf dem Mac erkannt)")
                    Button {
                        if app.voice.isSpeaking { app.voice.stopSpeaking() } else { app.settings.readAloud.toggle() }
                    } label: {
                        Image(systemName: app.voice.isSpeaking ? "speaker.wave.3.fill" : (app.settings.readAloud ? "speaker.wave.2" : "speaker.slash"))
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.plain).foregroundStyle(app.settings.readAloud ? AnyShapeStyle(Theme.primary) : AnyShapeStyle(.secondary))
                    .help(app.voice.isSpeaking ? "Vorlesen stoppen" : "Antworten vorlesen an/aus")
                    Menu {
                        ForEach(ScreenCapture.Mode.allCases) { mode in
                            Button { capture(mode) } label: { Label(mode.label, systemImage: mode.icon) }
                        }
                    } label: {
                        Image(systemName: "camera.viewfinder").font(.system(size: 19))
                    }
                    // .borderlessButton zeichnet das Symbol als AppKit-Menüknopf (kleiner, ignoriert .font);
                    // .button + .plain rendert es wie die übrigen Knöpfe der Leiste.
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(.secondary)
                    .help("Bildschirmfoto anhängen")
                    Button { app.toggleTalkMode() } label: {
                        Image(systemName: app.talkMode ? "waveform.circle.fill" : "waveform.circle").font(.system(size: 22))
                            .symbolEffect(.variableColor.iterative, isActive: app.talkPhase == .speaking)
                    }
                    .buttonStyle(.plain).foregroundStyle(app.talkMode ? AnyShapeStyle(Theme.gold) : AnyShapeStyle(.secondary))
                    .help("Gesprächsmodus: sprechen, Pause → abschicken, Antwort hören, weiter sprechen")
                    Button { pickImages() } label: { Image(systemName: "paperclip").font(.system(size: 19)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Dateien anhängen: Bilder, PDF, Word, Excel, PowerPoint, Text, ZIP … (auch per Drag & Drop)")
                    if session.isRunning {
                        Button { session.stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 30)) }
                            .buttonStyle(.plain).foregroundStyle(.red)
                    } else {
                        Button { app.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)) }
                            .buttonStyle(.plain).foregroundStyle(Theme.brand)
                            .disabled(!app.canSendOrStart
                                      || (session.input.trimmingCharacters(in: .whitespaces).isEmpty && session.attachments.isEmpty && session.documents.isEmpty))
                    }
                }
            }
            .padding(12)
            .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(focused ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.separator), lineWidth: focused ? 1.5 : 1))
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
        }
        .padding(16)
        .background(.bar)
        .onAppear { focused = true }
        .dropDestination(for: URL.self) { urls, _ in attach(urls) }
    }

    private var suggestions: [SlashCommand] {
        let input = app.session.input
        guard input.hasPrefix("/"), !input.contains(" ") else { return [] }
        let q = input.dropFirst().lowercased()
        return Array(app.plugins.commands.filter { q.isEmpty || $0.name.lowercased().hasPrefix(q) }.prefix(8))
    }

    private func capture(_ mode: ScreenCapture.Mode) {
        Task {
            do {
                if let jpeg = try await ScreenCapture.capture(mode) { app.session.attachments.append(jpeg) }
            } catch {
                captureError = error.localizedDescription
            }
        }
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Bilder, PDF, Word, Excel, PowerPoint, Text, ZIP – oder jede andere Datei"
        if panel.runModal() == .OK { attach(panel.urls) }
    }

    /// Bilder gehen als Bild an das (Vision-)Modell, alles andere als Datei mit ausgelesenem Inhalt.
    @discardableResult private func attach(_ urls: [URL]) -> Bool {
        for url in urls {
            if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
               let jpeg = ImageAttachment.jpeg(from: url) {
                app.session.attachments.append(jpeg)
            } else if !app.session.documents.contains(url) {
                app.session.documents.append(url)
            }
        }
        return !urls.isEmpty
    }

    /// Denken, Ordner, YOLO – bei wenig Platz nur als Symbole.
    @ViewBuilder private func toggles(compact: Bool) -> some View {
        @Bindable var session = app.session
        HStack(spacing: 8) {
            Toggle(isOn: $session.thinking) { label("Denken", "brain", compact) }
                .toggleStyle(.button)
                .help("Denken: das Modell überlegt erst und antwortet dann (langsamer, gründlicher)")
            if session.mode.hasWorkspace {
                Button { pickWorkspace() } label: {
                    label(session.workspace.lastPathComponent.isEmpty ? "/" : session.workspace.lastPathComponent,
                          session.mode == .code ? "folder.badge.gearshape" : "folder", compact)
                }
                .help("\(session.project == nil ? "Arbeitsordner" : "Projektordner"): \(session.workspace.path)")
                Toggle(isOn: $session.autoApprove) { label("YOLO", session.autoApprove ? "flame.fill" : "flame", compact) }
                    .toggleStyle(.button)
                    .tint(session.autoApprove ? .orange : nil)
                    .help(session.autoApprove
                          ? "YOLO an: Werkzeuge laufen ohne Nachfrage\(session.dangerGuard ? " (außer zerstörerische Befehle)" : " – auch zerstörerische!")"
                          : "YOLO-Modus: Agent fragt nicht mehr vor Schreiben, Shell, Browser-Aktionen und MCP-Aufrufen")
            }
        }
        .fixedSize()
    }

    private func label(_ title: String, _ icon: String, _ compact: Bool) -> some View {
        Label(title, systemImage: icon).labelStyle(CompactLabelStyle(compact: compact))
    }

    private func pickWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = app.session.workspace
        panel.prompt = "Als Arbeitsordner wählen"
        if panel.runModal() == .OK, let url = panel.url { app.session.workspace = url }
    }
}

/// Lebenszeichen, solange noch kein Text da ist: animierte Punkte, was gerade passiert und seit wann.
private struct TypingDots: View {
    @Environment(AppState.self) private var app
    var thinking = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let elapsed = app.session.stepStarted.map { context.date.timeIntervalSince($0) } ?? 0
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    ForEach(0..<3) { i in
                        let wave = (sin(t * 5 - Double(i) * 0.9) + 1) / 2
                        Circle().fill(Theme.brand).frame(width: 7, height: 7)
                            .opacity(0.3 + 0.7 * wave)
                            .offset(y: -3 * wave)
                    }
                }
                Text(status(elapsed)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.vertical, 6)
        }
    }

    private func status(_ s: Double) -> String {
        let secs = s < 1 ? "" : " · \(Int(s)) s"
        if thinking { return "denkt nach\(secs)" }
        if s < 2 { return "" }
        // Vor dem ersten Token verarbeitet das Modell die Eingabe (Prompt, Werkzeuge, Verlauf).
        return s < 25 ? "liest Eingabe\(secs)" : "liest Eingabe\(secs) – beim ersten Mal lädt das Modell"
    }
}

/// Markdown-Text mit abgesetzten Code-Blöcken.
struct RichText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                if seg.isCode {
                    CodeBlock(code: seg.text, language: seg.language)
                } else {
                    MarkdownBlocks(text: seg.text)
                }
            }
        }
    }

    private struct Segment { var text: String; var isCode: Bool; var language: String }

    private var segments: [Segment] {
        var out: [Segment] = []
        var current = "", inCode = false, lang = ""
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if !current.isEmpty || inCode { out.append(Segment(text: current.trimmingCharacters(in: .newlines), isCode: inCode, language: lang)) }
                current = ""
                inCode.toggle()
                lang = inCode ? line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "```", with: "") : ""
            } else {
                current += (current.isEmpty ? "" : "\n") + line
            }
        }
        if !current.isEmpty { out.append(Segment(text: current, isCode: inCode, language: lang)) }
        return out.filter { !$0.text.isEmpty || $0.isCode }
    }

}

/// Markdown-Blöcke außerhalb von Code: Überschriften, Tabellen, Listen, Zitate, Trennlinien, Absätze.
private struct MarkdownBlocks: View {
    let text: String

    enum Block {
        case heading(Int, String)
        case table([[String]])
        case bullet(String, marker: String, indent: Int)
        case quote(String)
        case rule
        case paragraph(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(level, t):
                    Text(Self.inline(t))
                        .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                        .padding(.top, level <= 2 ? 6 : 2)
                case let .table(rows):
                    MarkdownTable(rows: rows)
                case let .bullet(t, marker, indent):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
                        Text(Self.inline(t)).lineSpacing(3)
                    }
                    .padding(.leading, CGFloat(indent) * 16)
                case let .quote(t):
                    Text(Self.inline(t)).foregroundStyle(.secondary).padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.primary.opacity(0.6)).frame(width: 3) }
                case .rule:
                    Divider().padding(.vertical, 4)
                case let .paragraph(t):
                    Text(Self.inline(t)).lineSpacing(3)
                }
            }
        }
        .textSelection(.enabled)
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        var table: [[String]] = []
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !table.isEmpty { out.append(.table(table)); table = [] }
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("|") {
                if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
                var cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.first == "" { cells.removeFirst() }
                if cells.last == "" { cells.removeLast() }
                // Trennzeile |---|:--:| überspringen
                if !cells.isEmpty && cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) { continue }
                table.append(cells)
                continue
            }
            if !table.isEmpty { out.append(.table(table)); table = [] }
            if line.isEmpty { flush(); continue }
            if let m = line.firstMatch(of: /^(#{1,6})\s+(.+)$/) {
                flush(); out.append(.heading(m.1.count, String(m.2)))
            } else if line == "---" || line == "***" || line == "___" {
                flush(); out.append(.rule)
            } else if let m = line.firstMatch(of: /^[-*+]\s+(.+)$/) {
                flush(); out.append(.bullet(String(m.1), marker: "•", indent: Self.indent(raw)))
            } else if let m = line.firstMatch(of: /^(\d+)[.)]\s+(.+)$/) {
                flush(); out.append(.bullet(String(m.2), marker: "\(m.1).", indent: Self.indent(raw)))
            } else if let m = line.firstMatch(of: /^>\s?(.*)$/) {
                flush(); out.append(.quote(String(m.1)))
            } else {
                paragraph.append(raw)
            }
        }
        flush()
        return out
    }

    private static func indent(_ raw: String) -> Int {
        min(raw.prefix { $0 == " " || $0 == "\t" }.count / 2, 3)
    }
}

private struct MarkdownTable: View {
    let rows: [[String]]

    private var columns: Int { rows.map(\.count).max() ?? 0 }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            table
            ScrollView(.horizontal, showsIndicators: false) { table }
        }
    }

    private var table: some View {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { c in cell(row, r, c) }
                    }
                    .background(rowBackground(r))
                    if r < rows.count - 1 { Divider().gridCellColumns(columns) }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func cell(_ row: [String], _ r: Int, _ c: Int) -> some View {
        Text(MarkdownBlocks.inline(c < row.count ? row[c] : ""))
            .font(r == 0 ? Font.callout.weight(.semibold) : Font.callout)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)   // umbrechen statt abschneiden
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(minWidth: 80, maxWidth: 320, maxHeight: .infinity, alignment: .topLeading)
    }

    private func rowBackground(_ r: Int) -> AnyShapeStyle {
        if r == 0 { return AnyShapeStyle(.quaternary.opacity(0.6)) }
        return r % 2 == 0 ? AnyShapeStyle(.quaternary.opacity(0.25)) : AnyShapeStyle(Color.clear)
    }
}

struct CodeBlock: View {
    let code: String
    var language: String = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "Code" : language).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if ["html", "svg", "md", "markdown"].contains(language.lowercased()) {
                    Button { AppState.shared.session.preview.showSnippet(code, language: language) } label: {
                        Label("Vorschau", systemImage: "play.rectangle")
                    }
                    .buttonStyle(.borderless).font(.caption2)
                }
                Button {
                    AppState.copy(code)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: { Label(copied ? "Kopiert" : "Kopieren", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(.borderless).font(.caption2)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.quaternary.opacity(0.5))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(.callout, design: .monospaced)).textSelection(.enabled).padding(12)
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.6)))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}




enum ImageAttachment {
    /// Bild laden, auf höchstens 1536 px verkleinern und als JPEG kodieren (spart Tokens).
    static func jpeg(from url: URL, maxSide: CGFloat = 1536) -> Data? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        return jpeg(image, maxSide: maxSide)
    }

    static func jpeg(_ image: NSImage, maxSide: CGFloat = 1536) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxSide / max(w, h))
        let size = NSSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSImage(cgImage: cg, size: size).draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}


/// Leiste des Gesprächsmodus: Zustand, Pegel, Live-Text, Unterbrechen und Beenden.
struct TalkBar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(color.opacity(0.18)).frame(width: 38, height: 38)
                    .scaleEffect(app.talkPhase == .listening ? 1 + CGFloat(app.voice.level) * 0.6 : 1)
                    .animation(.easeOut(duration: 0.12), value: app.voice.level)
                Image(systemName: icon).foregroundStyle(color)
                    .symbolEffect(.pulse, isActive: app.talkPhase == .thinking)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if app.talkPhase == .speaking {
                Button("Unterbrechen") { app.voice.stopSpeaking() }
            }
            Button(role: .cancel) { app.toggleTalkMode() } label: { Label("Beenden", systemImage: "xmark.circle.fill") }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.gold.opacity(0.7), lineWidth: 1.5))
    }

    private var icon: String {
        switch app.talkPhase {
        case .listening: return "mic.fill"
        case .thinking: return "brain"
        case .speaking: return "speaker.wave.2.fill"
        case .off: return "mic.slash"
        }
    }
    private var color: Color { app.talkPhase == .listening ? .red : app.talkPhase == .speaking ? Theme.primary : Theme.gold }
    private var title: String {
        switch app.talkPhase {
        case .listening: return "Ich höre zu …"
        case .thinking: return "Ich denke nach …"
        case .speaking: return "Ich spreche – „Unterbrechen“, um direkt weiterzureden"
        case .off: return ""
        }
    }
    private var subtitle: String {
        switch app.talkPhase {
        case .listening: return app.voice.liveText.isEmpty ? "Sprich einfach – nach einer kurzen Pause schicke ich ab. „Schau auf meinen Bildschirm“ hängt ein Bildschirmfoto an." : app.voice.liveText
        case .thinking: return app.selectedModelName
        case .speaking: return "Danach höre ich automatisch wieder zu."
        case .off: return ""
        }
    }
}

private struct CompactLabelStyle: LabelStyle {
    let compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        if compact { Label(configuration).labelStyle(.iconOnly) } else { Label(configuration).labelStyle(.titleAndIcon) }
    }
}

/// Ordnet Elemente nebeneinander an und bricht in die nächste Zeile um, wenn der Platz nicht reicht.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}
