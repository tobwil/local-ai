import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot") {
            let dir = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : NSTemporaryDirectory()
            _ = NSApplication.shared
            MainActor.assumeIsolated { Snapshot.run(to: URL(fileURLWithPath: dir)) }
            exit(0)
        }
        if CommandLine.arguments.contains("--install-engine") {
            // Headless-Installation (Ziel per LOCALAI_ENGINE_PREFIX änderbar), z. B. für Tests und Skripte.
            Task { @MainActor in
                let installer = EngineInstaller()
                installer.install()
                var printed = 0
                while installer.running || installer.finished == nil {
                    try? await Task.sleep(for: .milliseconds(500))
                    for line in installer.log.dropFirst(printed) { print(line) }
                    printed = installer.log.count
                }
                print(installer.step)
                exit(installer.finished == true ? 0 : 1)
            }
            dispatchMain()
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
        Window("KI/lokal", id: "main") {
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
        Text(app.selectedModelName)
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
