import SwiftUI
import WebKit

/// Formatierter Canvas für Markdown: Überschriften, Fett, Listen und Tabellen sieht und bearbeitet man direkt
/// (wie in einem Textprogramm). Jede Änderung wird als Markdown zurückgeschrieben – der Agent und der Export
/// arbeiten weiter mit der .md-Datei.
struct RichCanvas: View {
    @Environment(AppState.self) private var app
    let url: URL
    let revision: Int
    @State private var bridge = CanvasBridge()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                group([("Absatz", "text.alignleft", "block('p')"), ("Überschrift 1", "textformat.size.larger", "block('h1')"),
                       ("Überschrift 2", "textformat.size", "block('h2')"), ("Überschrift 3", "textformat.size.smaller", "block('h3')")])
                Divider().frame(height: 16).padding(.horizontal, 4)
                group([("Fett", "bold", "cmd('bold')"), ("Kursiv", "italic", "cmd('italic')"), ("Code", "chevron.left.forwardslash.chevron.right", "inlineCode()")])
                Divider().frame(height: 16).padding(.horizontal, 4)
                group([("Aufzählung", "list.bullet", "cmd('insertUnorderedList')"), ("Nummerierung", "list.number", "cmd('insertOrderedList')"),
                       ("Zitat", "text.quote", "block('blockquote')"), ("Tabelle einfügen", "tablecells", "insertTable()"),
                       ("Trennlinie", "minus", "cmd('insertHorizontalRule')")])
                Divider().frame(height: 16).padding(.horizontal, 4)
                group([("Rückgängig", "arrow.uturn.backward", "cmd('undo')"), ("Wiederholen", "arrow.uturn.forward", "cmd('redo')")])
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.bar)
            CanvasWeb(url: url, revision: revision, bridge: bridge) { app.session.preview.noteOwnWrite() }
            HStack {
                Label(bridge.saved ? "Gespeichert" : "Speichert …", systemImage: bridge.saved ? "checkmark.circle" : "clock")
                Text("· \(bridge.words) Wörter")
                Spacer()
                Text("„Überarbeite den Canvas …“ im Chat – der Agent liest deine Änderungen mit.")
            }
            .font(.caption2).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 6)
        }
    }

    private func group(_ items: [(String, String, String)]) -> some View {
        ForEach(items, id: \.0) { title, icon, js in
            Button { bridge.run(js) } label: { Image(systemName: icon).frame(width: 24, height: 22) }
                .help(title)
        }
    }
}

@MainActor @Observable
final class CanvasBridge {
    var saved = true
    var words = 0
    @ObservationIgnored weak var web: WKWebView?

    func run(_ js: String) { web?.evaluateJavaScript(js) }
}

