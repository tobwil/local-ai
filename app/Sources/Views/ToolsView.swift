import SwiftUI

struct ToolsView: View {
    @Environment(AppState.self) private var app
    @State private var showAdd = false
    @State private var importNote: String?

    var body: some View {
        @Bindable var state = app
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Card {
                    HStack {
                        Label("Eingebaute Werkzeuge", systemImage: "hammer").font(.headline)
                        Spacer()
                        Toggle("", isOn: $state.useBuiltinTools).toggleStyle(.switch)
                    }
                    ForEach(BuiltinTools.all { app.session.workspace }) { tool in
                        ToolLine(tool: tool)
                    }
                }

                Card {
                    HStack {
                        Label("MCP-Server", systemImage: "point.3.filled.connected.trianglepath.dotted").font(.headline)
                        Spacer()
                        Button("Aus Claude Desktop übernehmen") {
                            let n = app.mcp.importClaudeDesktop()
                            importNote = n == 0 ? "Keine neuen Server gefunden." : "\(n) Server übernommen."
                            Task { await app.mcp.connectAll() }
                        }
                        Button { showAdd = true } label: { Label("Hinzufügen", systemImage: "plus") }
                            .buttonStyle(.borderedProminent)
                    }
                    if let importNote { Text(importNote).font(.caption).foregroundStyle(.secondary) }
                    if app.mcp.servers.isEmpty {
                        Text("Noch keine MCP-Server. Starte mit einer Vorlage:").foregroundStyle(.secondary)
                    }
                    ForEach(app.mcp.servers) { MCPServerRow(server: $0) }
                    Divider()
                    Text("Vorlagen").font(.subheadline.weight(.semibold))
                    HStack {
                        ForEach(MCPPreset.all(workspace: app.session.workspace), id: \.config.name) { preset in
                            Button {
                                app.mcp.add(preset.config)
                                Task { await app.mcp.connect(preset.config) }
                            } label: { Label(preset.title, systemImage: preset.icon) }
                                .disabled(app.mcp.servers.contains { $0.name == preset.config.name })
                        }
                    }
                    Text("Konfiguration: \(MCPManager.configURL.path) – gleiches Format wie Claude Desktop. MCP-Werkzeuge fragen vor jeder Ausführung nach.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $showAdd) { AddMCPServerSheet() }
    }
}

private struct ToolLine: View {
    let tool: AgentTool
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(tool.name).font(.callout.monospaced().weight(.medium)).frame(width: 220, alignment: .leading)
            Text(tool.description).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            if tool.needsApproval { Chip(text: "mit Freigabe", systemImage: "hand.raised", tint: .orange) }
        }
    }
}

private struct MCPServerRow: View {
    @Environment(AppState.self) private var app
    let server: MCPServerConfig
    @State private var expanded = false

    var body: some View {
        let status = app.mcp.status[server.name] ?? .off
        let tools = app.mcp.tools.filter { $0.source == server.name }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(color(status)).frame(width: 8, height: 8)
                Text(server.name).font(.callout.weight(.semibold))
                Text(([server.command] + server.args).joined(separator: " "))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(label(status)).font(.caption).foregroundStyle(.secondary)
                if !tools.isEmpty {
                    Button { withAnimation { expanded.toggle() } } label: { Image(systemName: expanded ? "chevron.down" : "chevron.right") }
                        .buttonStyle(.borderless)
                }
                Button { Task { await app.mcp.connect(server) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Neu verbinden")
                Toggle("", isOn: Binding(get: { server.enabled }, set: { app.mcp.setEnabled(server.name, $0) }))
                    .toggleStyle(.switch).controlSize(.small)
                Button(role: .destructive) { app.mcp.remove(server.name) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            if expanded { ForEach(tools) { ToolLine(tool: $0) }.padding(.leading, 18) }
        }
        .padding(.vertical, 4)
    }

    private func color(_ s: MCPManager.Status) -> Color {
        switch s {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .off: return .secondary
        }
    }

    private func label(_ s: MCPManager.Status) -> String {
        switch s {
        case let .connected(n): return "\(n) Werkzeuge"
        case .connecting: return "verbindet …"
        case let .failed(m): return m
        case .off: return "aus"
        }
    }
}

struct MCPPreset {
    let title: String
    let icon: String
    let config: MCPServerConfig

    static func all(workspace: URL) -> [MCPPreset] {
        [
            MCPPreset(title: "Dateisystem", icon: "folder",
                      config: MCPServerConfig(name: "filesystem", command: "npx",
                                              args: ["-y", "@modelcontextprotocol/server-filesystem", workspace.path])),
            MCPPreset(title: "Gedächtnis", icon: "brain.head.profile",
                      config: MCPServerConfig(name: "memory", command: "npx", args: ["-y", "@modelcontextprotocol/server-memory"])),
            MCPPreset(title: "Schrittweises Denken", icon: "list.number",
                      config: MCPServerConfig(name: "sequential-thinking", command: "npx",
                                              args: ["-y", "@modelcontextprotocol/server-sequential-thinking"])),
        ]
    }
}

private struct AddMCPServerSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var command = ""
    @State private var args = ""
    @State private var env = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MCP-Server hinzufügen").font(.title2.bold())
            Form {
                TextField("Name", text: $name, prompt: Text("z. B. github"))
                TextField("Befehl", text: $command, prompt: Text("npx, uvx, node, /pfad/zum/server"))
                TextField("Argumente", text: $args, prompt: Text("-y @modelcontextprotocol/server-github"))
                TextField("Umgebung", text: $env, prompt: Text("KEY=wert, eine pro Zeile"), axis: .vertical).lineLimit(2...5)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                Button("Hinzufügen") {
                    let config = MCPServerConfig(
                        name: name.trimmingCharacters(in: .whitespaces), command: command.trimmingCharacters(in: .whitespaces),
                        args: args.split(separator: " ").map(String.init),
                        env: Dictionary(env.split(separator: "\n").compactMap { line -> (String, String)? in
                            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                            return parts.count == 2 ? (parts[0], parts[1]) : nil
                        }, uniquingKeysWith: { $1 }))
                    app.mcp.add(config)
                    Task { await app.mcp.connect(config) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || command.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}
