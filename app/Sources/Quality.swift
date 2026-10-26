import AppKit
import Foundation
import WebKit

/// Macht den Agenten besser als das Modell allein: Die App prüft Arbeitsergebnisse selbst (Syntax, Laufzeitfehler im
/// Browser) und gibt die Befunde mit Zeilennummer sofort zurück; dazu kennt das Modell die verfügbaren Programme.
/// Hintergrund: Ein kleines lokales Modell schreibt schnell, übersieht aber Fehler – die Prüfung schließt die Lücke.
enum DevEnvironment {
    /// Gefundene Programme mit Pfad und Version, z. B. „node v22.3.0 (/usr/local/bin/node)“.
    nonisolated(unsafe) private(set) static var summary = ""
    nonisolated(unsafe) private(set) static var node: String?
    nonisolated(unsafe) private(set) static var python: String?

    /// Einmal beim Start im Hintergrund ermitteln (kaputte Installationen werden übersprungen).
    static func detect() async {
        await Task.detached {
            var found: [String] = []
            // Python: nur eines mit Root-Zertifikaten und aktuellem OpenSSL kann HTTPS (python.org-Installationen ohne
            // „Install Certificates“ haben keine, Apples /usr/bin/python3 hat ein altes LibreSSL).
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var pythons: [(path: String, https: Bool, version: String)] = []
            for path in ["\(home)/.local/bin/python3.12", "\(home)/.local/bin/python3", "/opt/homebrew/bin/python3",
                         "/usr/local/bin/python3", "/usr/bin/python3"] where FileManager.default.isExecutableFile(atPath: path) {
                guard let out = run(path, ["-c", "import ssl,sys;print(sys.version.split()[0], ssl.create_default_context().cert_store_stats()['x509_ca'], ssl.OPENSSL_VERSION.split()[0])"], timeout: 4) else { continue }
                let parts = out.split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard parts.count >= 3 else { continue }
                pythons.append((path, (Int(parts[1]) ?? 0) > 0 && parts[2] == "OpenSSL", parts[0]))
            }
            if let best = pythons.first(where: \.https) ?? pythons.first {
                python = best.path
                found.append("python3: \(best.path) (Python \(best.version)\(best.https ? ", HTTPS ok" : ""))")
                for other in pythons where !other.https && other.path != best.path {
                    found.append("  Achtung: \(other.path) kann kein HTTPS (Zertifikate/SSL fehlen) – für Internet-Zugriffe \(best.path) nehmen")
                }
            }
            for (name, candidates) in [("node", ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]),
                                       ("git", ["/opt/homebrew/bin/git", "/usr/bin/git"]),
                                       ("npm", ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"]),
                                       ("swift", ["/usr/bin/swift"])] {
                for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
                    guard let version = run(path, ["--version"], timeout: 4)?.split(separator: "\n").first.map(String.init),
                          !version.isEmpty else { continue }
                    found.append("\(name): \(path) (\(version.trimmingCharacters(in: .whitespaces)))")
                    if name == "node" { node = path }
                    break
                }
            }
            summary = found.joined(separator: "\n")
        }.value
    }

    /// Programm mit Zeitlimit ausführen; nil bei Fehler (z. B. fehlende Bibliothek) oder Zeitüberschreitung.
    static func run(_ path: String, _ args: [String], timeout: Double) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        guard (try? p.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return p.terminationStatus == 0 ? text : nil
    }

    /// Wie `run`, liefert aber auch bei Fehlern die Ausgabe (für Syntaxprüfungen).
    static func check(_ path: String, _ args: [String], timeout: Double = 10) -> (ok: Bool, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        guard (try? p.run()) != nil else { return (true, "") }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return (true, "") }
        return (p.terminationStatus == 0, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}

