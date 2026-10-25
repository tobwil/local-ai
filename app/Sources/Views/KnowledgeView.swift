import AppKit
import SwiftUI

struct KnowledgeView: View {
    @Environment(AppState.self) private var app
    @State private var query = ""
    @State private var hits: [KnowledgeBase.Hit] = []
    @State private var searching = false

    var body: some View {
        let kb = app.knowledge
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Card {
                    HStack {
                        Label("Eigene Dokumente als Wissen", systemImage: "books.vertical.fill").font(.headline)
                        Spacer()
                        if kb.indexing { ProgressView().controlSize(.small) }
                        Button("Neu indexieren") { kb.reindex() }.disabled(kb.indexing || kb.folders.isEmpty)
                        Button { addFolder() } label: { Label("Ordner hinzufügen", systemImage: "plus") }
                            .buttonStyle(.borderedProminent)
                    }
                    Text("Der Agent durchsucht diese Ordner mit search_documents und nennt die Quelle. Gelesen werden Text, Markdown, PDF, Word, RTF, HTML und Code. Alles bleibt auf dem Mac – die Bedeutungssuche nutzt das Sprachmodell von macOS.")
                        .font(.callout).foregroundStyle(.secondary)
                    if kb.folders.isEmpty {
                        Text("Noch keine Ordner. Zum Beispiel Dokumente, Projekte oder ein Notizen-Ordner.").foregroundStyle(.secondary)
                    }
                    ForEach(kb.folders, id: \.self) { url in
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(Theme.primary)
                            Text(url.path).font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(role: .destructive) { kb.removeFolder(url) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    HStack(spacing: 6) {
                        Chip(text: "\(kb.fileCount) Dateien", systemImage: "doc.on.doc")
                        Chip(text: "\(kb.chunkCount) Abschnitte", systemImage: "square.split.2x1")
                        if let d = kb.lastIndexed { Chip(text: "Stand \(d.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock") }
                        if kb.indexing { Text(kb.progress).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                Card {
                    Text("Suche ausprobieren").font(.headline)
                    HStack {
                        TextField("Wonach suchst du in deinen Unterlagen?", text: $query).textFieldStyle(.roundedBorder)
                            .onSubmit(search)
                        Button("Suchen", action: search).disabled(query.isEmpty || kb.chunkCount == 0)
                        if searching { ProgressView().controlSize(.small) }
                    }
                    ForEach(Array(hits.enumerated()), id: \.offset) { i, h in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("[\(i + 1)]").font(.caption.monospaced()).foregroundStyle(Theme.gold)
                                Button(URL(fileURLWithPath: h.chunk.path).lastPathComponent) {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: h.chunk.path))
                                }
                                .buttonStyle(.link)
                                Text("Abschnitt \(h.chunk.index + 1)").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "%.2f", h.score)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Text(h.chunk.text.prefix(400) + (h.chunk.text.count > 400 ? " …" : "")).font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(24)
        }
    }

    private func search() {
        searching = true
        Task {
            hits = await app.knowledge.search(query, topK: 8)
            searching = false
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Als Wissen hinzufügen"
        if panel.runModal() == .OK { panel.urls.forEach { app.knowledge.addFolder($0) } }
    }
}
