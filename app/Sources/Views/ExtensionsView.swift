import SwiftUI

struct ExtensionsView: View {
    @Environment(AppState.self) private var app
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Installiert (\(app.plugins.plugins.count))").tag(0)
                Text("Katalog (\(app.plugins.catalog.count))").tag(1)
                Text("Skills (\(app.plugins.skills.count))").tag(2)
                Text("Befehle & Agenten").tag(3)
            }
            .pickerStyle(.segmented).frame(maxWidth: 620).padding(14)
            Divider()
            switch tab {
            case 0: InstalledPlugins(showCatalog: { tab = 1 })
            case 1: PluginCatalog()
            case 2: SkillsList()
            default: CommandsAndAgents()
            }
        }
    }
}

// MARK: Installierte Plugins

private struct InstalledPlugins: View {
    @Environment(AppState.self) private var app
    let showCatalog: () -> Void
    @State private var gitURL = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if app.plugins.plugins.isEmpty {
                    Card {
                        Label("Noch keine Plugins", systemImage: "puzzlepiece.extension").font(.headline)
                        Text("Plugins bündeln Skills, Slash-Befehle, Sub-Agenten und MCP-Server – im selben Format wie Claude Code.")
                            .foregroundStyle(.secondary)
                        Button("Katalog öffnen", action: showCatalog).buttonStyle(.borderedProminent)
                    }
                }
                ForEach(app.plugins.plugins) { PluginCard(plugin: $0) }
                Card {
                    Text("Plugin aus Git installieren").font(.headline)
                    HStack {
                        TextField("https://github.com/…/plugin.git", text: $gitURL).textFieldStyle(.roundedBorder)
                        Button("Installieren") {
                            let url = gitURL
                            Task { await app.plugins.install(gitURL: url); await app.pluginsChanged() }
                            gitURL = ""
                        }
                        .disabled(!gitURL.hasPrefix("http"))
                    }
                    ForEach(app.plugins.errors.sorted(by: { $0.key < $1.key }), id: \.key) { _, e in
                        Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                    }
                    Text("Ordner: \(PluginManager.pluginsDir.path)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
    }
}

private struct PluginCard: View {
    @Environment(AppState.self) private var app
    let plugin: Plugin

    var body: some View {
        Card {
            HStack(alignment: .top) {
                Image(systemName: "puzzlepiece.extension.fill").font(.title2).foregroundStyle(Theme.brand)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(plugin.name).font(.headline)
                        if !plugin.version.isEmpty { Text(plugin.version).font(.caption).foregroundStyle(.secondary) }
                    }
                    Text(plugin.description).foregroundStyle(.secondary).lineLimit(3)
                    HStack(spacing: 6) {
                        if !plugin.skills.isEmpty { Chip(text: "\(plugin.skills.count) Skills", systemImage: "graduationcap") }
                        if !plugin.commands.isEmpty { Chip(text: "\(plugin.commands.count) Befehle", systemImage: "slash.circle") }
                        if !plugin.agents.isEmpty { Chip(text: "\(plugin.agents.count) Agenten", systemImage: "person.2") }
                        if !plugin.mcpServers.isEmpty { Chip(text: "\(plugin.mcpServers.count) MCP", systemImage: "point.3.connected.trianglepath.dotted") }
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(get: { plugin.enabled }, set: { on in
                    app.plugins.setEnabled(plugin.name, on)
                    Task { await app.pluginsChanged() }
                }))
                .toggleStyle(.switch)
                Button(role: .destructive) {
                    app.plugins.uninstall(plugin)
                    Task { await app.pluginsChanged() }
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
        }
    }
}

// MARK: Katalog

private struct PluginCatalog: View {
    @Environment(AppState.self) private var app
    @State private var query = ""
    @State private var category = "Alle"
    @State private var marketplaceURL = ""

    private var categories: [String] {
        ["Alle"] + Set(app.plugins.catalog.map(\.category).filter { !$0.isEmpty }).sorted()
    }