/// Prüft eine gerade geschriebene Datei und liefert einen kurzen Befund für das Modell.
enum CodeCheck {
    /// Tests des Projekts finden und ausführen (tests/test_*.js mit node, tests/test_*.py mit python).
    /// Liefert nil, wenn es keine gibt; sonst eine Zusammenfassung mit den fehlgeschlagenen Prüfungen.
    static func projectTests(in root: URL) async -> String? {
        let dir = root.appendingPathComponent("tests")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let tests = files.filter { $0.hasPrefix("test") && ($0.hasSuffix(".js") || $0.hasSuffix(".py")) }.sorted()
        guard !tests.isEmpty else { return nil }
        var lines: [String] = [], allOK = true
        for t in tests {
            let tool = t.hasSuffix(".js") ? DevEnvironment.node : DevEnvironment.python
            guard let tool else { continue }
            let path = dir.appendingPathComponent(t).path
            let r = await Task.detached { DevEnvironment.check(tool, [path], timeout: 90) }.value
            allOK = allOK && r.ok
            let failed = r.output.components(separatedBy: "\n").filter { $0.hasPrefix("✗") || $0.contains("Error") || $0.contains("FAIL") }
            let summary = r.output.components(separatedBy: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            lines.append("\(r.ok ? "✅" : "❌") tests/\(t): \(summary)" + (r.ok ? "" : "\n" + failed.prefix(12).map { "   \($0)" }.joined(separator: "\n")))
        }
        return (allOK ? "Projekttests grün:\n" : "Projekttests NICHT grün – erst beheben:\n") + lines.joined(separator: "\n")
    }

    static let checkable: Set<String> = ["js", "mjs", "cjs", "json", "py", "html", "htm", "sh"]

    @MainActor
    static func report(for url: URL) async -> String? {
        let ext = url.pathExtension.lowercased()
        guard checkable.contains(ext), FileManager.default.fileExists(atPath: url.path) else { return nil }
        var problems: [String] = []
        let name = url.lastPathComponent
        switch ext {
        case "js", "mjs", "cjs":
            if let node = DevEnvironment.node {
                let r = await Task.detached { DevEnvironment.check(node, ["--check", url.path]) }.value
                if !r.ok { problems.append(nodeError(r.output, file: name, lineOffset: 0)) }
            }
        case "json":
            if let data = try? Data(contentsOf: url), (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) == nil {
                problems.append("\(name): ungültiges JSON")
            }
        case "py":
            if let python = DevEnvironment.python {
                let r = await Task.detached { DevEnvironment.check(python, ["-m", "py_compile", url.path]) }.value
                if !r.ok { problems.append(String(r.output.suffix(600))) }
            }
        case "sh":
            let r = await Task.detached { DevEnvironment.check("/bin/bash", ["-n", url.path]) }.value
            if !r.ok { problems.append(String(r.output.suffix(600))) }
        case "html", "htm":
            problems += await htmlScripts(url)
            if problems.isEmpty { problems += await BrowserCheck.errors(loading: url) }
        default:
            break
        }
        if problems.isEmpty {
            return ext == "html" || ext == "htm"
                ? "✅ Automatische Prüfung: Skripte fehlerfrei, Seite lädt im Browser ohne Konsolenfehler."
                : "✅ Automatische Prüfung: Syntax in Ordnung."
        }
        return "❌ Automatische Prüfung von \(name) – bitte jetzt beheben:\n" + problems.prefix(8).map { "- \($0)" }.joined(separator: "\n")
    }

    /// Eingebettete <script>-Blöcke einzeln mit node prüfen (Zeilennummern bezogen auf die HTML-Datei).
    private static func htmlScripts(_ url: URL) async -> [String] {
        guard let node = DevEnvironment.node, let html = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var problems: [String] = []
        for m in html.matches(of: /<script(?![^>]*\bsrc=)([^>]*)>([\s\S]*?)<\/script>/) {
            let attrs = String(m.1)
            if attrs.contains("module") || attrs.contains("json") || attrs.contains("importmap") { continue }
            let offset = html[..<m.2.startIndex].filter { $0 == "\n" }.count
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kilokal-check-\(UUID().uuidString).js")
            try? String(m.2).write(to: tmp, atomically: true, encoding: .utf8)
            let r = await Task.detached { DevEnvironment.check(node, ["--check", tmp.path]) }.value
            try? FileManager.default.removeItem(at: tmp)
            if !r.ok { problems.append(nodeError(r.output, file: url.lastPathComponent, lineOffset: offset)) }
        }
        return problems
    }

    /// „file.js:12\n   code\n   ^\nSyntaxError: …“ → „SyntaxError: … (index.html:129: code)“
    private static func nodeError(_ output: String, file: String, lineOffset: Int) -> String {
        let lines = output.components(separatedBy: "\n")
        let message = lines.first { $0.contains("Error:") }?.trimmingCharacters(in: .whitespaces) ?? "Syntaxfehler"
        var location = ""
        if let first = lines.first, let colon = first.lastIndex(of: ":"), let line = Int(first[first.index(after: colon)...]) {
            let code = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespaces) : ""
            location = " (\(file) Zeile \(line + lineOffset)\(code.isEmpty ? "" : ": \(code.prefix(120))"))"
        }
        return message + location
    }
}

