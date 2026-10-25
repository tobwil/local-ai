import AppKit
import SwiftUI

struct ConnectView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let model = app.selectedModelID
        let exe = app.appExecutablePath
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ConnectCard(icon: "terminal", title: "Claude Code mit lokalem Modell",
                            text: "Claude Code spricht direkt mit oMLX über die Anthropic-API. Läuft komplett offline.",
                            snippet: "ANTHROPIC_BASE_URL=\(Paths.server.absoluteString) ANTHROPIC_AUTH_TOKEN=ki-lokal \\\n  claude --model \(model)")

                ConnectCard(icon: "point.3.connected.trianglepath.dotted", title: "Lokales Modell als MCP-Werkzeug",
                            text: "Claude Code (oder ein anderer MCP-Client) bekommt das Werkzeug local_chat und kann Teilaufgaben an deinen Mac abgeben – Zusammenfassungen, Entwürfe, private Daten.",
                            snippet: "claude mcp add ki-lokal -- \"\(exe)\" --mcp-server")

                ConnectCard(icon: "macwindow", title: "Claude Desktop / andere MCP-Clients",
                            text: "In claude_desktop_config.json unter mcpServers eintragen:",
                            snippet: """
                            "ki-lokal": {
                              "command": "\(exe)",
                              "args": ["--mcp-server"]
                            }
                            """)

                ConnectCard(icon: "curlybraces", title: "OpenAI-kompatibel (OpenCode, Continue, Open WebUI, Skripte)",
                            text: "Basis-URL und Modell-ID – ein API-Schlüssel ist nicht nötig, viele Clients wollen trotzdem einen beliebigen Wert.",
                            snippet: "Basis-URL: \(Paths.openAIBase.absoluteString)\nModell:    \(model)\nAPI-Key:   ki-lokal")

                if !app.server.state.isUp {
                    Label("Der Server muss laufen, damit diese Verbindungen funktionieren.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
    }
}

private struct ConnectCard: View {
    let icon, title, text, snippet: String

    var body: some View {
        Card {
            Label(title, systemImage: icon).font(.headline)
            Text(text).foregroundStyle(.secondary)
            CodeBlock(code: snippet, language: "")
        }
    }
}

struct LogView: View {
    @Environment(AppState.self) private var app
    @State private var source = 0
    @State private var actions: [ActionLog.Entry] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $source) {
                    Text("Aktionen").tag(2)
                    Text("oMLX").tag(0)
                    Text("MCP").tag(1)
                }
                .pickerStyle(.segmented).frame(width: 300)
                Spacer()
                if source == 2 {
                    Button("Aktualisieren") { actions = ActionLog.recent() }
                    Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([ActionLog.file]) }
                }
            }
            .padding(12)
            if source == 2 {
                if actions.isEmpty {
                    ContentUnavailableView("Noch keine Aktionen", systemImage: "list.bullet.clipboard",
                                           description: Text("Hier steht jeder Werkzeug-Aufruf des Agenten – mit Freigabe, YOLO oder aus Automationen."))
                }
                List(actions) { e in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: e.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(e.ok ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(e.tool).font(.callout.monospaced().weight(.semibold))
                                Chip(text: e.approval, tint: e.approval.contains("YOLO") || e.approval.contains("unbeaufsichtigt") ? .orange : .secondary)
                                Text(e.context).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(e.time.formatted(date: .abbreviated, time: .standard)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Text(e.arguments.replacingOccurrences(of: "\n", with: " ")).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                            if !e.result.isEmpty {
                                Text(e.result.replacingOccurrences(of: "\n", with: " ")).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
                .onAppear { actions = ActionLog.recent() }
            } else {
                let lines = source == 0 ? app.server.log : app.mcp.log
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                                Text(line).font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(line.contains("ERROR") ? .red : line.contains("WARNING") ? .orange : .primary)
                                    .textSelection(.enabled).id(i)
                            }
                        }
                        .padding(.horizontal, 16).padding(.bottom, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: lines.count) { proxy.scrollTo(lines.count - 1) }
                }
            }
        }
        .onAppear { if source == 0 && app.server.log.isEmpty { source = 2 } }
    }
}
