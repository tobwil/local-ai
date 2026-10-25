import AppKit
import Quartz
import SwiftUI
import WebKit

/// Seitenleiste mit der Vorschau der Dateien, die der Agent schreibt.
struct PreviewPane: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let preview = app.session.preview
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(preview.files, id: \.self) { url in
                            PreviewTab(url: url, selected: url == preview.selected)
                        }
                    }
                }
                if let url = preview.selected {
                    if preview.editing && PreviewStore.kind(of: url) == .markdown {
                        Picker("", selection: Binding(get: { preview.sourceMode }, set: { preview.sourceMode = $0 })) {
                            Text("Formatiert").tag(false)
                            Text("Markdown").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                    }
                    if PreviewStore.isEditable(url) {
                        Button { withAnimation { preview.editing.toggle() } } label: {
                            Label(preview.editing ? "Fertig" : "Bearbeiten", systemImage: preview.editing ? "checkmark" : "pencil")
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .help(preview.editing ? "Zur Ansicht wechseln (gespeichert wird automatisch)" : "Als Canvas bearbeiten – direkt tippen, wird automatisch gespeichert")
                    }
                }
                // Alles Weitere in einem Menü statt vieler kleiner Symbole
                Menu {
                    if let url = preview.selected {
                        if PreviewStore.kind(of: url) == .markdown {
                            Menu("Exportieren") {
                                Button("Als PDF") { export(url, "pdf") }
                                Button("Als Word (.docx)") { export(url, "docx") }
                                Button("Als HTML") { export(url, "html") }
                            }
                        }
                        Button("Neu laden") { preview.reload() }
                        Button(PreviewStore.kind(of: url) == .web ? "Im Browser öffnen" : "Mit Standard-App öffnen") { NSWorkspace.shared.open(url) }
                        Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Divider()
                    }
                    Toggle("Automatisch öffnen, wenn der Agent etwas erstellt",
                           isOn: Binding(get: { preview.autoOpen }, set: { preview.autoOpen = $0 }))
                    Button("Alle Tabs schließen") { preview.clear() }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 15)) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("Exportieren, öffnen, im Finder zeigen …")
                Button { preview.isOpen = false } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)) }
                    .help("Vorschau schließen")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()

            Group {
                if let url = preview.selected, preview.editing, PreviewStore.isEditable(url) {
                    if PreviewStore.kind(of: url) == .markdown && !preview.sourceMode {
                        RichCanvas(url: url, revision: preview.revision).id(url)
                    } else {
                        CanvasEditor(url: url, revision: preview.revision).id("\(url.path)-quelle")
                    }
                } else if let url = preview.selected {
                    switch PreviewStore.kind(of: url) {
                    case .web: WebPreview(url: url, revision: preview.revision).id(url)
                    case .markdown: MarkdownPreview(url: url, revision: preview.revision)
                    case .quickLook: QuickLookPreview(url: url, revision: preview.revision).id(url)
                    case .code: CodePreview(url: url, revision: preview.revision)
                    }
                } else {
                    ContentUnavailableView("Noch nichts zu zeigen", systemImage: "rectangle.on.rectangle",
                                           description: Text("Sobald der Agent eine Seite, ein Spiel, ein Bild oder ein Dokument schreibt, erscheint es hier. HTML-Blöcke im Chat lassen sich mit „Vorschau“ öffnen."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !preview.consoleErrors.isEmpty { ConsoleBar() }
        }
        .background(.background)
    }
}

extension PreviewPane {
    /// Markdown-Canvas als PDF/Word/HTML neben der Datei speichern und zeigen.
    fileprivate func export(_ url: URL, _ ext: String) {
        let target = url.deletingPathExtension().appendingPathExtension(ext)
        let markdown = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        Task {
            do {
                try await Documents.create(markdown: markdown, title: nil, at: target)
                app.session.preview.show(target)
                app.notice = "Exportiert: \(target.lastPathComponent)"
            } catch { app.notice = "Export fehlgeschlagen: \(error.localizedDescription)" }
        }
    }
}

/// Bearbeitbarer Canvas: Text direkt ändern, wird nach kurzer Pause automatisch gespeichert.
/// Schreibt der Agent die Datei neu, lädt der Canvas den neuen Stand (sofern du gerade nicht tippst).
private struct CanvasEditor: View {
    @Environment(AppState.self) private var app
    let url: URL
    let revision: Int
    @State private var text = ""
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?
    @State private var saved = true

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(PreviewStore.kind(of: url) == .markdown ? .system(size: 14) : .system(size: 12.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 14).padding(.top, 10)
                .onChange(of: text) { _, new in
                    guard loaded else { return }
                    saved = false
                    saveTask?.cancel()
                    saveTask = Task {
                        try? await Task.sleep(for: .milliseconds(600))
                        guard !Task.isCancelled else { return }
                        try? new.write(to: url, atomically: true, encoding: .utf8)
                        app.session.preview.noteOwnWrite()
                        saved = true
                    }
                }
            HStack {
                Label(saved ? "Gespeichert" : "Speichert …", systemImage: saved ? "checkmark.circle" : "clock")
                Text("· \(text.split(whereSeparator: \.isWhitespace).count) Wörter")
                Spacer()
                Text("Tipp: „Überarbeite den Canvas …“ im Chat – der Agent liest deine Änderungen mit.")
            }
            .font(.caption2).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 6)
        }
        .onAppear(perform: load)
        .onChange(of: revision) { if saved { load() } }
    }

    private func load() {
        loaded = false
        text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        DispatchQueue.main.async { loaded = true }
    }
}