/// Lädt eine Seite unsichtbar in WebKit und sammelt Fehler der ersten Sekunden (Ausnahmen, console.error,
/// fehlende Dateien) – so findet der Agent Laufzeitfehler, ohne dass jemand die Seite öffnen muss.
@MainActor
final class BrowserCheck: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private var errors: [String] = []
    private var longestGap = 0.0
    private var loadedAt: Double?
    private var finished: CheckedContinuation<Void, Never>?
    private static var active: [BrowserCheck] = []

    static func errors(loading url: URL, seconds: Double = 2.5) async -> [String] {
        let c = BrowserCheck()
        active.append(c)
        defer { active.removeAll { $0 === c } }
        return await c.run(url, seconds: seconds)
    }

    private func run(_ url: URL, seconds: Double) async -> [String] {
        let config = WKWebViewConfiguration()
        // Ohne diese Freigabe meldet WebKit bei lokalen Dateien nur „Script error.“ ohne Text und Zeile.
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        config.userContentController.addUserScript(WKUserScript(source: """
            (function(){
              const post = m => { try { webkit.messageHandlers.check.postMessage(String(m)); } catch (e) {} };
              const original = console.error;
              console.error = function(...a) { post('console.error: ' + a.map(String).join(' ')); original.apply(console, a); };
              window.addEventListener('error', e => {
                if (e.target && e.target !== window && (e.target.src || e.target.href)) { post('Datei nicht gefunden: ' + (e.target.src || e.target.href).split('/').pop()); return; }
                post((e.message || 'Fehler') + (e.filename ? ' (' + e.filename.split('/').pop() + ' Zeile ' + e.lineno + ')' : ''));
              }, true);
              window.addEventListener('unhandledrejection', e => post('Promise: ' + ((e.reason && e.reason.message) || e.reason)));
              // Herzschlag: misst, wie lange die Seite blockiert (Endlosschleife, zu langsamer Code)
              const beat = m => { try { webkit.messageHandlers.check.postMessage(m); } catch (e) {} };
              let last = performance.now();
              setInterval(() => { const now = performance.now(); beat({ gap: now - last }); last = now; }, 250);
              window.addEventListener('load', () => beat({ loaded: performance.now() }));
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.add(self, name: "check")
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1200, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: config)
        web.navigationDelegate = self
        window.contentView = web
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        try? await Task.sleep(for: .seconds(seconds))
        config.userContentController.removeScriptMessageHandler(forName: "check")
        window.close()
        var unique: [String] = []
        for e in errors where !unique.contains(e) { unique.append(e) }
        if loadedAt == nil {
            unique.append("Seite hat nach \(Int(seconds)) s noch nicht fertig geladen – sie blockiert vermutlich (Endlosschleife oder sehr langsamer Code beim Start). Mit performance.now() messen, welcher Teil so lange dauert.")
        } else if longestGap > 1500 {
            unique.append("Seite blockiert zwischendurch \(String(format: "%.1f", longestGap / 1000)) s am Stück (zu langsamer Code, z. B. in einer Schleife) – optimieren.")
        }
        return unique
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let beat = message.body as? [String: Any] {
            let gap = (beat["gap"] as? NSNumber)?.doubleValue, loaded = (beat["loaded"] as? NSNumber)?.doubleValue
            MainActor.assumeIsolated {
                if let gap { longestGap = max(longestGap, gap) }
                if let loaded { loadedAt = loaded }
            }
            return
        }
        let text = "\(message.body)"
        MainActor.assumeIsolated { if errors.count < 20 { errors.append(text) } }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let text = "Seite lädt nicht: \(error.localizedDescription)"
        MainActor.assumeIsolated { errors.append(text) }
    }
}
