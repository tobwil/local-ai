import AppKit
import SwiftUI

/// `KI lokal --snapshot <ordner>`: rendert zentrale Ansichten als PNG (hell und dunkel),
/// um das Erscheinungsbild ohne Bildschirmzugriff zu prüfen.
enum Snapshot {
    @MainActor
    static func run(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = AppState.shared
        let views: [(String, AnyView)] = [
            ("hero", AnyView(VStack(alignment: .leading, spacing: 10) {
                Wordmark(size: 46)
                Text("KI für alle – direkt auf deinem Mac.").font(.system(size: 24, weight: .semibold))
                Text("Privat, offline, ohne Abo.").font(.title3).foregroundStyle(.secondary)
                HStack {
                    Chip(text: "Ornith 1.5 35B · 3 Bit", systemImage: "cpu", tint: Theme.primary)
                    Chip(text: "installiert", systemImage: "checkmark.seal.fill", tint: .green)
                }
                Button {} label: { Label("Loslegen", systemImage: "sparkles") }.buttonStyle(PrimaryButtonStyle())
            }.padding(28).frame(width: 720, alignment: .leading))),
            ("gauge", AnyView(SpeedGauge(tokS: 43, measured: true).padding(20))),
            ("hardware", AnyView(HardwareGrid(hw: app.hardware).padding(20).frame(width: 900))),
            ("footer", AnyView(KisruptivFooter().padding(20).frame(width: 900))),
            ("icon", AnyView(Image(nsImage: NSApp.applicationIconImage ?? NSImage()).resizable().frame(width: 256, height: 256))),
            ("compare", AnyView(Chart_SWE().padding(20).frame(width: 760))),
        ]
        for (name, view) in views {
            for (scheme, label) in [(ColorScheme.light, "hell"), (.dark, "dunkel")] {
                let content = view.environment(app).environment(\.colorScheme, scheme)
                    .background(scheme == .dark ? Color(white: 0.12) : Color.white)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                if let cg = renderer.cgImage {
                    let rep = NSBitmapImageRep(cgImage: cg)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name)-\(label).png"))
                }
            }
        }
        print("→ \(dir.path)")
    }
}

private struct Chart_SWE: View {
    var body: some View {
        let bench = BenchmarkData.all[0]
        return VStack(alignment: .leading) {
            Text(bench.name).font(.headline)
            CompareChart(bench: bench)
        }
    }
}
