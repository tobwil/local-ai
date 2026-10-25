import SwiftUI

enum Screen: String, CaseIterable, Identifiable {
    case overview, agent, assistants, knowledge, automations, models, compare, extensions, tools, connect, settings, log
    var id: String { rawValue }

    /// Deep Link `kilokal://<bereich>` – englischer Name oder deutscher Titel (z. B. kilokal://modelle, kilokal://agent?modus=code).
    init?(link: String) {
        let key = link.lowercased()
            .replacingOccurrences(of: "ü", with: "ue").replacingOccurrences(of: "ä", with: "ae").replacingOccurrences(of: "ö", with: "oe")
        let aliases: [String: Screen] = ["uebersicht": .overview, "wissen": .knowledge, "automationen": .automations,
                                         "modelle": .models, "vergleich": .compare, "skills": .extensions, "plugins": .extensions,
                                         "werkzeuge": .tools, "mcp": .tools, "verbinden": .connect, "einstellungen": .settings,
                                         "protokoll": .log, "assistenten": .assistants]
        guard let screen = Screen(rawValue: key) ?? aliases[key] else { return nil }
        self = screen
    }

    var title: String {
        switch self {
        case .overview: return "Übersicht"
        case .agent: return "Agent"
        case .assistants: return "Assistenten"
        case .models: return "Modelle"
        case .knowledge: return "Wissen"
        case .automations: return "Automationen"
        case .compare: return "Vergleich"
        case .extensions: return "Skills & Plugins"
        case .tools: return "Werkzeuge & MCP"
        case .settings: return "Einstellungen"
        case .connect: return "Verbinden"
        case .log: return "Protokoll"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .agent: return "bubble.left.and.text.bubble.right"
        case .assistants: return "sparkles.rectangle.stack"
        case .models: return "square.stack.3d.up"
        case .knowledge: return "books.vertical"
        case .automations: return "clock.badge.checkmark"
        case .compare: return "chart.bar.xaxis"
        case .extensions: return "puzzlepiece.extension"
        case .tools: return "wrench.and.screwdriver"
        case .settings: return "gearshape"
        case .connect: return "point.3.connected.trianglepath.dotted"
        case .log: return "text.alignleft"
        }
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var app
    @State private var screen: Screen = .overview

    var body: some View {
        NavigationSplitView {
            List(Screen.allCases, selection: $screen) { s in
                Label(s.title, systemImage: s.icon).tag(s)
            }
            .safeAreaInset(edge: .top) {
                HStack {
                    Wordmark(size: 22)
                    Spacer()
                }
                .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 4)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) { SidebarStatus() }
        } detail: {
            Group {
                switch screen {
                case .overview: OverviewView(screen: $screen)
                case .agent: AgentView()
                case .assistants: AssistantsView()
                case .models: ModelsView()
                case .knowledge: KnowledgeView()
                case .automations: AutomationsView()
                case .compare: CompareView()
                case .extensions: ExtensionsView()
                case .tools: ToolsView()
                case .settings: SettingsView()
                case .connect: ConnectView()
                case .log: LogView()
                }
            }
            .navigationTitle(screen.title)
            .onChange(of: app.requestedScreen) { _, wanted in
                if let wanted { screen = wanted; app.requestedScreen = nil }
            }
            .onOpenURL { app.open(link: $0) }
            .overlay(alignment: .top) {
                if let notice = app.notice {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task(id: notice) {
                            try? await Task.sleep(for: .seconds(5))
                            withAnimation { app.notice = nil }
                        }
                }
            }
            .toolbar { ToolbarItem(placement: .primaryAction) { ServerToggle() } }
        }
    }
}

struct SidebarStatus: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(state: app.server.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.server.state.label).font(.caption.weight(.semibold)).lineLimit(1)
                Text(app.selectedModelName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(12)
    }
}

struct ServerToggle: View {
    @Environment(AppState.self) private var app

    var body: some View {
        switch app.server.state {
        case .running, .starting:
            Button { app.server.stop() } label: { Label("Stoppen", systemImage: "stop.fill") }
        case .external:
            Label("Extern", systemImage: "bolt.horizontal.fill").foregroundStyle(.green)
        default:
            Button { app.server.start() } label: { Label("Starten", systemImage: "play.fill") }
                .disabled(!app.server.engineInstalled)
        }
    }
}
