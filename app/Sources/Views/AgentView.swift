import AppKit
import SwiftUI

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
        ("globe", "Lies https://news.ycombinator.com und nenne mir die drei spannendsten Themen."),
        ("terminal", "Wie viel Speicherplatz ist auf meinem Mac frei? Prüfe es mit einem Shell-Befehl."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(Theme.brand)
                VStack(alignment: .leading) {
                    Text("Dein lokaler Agent").font(.title.bold())
                    Text("\(app.agentTools.count) Werkzeuge bereit · alles bleibt auf diesem Mac").foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(ideas, id: \.1) { icon, text in
                    Button { app.session.input = text } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: icon).foregroundStyle(Theme.violet).frame(width: 18)
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
        case let .user(text):
            HStack {
                Spacer(minLength: 80)
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(Theme.brand, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                    Toggle("Ohne Nachfrage", isOn: $session.autoApprove).toggleStyle(.checkbox).font(.caption)
                        .help("Schreiben, Shell und MCP-Aufrufe ohne Freigabe ausführen")
                }
                Spacer()
                if session.isRunning && session.liveTokPerSec > 0 {
                    Label("\(session.liveTokPerSec.oneDecimal) tok/s", systemImage: "bolt.fill")
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.violet)
                        .contentTransition(.numericText())
                }
                Text(app.selectedModel?.name ?? app.selectedModelID).font(.caption).foregroundStyle(.secondary)
            }
            .controlSize(.small)

            HStack(alignment: .bottom, spacing: 10) {
                TextField(app.server.state.isUp ? "Frag etwas oder gib dem Agenten eine Aufgabe …" : "Server starten, um loszulegen",
                          text: $session.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit { app.send() }
                    .padding(12)
                    .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(focused ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.separator), lineWidth: focused ? 1.5 : 1))
                if session.isRunning {
                    Button { session.stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 30)) }
                        .buttonStyle(.plain).foregroundStyle(.red)
                } else {
                    Button { app.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.brand)
                        .disabled(!app.server.state.isUp || session.input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(16)
        .background(.bar)
        .onAppear { focused = true }
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