    private var filtered: [CatalogEntry] {
        app.plugins.catalog.filter { e in
            (category == "Alle" || e.category == category) &&
            (query.isEmpty || e.name.localizedCaseInsensitiveContains(query) || e.description.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Plugins durchsuchen …", text: $query).textFieldStyle(.plain)
                Picker("", selection: $category) { ForEach(categories, id: \.self) { Text($0).tag($0) } }
                    .frame(width: 200)
            }
            .padding(12)
            .background(.background.secondary)
            if app.plugins.catalog.isEmpty {
                Card {
                    Label("Kein Katalog geladen", systemImage: "books.vertical").font(.headline)
                    Text("Lade den offiziellen Plugin-Katalog von Anthropic (über 300 Plugins) oder füge einen eigenen Marketplace hinzu.")
                        .foregroundStyle(.secondary)
                    Button("Offiziellen Katalog laden") {
                        Task { await app.plugins.addMarketplace(PluginManager.officialMarketplace) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(24)
                Spacer()
            } else {
                List(filtered) { CatalogRow(entry: $0) }
                    .listStyle(.inset)
            }
            HStack {
                Text("Marketplaces: \(app.plugins.marketplaces.map(\.name).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                TextField("Marketplace-Git-URL", text: $marketplaceURL).textFieldStyle(.roundedBorder).frame(width: 300)
                Button("Hinzufügen") {
                    let u = marketplaceURL
                    Task { await app.plugins.addMarketplace(u) }
                    marketplaceURL = ""
                }
                .disabled(!marketplaceURL.hasPrefix("http"))
                if app.plugins.busy.keys.contains(where: { $0.hasPrefix("marketplace:") }) { ProgressView().controlSize(.small) }
            }
            .padding(12)
        }
    }
}

private struct CatalogRow: View {
    @Environment(AppState.self) private var app
    let entry: CatalogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "puzzlepiece.extension").foregroundStyle(Theme.violet).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name).font(.callout.weight(.semibold))
                    if !entry.author.isEmpty { Text("· \(entry.author)").font(.caption).foregroundStyle(.secondary) }
                    if !entry.category.isEmpty { Chip(text: entry.category) }
                }
                Text(entry.description).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                if let e = app.plugins.errors[entry.id] { Text(e).font(.caption).foregroundStyle(.red) }
            }
            Spacer()
            if let b = app.plugins.busy[entry.id] {
                ProgressView().controlSize(.small)
                Text(b).font(.caption).foregroundStyle(.secondary)
            } else if app.plugins.isInstalled(entry) {
                Label("Installiert", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
            } else {
                Button("Installieren") { Task { await app.plugins.install(entry); await app.pluginsChanged() } }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: Skills

private struct SkillsList: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var plugins = app.plugins
        List {
            Section {
                Toggle("Skills und Befehle aus Claude Code (~/.claude) einbeziehen", isOn: $plugins.includeClaudeCode)
            }
            ForEach(Dictionary(grouping: app.plugins.skills, by: \.source).sorted(by: { $0.key < $1.key }), id: \.key) { source, skills in
                Section(source) {
                    ForEach(skills) { s in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name).font(.callout.monospaced().weight(.semibold))
                                Text(s.description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                            Spacer()
                            Button { NSWorkspace.shared.open(s.file) } label: { Image(systemName: "doc.text") }
                                .buttonStyle(.borderless).help("SKILL.md öffnen")
                        }
                    }
                }
            }
            Section {
                Text("Eigene Skills: \(PluginManager.skillsDir.path)/<name>/SKILL.md – oder sag dem Agenten „mach daraus einen Skill“.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Skills-Ordner öffnen") { NSWorkspace.shared.open(PluginManager.skillsDir) }
            }
        }
        .listStyle(.inset)
    }
}

private struct CommandsAndAgents: View {
    @Environment(AppState.self) private var app

    var body: some View {
        List {
            Section("Slash-Befehle (im Chat mit / aufrufen)") {
                if app.plugins.commands.isEmpty { Text("Keine – kommen mit Plugins oder aus ~/.claude/commands").foregroundStyle(.secondary) }
                ForEach(app.plugins.commands) { c in
                    HStack {
                        Text("/\(c.name)").font(.callout.monospaced().weight(.semibold))
                        if !c.argumentHint.isEmpty { Text(c.argumentHint).font(.caption).foregroundStyle(.tertiary) }
                        Text(c.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text(c.source).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            Section("Sub-Agenten (der Agent ruft sie mit run_agent auf)") {
                if app.plugins.agents.isEmpty { Text("Keine – kommen mit Plugins, z. B. feature-dev").foregroundStyle(.secondary) }
                ForEach(app.plugins.agents) { a in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(a.name).font(.callout.monospaced().weight(.semibold))
                            Spacer()
                            Text(a.source).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Text(a.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}
