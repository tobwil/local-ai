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

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $source) {
                Text("oMLX").tag(0)
                Text("MCP").tag(1)
            }
            .pickerStyle(.segmented).frame(width: 220).padding(12)
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
}
