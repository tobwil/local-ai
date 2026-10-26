import AppKit
import SwiftUI

/// Projekt-Leiste rechts neben dem Chat (wie bei Claude): Wo liegt alles, wie startet man es, wie voll ist der Kontext,
/// was hat der Agent erstellt – unabhängig davon, welches Gespräch gerade offen ist.
struct ProjectPanel: View {
    @Environment(AppState.self) private var app
    @State private var branch: String?
    @State private var dateien: [URL] = []
    @State private var start: StartAktion?

    var body: some View {
        let session = app.session
        let ordner = session.workspace
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Umgebung
                abschnitt("Umgebung") {
                    zeile(icon: "folder", titel: ordner.lastPathComponent, detail: (ordner.path as NSString).abbreviatingWithTildeInPath) {
                        NSWorkspace.shared.open(ordner)
                    }
                    .contextMenu {
                        Button("Im Finder öffnen") { NSWorkspace.shared.open(ordner) }
                        Button("Im Terminal öffnen") { NSWorkspace.shared.open([ordner], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: .init()) }
                        Button("Pfad kopieren") { AppState.copy(ordner.path) }
                    }
                    if let branch { zeile(icon: "arrow.triangle.branch", titel: branch, detail: "Git-Zweig") {} }
                    HStack(spacing: 8) {
                        Circle().fill(app.server.state.isUp || app.selectedIsCloud ? Color.green : Color.secondary).frame(width: 8, height: 8)
                        Text(app.selectedModelName).font(.callout)
                        Spacer()
                        Text(app.selectedIsCloud ? "Cloud" : "lokal").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                }

                // Starten
                if let start {
                    abschnitt("Starten") {
                        Button { start.aktion(app) } label: {
                            Label(start.titel, systemImage: start.icon).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        if let zweit = start.zweitTitel {
                            Button(zweit) { start.zweit?(app) }.buttonStyle(.borderless).font(.callout)
                        }
                        Text(start.hinweis).font(.caption).foregroundStyle(.secondary)
                    }
                }

                // Kontext
                abschnitt("Kontext") { kontext }

                // Ausgaben dieses Gesprächs
                abschnitt("Ausgaben in diesem Gespräch") {
                    let outs = session.outputs
                    if outs.isEmpty {
                        Text("Noch keine – Dateien, die der Agent erstellt oder ändert, erscheinen hier.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(outs.prefix(8), id: \.self) { url in dateiZeile(url, relativZu: ordner) }
                }

                // Projektdateien
                abschnitt("Projektdateien") {
                    ForEach(dateien, id: \.self) { url in dateiZeile(url, relativZu: ordner) }
                    if dateien.isEmpty { Text("Ordner ist leer.").font(.caption).foregroundStyle(.secondary) }
                    Button("Alle im Finder zeigen") { NSWorkspace.shared.open(ordner) }.buttonStyle(.borderless).font(.caption)
                }
            }
            .padding(14)
        }
        .background(.background.secondary)
        .task(id: "\(ordner.path)|\(session.historyVersion)|\(session.items.count)") { await aktualisiere(ordner) }
    }

    // Kontext: wie viel des Arbeitsgedächtnisses der Verlauf belegt
    @ViewBuilder private var kontext: some View {
        let lokal = !app.selectedIsCloud
        // Lokal: 32k-Fenster der Engine (der Prefix-Cache liest pro Schritt nur das Neue ein). Echte Länge der letzten
        // Anfrage, sonst geschätzt (Verlauf samt Systemprompt ≈ 3,5 Zeichen pro Token, dazu die Werkzeug-Beschreibungen).
        let grenze = lokal ? AgentSession.localWindow : 200_000
        let tokens = app.session.lastPromptTokens > 0 ? app.session.lastPromptTokens : 1_200 + app.session.contextChars * 10 / 35
        let anteil = min(1, Double(tokens) / Double(grenze))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("≈ \(tokens.formatted()) von \(grenze.formatted()) Tokens").font(.callout).monospacedDigit()
                Spacer()
                Text("\(Int(anteil * 100)) %").font(.callout.weight(.semibold)).monospacedDigit()
            }
            ProgressView(value: anteil).tint(Double(tokens) > Double(AgentSession.compactAtTokens) && lokal ? .orange : Theme.primary)
            Text(lokal ? "Ab ~\(AgentSession.compactAtTokens / 1000)k kürzt KI/lokal ältere Schritte automatisch – Dateien bleiben vollständig." : "Cloud-Modell mit großem Kontext.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func abschnitt<Inhalt: View>(_ titel: String, @ViewBuilder _ inhalt: () -> Inhalt) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titel).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase).padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 2) { inhalt() }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func zeile(icon: String, titel: String, detail: String, aktion: @escaping () -> Void) -> some View {
        Button(action: aktion) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(Theme.primary).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(titel).font(.callout).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dateiZeile(_ url: URL, relativZu ordner: URL) -> some View {
        let rel = url.path.hasPrefix(ordner.path + "/") ? String(url.path.dropFirst(ordner.path.count + 1)) : url.lastPathComponent
        return Button { app.session.preview.show(url) } label: {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                Text(rel).font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("In der Vorschau öffnen – \(url.path)")
        .contextMenu {
            Button("In der Vorschau öffnen") { app.session.preview.show(url) }
            Button("Mit Standard-App öffnen") { NSWorkspace.shared.open(url) }
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    private func aktualisiere(_ ordner: URL) async {
        let ergebnis = await Task.detached { () -> (String?, [URL], StartAktion?) in
            let git = DevEnvironment.run("/usr/bin/git", ["-C", ordner.path, "rev-parse", "--abbrev-ref", "HEAD"], timeout: 2)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (git, ProjectPanel.neuesteDateien(in: ordner), StartAktion.erkenne(in: ordner))
        }.value
        branch = ergebnis.0; dateien = ergebnis.1; start = ergebnis.2
    }

    /// Zuletzt geänderte Dateien (bis zu 3 Ebenen tief, ohne .git, node_modules, Build-Ordner).
    nonisolated static func neuesteDateien(in ordner: URL, anzahl: Int = 10) -> [URL] {
        let skip: Set<String> = [".git", "node_modules", "build", "DerivedData", ".build", "__pycache__", ".venv", "venv"]
        var gefunden: [(URL, Date)] = []
        guard let e = FileManager.default.enumerator(at: ordner, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        while let url = e.nextObject() as? URL {
            if e.level > 3 { e.skipDescendants(); continue }
            let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            if v?.isDirectory == true { if skip.contains(url.lastPathComponent) { e.skipDescendants() }; continue }
            gefunden.append((url, v?.contentModificationDate ?? .distantPast))
            if gefunden.count > 3_000 { break }
        }
        return gefunden.sorted { $0.1 > $1.1 }.prefix(anzahl).map(\.0)
    }
}

/// Wie man das Projekt startet – aus den Dateien erkannt.
struct StartAktion: Sendable {
    let titel: String
    let icon: String
    let hinweis: String
    let datei: URL
    var zweitTitel: String?

    @MainActor func aktion(_ app: AppState) {
        if ["html", "htm", "md"].contains(datei.pathExtension.lowercased()) { app.session.preview.show(datei) } else { NSWorkspace.shared.open(datei) }
    }
    @MainActor var zweit: ((AppState) -> Void)? {
        { _ in NSWorkspace.shared.open(datei) }
    }

    static func erkenne(in ordner: URL) -> StartAktion? {
        let fm = FileManager.default
        let index = ordner.appendingPathComponent("index.html")
        if fm.fileExists(atPath: index.path) {
            let spiel = (try? String(contentsOf: index, encoding: .utf8))?.lowercased().contains("canvas") ?? false
            return StartAktion(titel: spiel ? "Spiel starten" : "Seite öffnen", icon: spiel ? "gamecontroller.fill" : "globe",
                               hinweis: "Öffnet index.html in der Vorschau – oder im Browser für volle Größe.", datei: index, zweitTitel: "Im Browser öffnen")
        }
        for name in ["README.md", "readme.md", "ANLEITUNG.md"] {
            let url = ordner.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                return StartAktion(titel: "Anleitung lesen", icon: "book", hinweis: "Die README erklärt, wie man das Projekt startet.",
                                   datei: url, zweitTitel: "Mit Standard-App öffnen")
            }
        }
        return nil
    }
}
