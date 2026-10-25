import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AgentView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if app.session.items.isEmpty { EmptyAgent() }
                        ForEach(app.session.items) { item in
                            ItemView(item: item).id(item.id)
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
        .toolbar {
            ToolbarItem {
                HistoryMenu()
            }
            ToolbarItem {
                Button { app.session.reset() } label: { Label("Neues Gespräch", systemImage: "square.and.pencil") }
            }
        }
    }

    private var lastText: Int {
        guard case let .assistant(text, thinking, _)? = app.session.items.last?.kind else { return 0 }
        return text.count + thinking.count
    }
}

private struct EmptyAgent: View {
    @Environment(AppState.self) private var app
    private let ideas = [
        ("folder", "Was liegt in meinem Arbeitsordner? Fasse die wichtigsten Dateien zusammen."),
        ("chevron.left.forwardslash.chevron.right", "Schreibe ein Python-Skript, das alle Fotos in einem Ordner nach Datum sortiert, und speichere es als sort_photos.py."),
        ("globe", "Recherchiere die wichtigsten KI-Neuigkeiten dieser Woche und fasse sie mit Quellen zusammen."),
        ("terminal", "Wie viel Speicherplatz ist auf meinem Mac frei? Prüfe es mit einem Shell-Befehl."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                VStack(alignment: .leading) {
                    HStack(spacing: 8) { Wordmark(suffix: "agent", size: 28) }
                    Text("\(app.agentTools.count) Werkzeuge · \(app.plugins.skills.count) Skills · \(app.plugins.commands.count) Befehle – das Modell läuft auf diesem Mac").foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(ideas, id: \.1) { icon, text in
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
        }
        .padding(.top, 30)
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
                if text.isEmpty && thinking.isEmpty {
                    TypingDots()
                } else if !text.isEmpty {
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
                Button { withAnimation { expanded.toggle() } } label: {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(expanded || state == .awaitingApproval ? 90 : 0))
                }
                .buttonStyle(.borderless)
            }
            if expanded || state == .awaitingApproval {
                CodeBlock(code: arguments, language: "Argumente")
            }
            if state == .awaitingApproval {
                HStack {
                    Text("Darf der Agent das ausführen?").font(.callout.weight(.medium))
                    Spacer()
                    Button("Ablehnen") { app.session.approve(id, false) }
                    Button("Erlauben") { app.session.approve(id, true) }.buttonStyle(.borderedProminent).keyboardShortcut(.return)
                }
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

    var body: some View {
        @Bindable var session = app.session
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Toggle(isOn: $session.agentMode) { Label("Agent", systemImage: "wrench.and.screwdriver") }
                    .toggleStyle(.button)
                Toggle(isOn: $session.thinking) { Label("Denken", systemImage: "brain") }
                    .toggleStyle(.button)
                Button { pickWorkspace() } label: {
                    Label(session.workspace.lastPathComponent.isEmpty ? "/" : session.workspace.lastPathComponent, systemImage: "folder")
                }
                .help("Arbeitsordner: \(session.workspace.path)")
                if session.agentMode {
                    Toggle(isOn: $session.autoApprove) { Label("YOLO", systemImage: session.autoApprove ? "flame.fill" : "flame") }
                        .toggleStyle(.button)
                        .tint(session.autoApprove ? .orange : nil)
                        .help(session.autoApprove
                              ? "YOLO an: Werkzeuge laufen ohne Nachfrage\(session.dangerGuard ? " (außer zerstörerische Befehle)" : " – auch zerstörerische!")"
                              : "YOLO-Modus: Agent fragt nicht mehr vor Schreiben, Shell, Browser-Aktionen und MCP-Aufrufen")
                }
                Spacer()
                if session.isRunning && session.liveTokPerSec > 0 {
                    Label("\(session.liveTokPerSec.oneDecimal) tok/s", systemImage: "bolt.fill")
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.primary)
                        .contentTransition(.numericText())
                }
                if app.selectedIsCloud {
                    Chip(text: "Cloud – Daten verlassen den Mac", systemImage: "cloud", tint: .orange)
                }
                Text(app.selectedModelName).font(.caption).foregroundStyle(.secondary)
            }
            .controlSize(.small)

            if let e = app.voice.error {
                Label(e, systemImage: "mic.slash").font(.caption).foregroundStyle(.orange)
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

            HStack(alignment: .bottom, spacing: 10) {
                TextField(app.canSend ? "Frag etwas oder gib dem Agenten eine Aufgabe …" : "Server starten, um loszulegen",
                          text: $session.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit { app.send() }
                    .padding(12)
                    .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(focused ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.separator), lineWidth: focused ? 1.5 : 1))
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
                Button { pickImages() } label: { Image(systemName: "photo.badge.plus").font(.system(size: 20)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Bild anhängen (auch per Drag & Drop)")
                if session.isRunning {
                    Button { session.stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 30)) }
                        .buttonStyle(.plain).foregroundStyle(.red)
                } else {
                    Button { app.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.brand)
                        .disabled(!app.canSend
                                  || (session.input.trimmingCharacters(in: .whitespaces).isEmpty && session.attachments.isEmpty))
                }
            }
        }
        .padding(16)
        .background(.bar)
        .onAppear { focused = true }
        .dropDestination(for: URL.self) { urls, _ in
            let images = urls.compactMap { ImageAttachment.jpeg(from: $0) }
            app.session.attachments += images
            return !images.isEmpty
        }
    }

    private var suggestions: [SlashCommand] {
        let input = app.session.input
        guard input.hasPrefix("/"), !input.contains(" ") else { return [] }
        let q = input.dropFirst().lowercased()
        return Array(app.plugins.commands.filter { q.isEmpty || $0.name.lowercased().hasPrefix(q) }.prefix(8))
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            app.session.attachments += panel.urls.compactMap { ImageAttachment.jpeg(from: $0) }
        }
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

private struct TypingDots: View {
    @State private var phase = 0.0
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle().fill(Theme.brand).frame(width: 7, height: 7)
                    .opacity(0.3 + 0.7 * abs(sin(phase + Double(i) * 0.8)))
            }
        }
        .onAppear { withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = .pi } }
        .padding(.vertical, 6)
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
                    Text(markdown(seg.text)).textSelection(.enabled).lineSpacing(3)
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

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
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


private struct HistoryMenu: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let _ = app.session.historyVersion
        Menu {
            let chats = ChatStore.list().prefix(25)
            if chats.isEmpty { Text("Noch keine Gespräche") }
            ForEach(chats) { chat in
                Button {
                    app.session.load(id: chat.id)
                } label: {
                    Text("\(chat.title) – \(chat.date.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            if !chats.isEmpty {
                Divider()
                Button("Aktuelles Gespräch löschen", role: .destructive) {
                    ChatStore.delete(id: app.session.chatID)
                    app.session.reset()
                }
            }
        } label: {
            Label("Verlauf", systemImage: "clock.arrow.circlepath")
        }
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
