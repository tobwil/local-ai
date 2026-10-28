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

                KiroCrewCards(model: model, exe: exe)

                if !app.server.state.isUp {
                    Label("Der Server muss laufen, damit diese Verbindungen funktionieren.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
    }
}

/// KiroCrew (github.com/kirodotdev/KiroCrew) ruft lokale Modelle nicht selbst auf, sondern über die Agenten OpenCode
/// oder Pi, die es startet. Die Formate folgen KiroCrews Anleitung „Using LM Studio … through OpenCode or Pi“ –
/// statt LM Studio zeigt die Basis-URL auf oMLX.
private struct KiroCrewCards: View {
    let model, exe: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("KiroCrew mit KI/lokal").font(.title3.bold())
                Text("KiroCrew ruft Modelle über einen Agenten auf. OpenCode und Pi können auf deine lokale Engine zeigen – dann läuft KiroCrew ohne Cloud. Im Modell-Picker eines neuen KiroCrew-Chats erscheint danach „ki-lokal/\(model)“.")
                    .foregroundStyle(.secondary)
                Label("Diese Agenten schicken lange Systemprompts und viele Werkzeuge mit. Auf einem 24-GB-Mac (32k Kontext) wird es schnell eng – für Code-Aufgaben ist der eingebaute Agent meist schneller.",
                      systemImage: "memorychip")
                    .font(.caption).foregroundStyle(.orange)
            }

            ConnectCard(icon: "1.circle", title: "Über OpenCode",
                        text: "Agent installieren (npm i -g opencode-ai@1), in KiroCrew unter Settings → Agent Harness „OpenCode“ wählen und diesen Anbieter in ~/.config/opencode/opencode.json eintragen. Prüfen mit: opencode models ki-lokal",
                        snippet: """
                        {
                          "$schema": "https://opencode.ai/config.json",
                          "provider": {
                            "ki-lokal": {
                              "npm": "@ai-sdk/openai-compatible",
                              "name": "KI/lokal",
                              "options": { "baseURL": "\(Paths.openAIBase.absoluteString)", "apiKey": "ki-lokal" },
                              "models": {
                                "\(model)": { "name": "\(model) (lokal)", "limit": { "context": 32768, "output": 8192 } }
                              }
                            }
                          },
                          "model": "ki-lokal/\(model)"
                        }
                        """)

            ConnectCard(icon: "2.circle", title: "Über Pi",
                        text: "Agent installieren (npm i -g pi-acp @earendil-works/pi-coding-agent), in KiroCrew „Pi“ wählen und den Anbieter in ~/.pi/agent/models.json eintragen. Den apiKey stehen lassen – Pi zeigt ein Modell nur mit Schlüssel an. Prüfen mit: pi --list-models",
                        snippet: """
                        {
                          "$schema": "https://pi.dev/schemas/models.schema.json",
                          "providers": {
                            "ki-lokal": {
                              "baseUrl": "\(Paths.openAIBase.absoluteString)",
                              "api": "openai-completions",
                              "apiKey": "ki-lokal",
                              "models": [ { "id": "\(model)", "contextWindow": 32768, "maxTokens": 8192 } ]
                            }
                          }
                        }
                        """)

            ConnectCard(icon: "3.circle", title: "KI/lokal als Werkzeug in KiroCrew (MCP)",
                        text: "Umgekehrt: KiroCrew (auch mit Cloud-Agent) bekommt das Werkzeug local_chat und kann private Teilaufgaben an deinen Mac geben. In ~/.kiro/crew/mcp.json eintragen:",
                        snippet: """
                        {
                          "mcpServers": {
                            "ki-lokal": { "command": "\(exe)", "args": ["--mcp-server"] }
                          }
                        }
                        """)
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
    /// Zuerst die Aktionen des Agenten – das Engine-Protokoll ist für die Fehlersuche.
    @State private var source = 2
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
            if source == 0 {
                Text("Gelbe Zeilen (WARNING) sind Hinweise der Engine, keine Fehler. „Prefill above max_bytes“ heißt: Das Modell liest gerade einen langen Text nahe der Speichergrenze und tut das in kleinen Stücken – langsamer, aber sicher. Gleiche Meldungen hintereinander stehen als eine Zeile mit (×Anzahl).")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
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
    }
}
