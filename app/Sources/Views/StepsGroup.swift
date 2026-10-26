import SwiftUI

/// Darstellung des Chats in Abschnitten: Die Arbeitsschritte eines Auftrags (Werkzeuge, Zwischenbemerkungen,
/// Prüfungen) werden zu einem kompakten Block zusammengefasst; die Antwort selbst steht groß darunter.
enum ChatSegment: Identifiable {
    case item(AgentSession.Item)
    case steps([AgentSession.Item])

    var id: UUID {
        switch self {
        case let .item(i): return i.id
        case let .steps(items): return items[0].id
        }
    }

    static func build(_ items: [AgentSession.Item]) -> [ChatSegment] {
        var out: [ChatSegment] = []
        var run: [AgentSession.Item] = []
        func flush() {
            defer { run = [] }
            guard !run.isEmpty else { return }
            let lastTool = run.lastIndex { if case .tool = $0.kind { return true }; return false }
            // Die Antwort: das letzte Modell-Element nach dem letzten Werkzeug-Aufruf
            let finalIndex = run.indices.last { idx in
                idx > (lastTool ?? -1) && { if case .assistant = run[idx].kind { return true }; return false }()
            }
            let before = finalIndex.map { Array(run[..<$0]) } ?? run
            if lastTool != nil {
                var steps: [AgentSession.Item] = [], loose: [AgentSession.Item] = []
                for i in before {
                    switch i.kind {
                    case .tool(_, _, _, .awaitingApproval, _): loose.append(i)
                    case let .error(m) where !m.hasPrefix(AgentSession.qualityPrefix): loose.append(i)
                    default: steps.append(i)
                    }
                }
                if !steps.isEmpty { out.append(.steps(steps)) }
                out += loose.map(ChatSegment.item)
            } else {
                out += before.map(ChatSegment.item)
            }
            if let f = finalIndex { out += run[f...].map(ChatSegment.item) }
        }
        for item in items {
            if case .user = item.kind { flush(); out.append(.item(item)) } else { run.append(item) }
        }
        flush()
        return out
    }
}

struct StepsGroup: View {
    @Environment(AppState.self) private var app
    let items: [AgentSession.Item]
    @State private var expanded = false

    private var tools: [(item: AgentSession.Item, name: String, args: String, state: AgentSession.ToolState, result: String)] {
        items.compactMap { i in
            if case let .tool(name, _, args, state, result) = i.kind { return (i, name, args, state, result) }
            return nil
        }
    }

    var body: some View {
        let tools = self.tools
        let running = tools.contains { $0.state == .running }
        let failed = tools.filter { $0.state == .failed }.count
        let changed = Set(tools.filter { ["write_file", "edit_file", "replace_lines", "create_document", "open_canvas"].contains($0.name) && $0.state == .done }
            .compactMap { ToolExplain.path(of: $0.args) }).count
        let lastCheck = tools.last { $0.result.contains("Automatische Prüfung") }?.result
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    if running { ProgressView().controlSize(.mini).frame(width: 16) } else {
                        Image(systemName: failed > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(failed > 0 ? .orange : .green)
                    }
                    Text(summary(count: tools.count, changed: changed, failed: failed, check: lastCheck, running: running))
                        .font(.callout.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 9)

            if expanded {
                Divider().padding(.horizontal, 12)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in row(item) }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            } else if running, let current = items.last(where: { if case .tool = $0.kind { return true }; return false }) {
                // Live: den aktuellen Schritt zeigen
                row(current).padding(.horizontal, 8).padding(.bottom, 6)
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }

    private func summary(count: Int, changed: Int, failed: Int, check: String?, running: Bool) -> String {
        var parts = [running ? "Arbeitet … Schritt \(count)" : "\(count) Arbeitsschritt\(count == 1 ? "" : "e")"]
        if changed > 0 { parts.append("\(changed) Datei\(changed == 1 ? "" : "en") geändert") }
        if let check { parts.append(check.contains("❌") ? "Prüfung: Fehler" : "Prüfung bestanden") }
        if failed > 0 { parts.append("\(failed) fehlgeschlagen") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func row(_ item: AgentSession.Item) -> some View {
        switch item.kind {
        case let .tool(name, source, args, state, result):
            StepRow(id: item.id, name: name, source: source, arguments: args, state: state, result: result)
        case let .assistant(text, _, _) where !text.isEmpty:
            Text(text.replacingOccurrences(of: "\n", with: " "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                .padding(.leading, 28).padding(.vertical, 3)
        case let .error(message):
            Label(message, systemImage: "checkmark.seal").font(.caption).foregroundStyle(Theme.primary)
                .padding(.leading, 6).padding(.vertical, 3)
        default:
            EmptyView()
        }
    }
}

/// Eine Zeile pro Werkzeug-Aufruf in Klartext; Klick zeigt Argumente und Ergebnis.
private struct StepRow: View {
    @Environment(AppState.self) private var app
    let id: UUID
    let name, source, arguments: String
    let state: AgentSession.ToolState
    let result: String
    @State private var open = false

    var body: some View {
        let label = ToolExplain.short(name: name, arguments: arguments)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                stateIcon.frame(width: 16)
                Image(systemName: label.icon).foregroundStyle(.secondary).frame(width: 16)
                Text(label.text).font(.callout).lineLimit(1).truncationMode(.middle)
                if result.contains("❌ Automatische Prüfung") {
                    Label("Prüfung: Fehler", systemImage: "xmark.seal").font(.caption2).foregroundStyle(.orange)
                } else if result.contains("✅ Automatische Prüfung") {
                    Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(.green).help("Automatische Prüfung bestanden")
                }
                Spacer(minLength: 4)
                if state == .done, let url = PreviewStore.writtenPath(tool: name, arguments: arguments, workspace: app.session.workspace) {
                    Button { app.session.preview.show(url) } label: { Image(systemName: "eye") }
                        .buttonStyle(.borderless).help("In der Vorschau zeigen")
                }
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).rotationEffect(.degrees(open ? 90 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy) { open.toggle() } }
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    CodeBlock(code: arguments, language: "\(name) · \(source)")
                    if !result.isEmpty { CodeBlock(code: String(result.prefix(6000)), language: "Ergebnis") }
                }
                .padding(.leading, 24)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(open ? AnyShapeStyle(.quaternary.opacity(0.4)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var stateIcon: some View {
        switch state {
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.green)
        case .failed: Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.red)
        case .denied: Image(systemName: "nosign").font(.caption).foregroundStyle(.secondary)
        case .awaitingApproval: Image(systemName: "hand.raised.fill").font(.caption).foregroundStyle(.orange)
        }
    }
}
