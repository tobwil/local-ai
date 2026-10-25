import SwiftUI

enum Screen: String, CaseIterable, Identifiable {
    case overview, agent, models, compare, extensions, tools, connect, settings, log
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Übersicht"
        case .agent: return "Agent"
        case .models: return "Modelle"
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
        case .models: return "square.stack.3d.up"
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
                case .models: ModelsView()
                case .compare: CompareView()
                case .extensions: ExtensionsView()
                case .tools: ToolsView()
                case .settings: SettingsView()
                case .connect: ConnectView()
                case .log: LogView()
                }
            }
            .navigationTitle(screen.title)
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