private struct CanvasWeb: NSViewRepresentable {
    let url: URL
    let revision: Int
    let bridge: CanvasBridge
    let onSaved: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(url: url, bridge: bridge, onSaved: onSaved) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "canvas")
        let web = WKWebView(frame: .zero, configuration: config)
        web.isInspectable = true
        bridge.web = web
        context.coordinator.revision = revision
        web.loadHTMLString(Self.page(markdown: Self.read(url)), baseURL: url.deletingLastPathComponent())
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        guard context.coordinator.revision != revision else { return }
        context.coordinator.revision = revision
        // Von außen geändert (Agent)? Nur übernehmen, wenn gerade nichts Ungespeichertes im Editor steht.
        guard bridge.saved else { return }
        let html = MarkdownHTML.body(Self.read(url))
        if let data = try? JSONSerialization.data(withJSONObject: [html]), let json = String(data: data, encoding: .utf8) {
            web.evaluateJavaScript("setContent(\(json)[0])")
        }
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "canvas")
    }

    static func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let url: URL
        let bridge: CanvasBridge
        let onSaved: () -> Void
        var revision = -1

        init(url: URL, bridge: CanvasBridge, onSaved: @escaping () -> Void) {
            self.url = url; self.bridge = bridge; self.onSaved = onSaved
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            MainActor.assumeIsolated {
                if body["dirty"] as? Bool == true { bridge.saved = false; return }
                if let words = body["words"] as? Int { bridge.words = words; return }
                guard let markdown = body["markdown"] as? String else { return }
                try? markdown.write(to: url, atomically: true, encoding: .utf8)
                bridge.words = markdown.split(whereSeparator: \.isWhitespace).count
                bridge.saved = true
                onSaved()
            }
        }
    }

    /// Editor-Seite: Papier-Optik wie der PDF-Export, contenteditable, DOM → Markdown beim Tippen.
    static func page(markdown: String) -> String {
        """
        <!doctype html><html lang="de"><head><meta charset="utf-8"><style>
        html { background: #e9ecf1; }
        body { margin: 0; padding: 28px 0 60px; font: 15px/1.6 -apple-system, "Helvetica Neue", sans-serif; color: #1d2433; }
        #doc { background: #fff; max-width: 760px; margin: 0 auto; padding: 48px 56px; min-height: 900px; outline: none;
               box-shadow: 0 1px 3px rgba(0,0,0,.08), 0 8px 24px rgba(0,0,0,.06); border-radius: 4px; }
        h1 { font-size: 26px; color: #274060; margin: 0 0 10px; padding-bottom: 8px; border-bottom: 3px solid #FCC419; }
        h2 { font-size: 19px; color: #274060; margin: 22px 0 6px; } h3 { font-size: 16px; color: #274060; margin: 16px 0 4px; }
        p { margin: 0 0 10px; } ul, ol { margin: 0 0 10px; padding-left: 24px; }
        table { border-collapse: collapse; width: 100%; margin: 10px 0 14px; font-size: 14px; }
        th { background: #274060; color: #fff; text-align: left; padding: 6px 8px; }
        td { border-bottom: 1px solid #d9dee8; padding: 6px 8px; } tr:nth-child(even) td { background: #f4f6fa; }
        blockquote { margin: 10px 0; padding: 6px 12px; border-left: 3px solid #7590BF; background: #f4f6fa; color: #4a5568; }
        code { font: 13px Menlo, monospace; background: #f0f2f6; padding: 1px 4px; border-radius: 3px; }
        pre { background: #f0f2f6; padding: 10px; border-radius: 4px; white-space: pre-wrap; }
        hr { border: none; border-top: 1px solid #d9dee8; margin: 18px 0; }
        @media (prefers-color-scheme: dark) { html { background: #1c1e22; } }
        </style></head><body><div id="doc" contenteditable="true" spellcheck="true">\(MarkdownHTML.body(markdown))</div>
        <script>
        const doc = document.getElementById('doc');
        const post = m => window.webkit.messageHandlers.canvas.postMessage(m);
        function cmd(c) { document.execCommand(c, false, null); doc.focus(); changed(); }
        function block(tag) { document.execCommand('formatBlock', false, tag); doc.focus(); changed(); }
        function inlineCode() {
          const s = window.getSelection(); if (!s.rangeCount || s.isCollapsed) return;
          document.execCommand('insertHTML', false, '<code>' + s.toString().replace(/</g,'&lt;') + '</code>'); changed();
        }
        function insertTable() {
          document.execCommand('insertHTML', false, '<table><thead><tr><th>Spalte 1</th><th>Spalte 2</th><th>Spalte 3</th></tr></thead><tbody><tr><td>&nbsp;</td><td>&nbsp;</td><td>&nbsp;</td></tr><tr><td>&nbsp;</td><td>&nbsp;</td><td>&nbsp;</td></tr></tbody></table><p><br></p>');
          changed();
        }
        function setContent(html) { doc.innerHTML = html; }
        function inline(node) {
          let out = '';
          node.childNodes.forEach(n => {
            if (n.nodeType === 3) { out += n.textContent.replace(/\\u00a0/g, ' '); return; }
            if (n.nodeType !== 1) return;
            const t = n.tagName, inner = inline(n);
            if (t === 'STRONG' || t === 'B') out += inner.trim() ? '**' + inner + '**' : inner;
            else if (t === 'EM' || t === 'I') out += inner.trim() ? '*' + inner + '*' : inner;
            else if (t === 'CODE') out += '`' + n.textContent + '`';
            else if (t === 'A') out += '[' + inner + '](' + n.getAttribute('href') + ')';
            else if (t === 'BR') out += '\\n';
            else out += inner;
          });
          return out;
        }
        function list(el, ordered, depth) {
          let out = '', i = 1;
          el.childNodes.forEach(li => {
            if (li.nodeType !== 1 || li.tagName !== 'LI') return;
            let text = '', nested = '';
            li.childNodes.forEach(c => {
              if (c.nodeType === 1 && (c.tagName === 'UL' || c.tagName === 'OL')) nested += list(c, c.tagName === 'OL', depth + 1);
              else text += c.nodeType === 3 ? c.textContent : inline({ childNodes: [c] });
            });
            out += '  '.repeat(depth) + (ordered ? (i++) + '. ' : '- ') + text.trim() + '\\n' + nested;
          });
          return out;
        }
        function toMarkdown() {
          const parts = [];
          doc.childNodes.forEach(n => {
            if (n.nodeType === 3) { if (n.textContent.trim()) parts.push(n.textContent.trim()); return; }
            if (n.nodeType !== 1) return;
            const t = n.tagName;
            if (/^H[1-6]$/.test(t)) parts.push('#'.repeat(+t[1]) + ' ' + inline(n).trim());
            else if (t === 'UL' || t === 'OL') parts.push(list(n, t === 'OL', 0).trimEnd());
            else if (t === 'BLOCKQUOTE') parts.push(inline(n).trim().split('\\n').map(l => '> ' + l).join('\\n'));
            else if (t === 'PRE') parts.push('```\\n' + n.textContent.replace(/\\n$/, '') + '\\n```');
            else if (t === 'HR') parts.push('---');
            else if (t === 'TABLE') {
              const rows = [...n.querySelectorAll('tr')].map(r => [...r.children].map(c => inline(c).trim().replace(/\\|/g, '/') || ' '));
              if (rows.length) {
                const w = Math.max(...rows.map(r => r.length));
                const line = r => '| ' + [...r, ...Array(w - r.length).fill(' ')].join(' | ') + ' |';
                parts.push([line(rows[0]), '|' + ' --- |'.repeat(w), ...rows.slice(1).map(line)].join('\\n'));
              }
            }
            else { const s = inline(n).trim(); if (s) parts.push(s); }
          });
          return parts.join('\\n\\n') + '\\n';
        }
        let timer = null;
        function changed() {
          post({ dirty: true });
          clearTimeout(timer);
          timer = setTimeout(() => post({ markdown: toMarkdown() }), 500);
        }
        doc.addEventListener('input', changed);
        document.addEventListener('keydown', e => {
          if (e.metaKey && e.key === 'b') { e.preventDefault(); cmd('bold'); }
          if (e.metaKey && e.key === 'i') { e.preventDefault(); cmd('italic'); }
        });
        post({ words: (doc.innerText.match(/\\S+/g) || []).length });
        </script></body></html>
        """
    }
}