private struct PreviewTab: View {
    @Environment(AppState.self) private var app
    let url: URL
    let selected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption)
            Text(url.lastPathComponent).font(.caption.weight(selected ? .semibold : .regular)).lineLimit(1)
            Button { app.session.preview.close(url) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(selected ? AnyShapeStyle(Theme.primary.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                    in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { app.session.preview.select(url) }
        .help(url.path)
    }

    private var icon: String {
        switch PreviewStore.kind(of: url) {
        case .web: return url.pathExtension.lowercased() == "svg" ? "photo" : "globe"
        case .markdown: return "doc.richtext"
        case .quickLook: return "eye"
        case .code: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// Fehler der Seite (console.error, Ausnahmen) – mit einem Klick zurück an den Agenten.
private struct ConsoleBar: View {
    @Environment(AppState.self) private var app
    @State private var expanded = false

    var body: some View {
        let preview = app.session.preview
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { withAnimation { expanded.toggle() } } label: {
                    Label("\(preview.consoleErrors.count) Fehler in der Konsole", systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.plain).foregroundStyle(.orange).font(.callout.weight(.medium))
                Spacer()
                Button("An Agent schicken") {
                    let name = preview.selected?.lastPathComponent ?? "der Seite"
                    app.session.input = "Die Vorschau von \(name) meldet Fehler in der Browser-Konsole:\n"
                        + preview.consoleErrors.prefix(10).map { "- \($0)" }.joined(separator: "\n")
                        + "\nBitte finde die Ursache und behebe sie."
                    app.send()
                }
                .disabled(app.session.isRunning)
            }
            if expanded {
                ScrollView {
                    Text(preview.consoleErrors.joined(separator: "\n"))
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
        }
        .padding(10)
        .background(.orange.opacity(0.1))
    }
}

// MARK: Inhalte

/// HTML/SVG in einer WebKit-Ansicht; Konsolenfehler werden an den PreviewStore gemeldet.
private struct WebPreview: NSViewRepresentable {
    let url: URL
    let revision: Int

    private static let consoleScript = """
    (function(){
      const post = m => { try { webkit.messageHandlers.kilokal.postMessage(String(m)); } catch (e) {} };
      const original = console.error;
      console.error = function(...a) { post(a.map(String).join(' ')); original.apply(console, a); };
      window.addEventListener('error', e => post((e.message || 'Fehler') +
        (e.filename ? ' (' + e.filename.split('/').pop() + ':' + e.lineno + ')' : '')));
      window.addEventListener('unhandledrejection', e => post('Promise: ' + ((e.reason && e.reason.message) || e.reason)));
    })();
    """

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(source: Self.consoleScript, injectionTime: .atDocumentStart,
                                                                forMainFrameOnly: false))
        config.userContentController.add(context.coordinator, name: "kilokal")
        let view = WKWebView(frame: .zero, configuration: config)
        view.isInspectable = true
        view.navigationDelegate = context.coordinator
        context.coordinator.revision = revision
        load(view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.revision != revision else { return }
        context.coordinator.revision = revision
        load(view)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "kilokal")
    }

    private func load(_ view: WKWebView) {
        // Frisch von der Platte laden (der Agent hat die Datei eventuell gerade geändert).
        view.configuration.websiteDataStore.removeData(ofTypes: [WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeDiskCache],
                                                       modifiedSince: .distantPast) {}
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var revision = -1

        /// Breite Seiten (z. B. ein 800-px-Spiel) auf die Breite des Panels verkleinern, statt sie abzuschneiden.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.pageZoom = 1
            webView.evaluateJavaScript("Math.max(document.documentElement.scrollWidth, document.body ? document.body.scrollWidth : 0)") { value, _ in
                guard let width = (value as? NSNumber)?.doubleValue, width > 0 else { return }
                let available = webView.bounds.width
                if width > available + 4 { webView.pageZoom = max(0.35, available / width) }
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let text = "\(message.body)"
            MainActor.assumeIsolated {
                let preview = AppState.shared.session.preview
                if preview.consoleErrors.count < 50 { preview.consoleErrors.append(text) }
            }
        }
    }
}

private struct MarkdownPreview: View {
    let url: URL
    let revision: Int

    var body: some View {
        let _ = revision
        ScrollView {
            RichText(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "Datei nicht lesbar.")
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CodePreview: View {
    let url: URL
    let revision: Int

    var body: some View {
        let _ = revision
        let text = (try? String(contentsOf: url, encoding: .utf8)).map { String($0.prefix(300_000)) } ?? "Datei nicht lesbar (keine Textdatei?)."
        let lines = text.components(separatedBy: "\n")
        let width = String(lines.count).count
        ScrollView([.vertical, .horizontal]) {
            Text(lines.enumerated().map { "\(String(repeating: " ", count: width - String($0.offset + 1).count))\($0.offset + 1)  \($0.element)" }
                .joined(separator: "\n"))
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// Bilder, PDF, Office-Dateien, Audio/Video über QuickLook.
private struct QuickLookPreview: NSViewRepresentable {
    let url: URL
    let revision: Int

    final class Coordinator { var revision = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        context.coordinator.revision = revision
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard context.coordinator.revision != revision else { return }
        context.coordinator.revision = revision
        view.refreshPreviewItem()
    }
}
