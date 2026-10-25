import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run())
        }
        if CommandLine.arguments.contains("--mcp-server") {
            MCPServerMode.run()
            exit(0)
        }
        LocalAIApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppState.shared.mcp.disconnectAll()
            AppState.shared.server.shutdownSync()
        }
    }
}

struct LocalAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let app = AppState.shared

    var body: some Scene {
        Window("Local AI", id: "main") {
            ContentView()
                .environment(app)
                .frame(minWidth: 1000, minHeight: 660)
                .task { await app.bootOnce() }
        }
        .windowToolbarStyle(.unified)

        MenuBarExtra {
            MenuBarContent().environment(app)
        } label: {
            Image(systemName: app.server.state.isUp ? "sparkles" : "sparkle")
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(app.server.state.label)
        if let m = app.selectedModel { Text(m.name) }
        Divider()
        if app.server.state == .running || app.server.state == .starting {
            Button("Server stoppen") { app.server.stop() }
        } else if app.server.state != .external {
            Button("Server starten") { app.server.start() }
        }
        Button("Fenster öffnen") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Divider()
        Button("Beenden") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
