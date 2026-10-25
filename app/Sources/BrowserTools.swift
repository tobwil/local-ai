import Foundation

/// Steuert den echten Browser des Nutzers über JavaScript for Automation (osascript -l JavaScript).
/// Chromium-Browser brauchen „Ansicht → Entwickler → JavaScript von Apple Events erlauben“,
/// Safari „Entwickler → JavaScript von Apple Events erlauben“. macOS fragt beim ersten Zugriff nach.
enum BrowserTools {
    static let browsers = ["Brave Browser", "Google Chrome", "Microsoft Edge", "Arc", "Safari"]

    static var appName: String { UserDefaults.standard.string(forKey: "browserApp") ?? "Brave Browser" }
    private static var isSafari: Bool { appName == "Safari" }

    static func all() -> [AgentTool] {
        [
            AgentTool(name: "browser_tabs",
                      description: "Listet die offenen Tabs des Browsers (Fenster, Titel, URL; der aktive Tab ist markiert).",
                      parameters: schema([], required: []), needsApproval: false, source: "Browser") { _ in
                try await jxa(tabsScript)
            },
            AgentTool(name: "browser_open",
                      description: "Öffnet eine URL im aktiven Tab (oder mit new_tab=true in einem neuen Tab) und wartet, bis sie geladen ist.",
                      parameters: schema([("url", "string", "Adresse"), ("new_tab", "boolean", "In neuem Tab öffnen")], required: ["url"]),
                      needsApproval: true, source: "Browser") { args in
                let url = try BuiltinTools.string(args, "url")
                guard url.hasPrefix("http://") || url.hasPrefix("https://") else { throw ToolError.invalid("Nur http(s)-Adressen") }
                _ = try await jxa(openScript(url: url, newTab: args["new_tab"] as? Bool ?? false))
                try await Task.sleep(for: .seconds(2))
                return try await runJS(readJS)
            },
            AgentTool(name: "browser_read",
                      description: "Liest den aktiven Tab: Titel, URL, sichtbarer Text und nummerierte Bedienelemente [n] (Links, Buttons, Eingabefelder) für browser_click/browser_type.",
                      parameters: schema([], required: []), needsApproval: false, source: "Browser") { _ in
                try await runJS(readJS)
            },
            AgentTool(name: "browser_click",
                      description: "Klickt das Element mit der Nummer [n] aus browser_read und liefert danach den neuen Seitenzustand.",
                      parameters: schema([("element", "integer", "Nummer aus browser_read")], required: ["element"]),
                      needsApproval: true, source: "Browser") { args in
                guard let n = BuiltinTools.int(args["element"]) else { throw ToolError.invalid("element fehlt") }
                let r = try await runJS(actionJS("el.scrollIntoView({block:'center'}); el.click(); return 'geklickt';", n))
                try await Task.sleep(for: .seconds(1.5))
                return r + "\n\n" + (try await runJS(readJS))
            },
            AgentTool(name: "browser_type",
                      description: "Tippt Text in das Eingabefeld [n] aus browser_read. Mit submit=true wird danach das Formular abgeschickt (Enter).",
                      parameters: schema([("element", "integer", "Nummer aus browser_read"), ("text", "string", "Text"),
                                          ("submit", "boolean", "Danach abschicken")], required: ["element", "text"]),
                      needsApproval: true, source: "Browser") { args in
                guard let n = BuiltinTools.int(args["element"]) else { throw ToolError.invalid("element fehlt") }
                let text = try BuiltinTools.string(args, "text")
                let submit = args["submit"] as? Bool ?? false
                let body = """
                el.focus();
                const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
                const setter = Object.getOwnPropertyDescriptor(proto, 'value');
                if (el.isContentEditable) { el.textContent = \(jsString(text)); } else if (setter) { setter.set.call(el, \(jsString(text))); } else { el.value = \(jsString(text)); }
                el.dispatchEvent(new Event('input', {bubbles: true}));
                el.dispatchEvent(new Event('change', {bubbles: true}));
                if (\(submit)) {
                  el.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true}));
                  if (el.form) { el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit(); }
                }
                return 'eingegeben';
                """
                let r = try await runJS(actionJS(body, n))
                try await Task.sleep(for: .seconds(submit ? 2 : 0.5))
                return r + "\n\n" + (try await runJS(readJS))
            },
            AgentTool(name: "browser_scroll",
                      description: "Scrollt den aktiven Tab nach unten oder oben und liest ihn neu.",
                      parameters: schema([("direction", "string", "down oder up")], required: []),
                      needsApproval: false, source: "Browser") { args in
                let up = (args["direction"] as? String) == "up"
                _ = try await runJS("window.scrollBy(0, \(up ? "-" : "")window.innerHeight * 0.85); return 'ok';")
                try await Task.sleep(for: .milliseconds(500))
                return try await runJS(readJS)
            },
            AgentTool(name: "browser_back",
                      description: "Geht im aktiven Tab eine Seite zurück.",
                      parameters: schema([], required: []), needsApproval: true, source: "Browser") { _ in
                _ = try await runJS("history.back(); return 'ok';")
                try await Task.sleep(for: .seconds(1.5))
                return try await runJS(readJS)
            },
        ]
    }

    // MARK: JavaScript im Tab

    /// Liest die Seite und nummeriert Bedienelemente über data-lai-Attribute.
    static let readJS = """
    const sel = 'a[href], button, input:not([type=hidden]), textarea, select, [role=button], [role=link], [contenteditable=true]';
    const items = [];
    let n = 0;
    document.querySelectorAll('[data-lai]').forEach(e => e.removeAttribute('data-lai'));
    for (const el of document.querySelectorAll(sel)) {
      const r = el.getBoundingClientRect();
      const st = getComputedStyle(el);
      if (r.width < 2 || r.height < 2 || st.visibility === 'hidden' || st.display === 'none') continue;
      n += 1;
      el.setAttribute('data-lai', String(n));
      const tag = el.tagName.toLowerCase();
      const label = (el.innerText || el.value || el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.title || el.name || '').trim().replace(/\\s+/g, ' ').slice(0, 80);
      const kind = tag === 'input' ? 'input:' + (el.type || 'text') : tag;
      const extra = tag === 'a' ? ' → ' + (el.href || '').slice(0, 100) : '';
      items.push('[' + n + '] ' + kind + ' "' + label + '"' + extra);
      if (n >= 150) break;
    }
    const text = (document.body ? document.body.innerText : '').replace(/\\n{3,}/g, '\\n\\n').slice(0, 12000);
    return 'Titel: ' + document.title + '\\nURL: ' + location.href + '\\n\\n--- Text ---\\n' + text + '\\n\\n--- Bedienelemente ---\\n' + items.join('\\n');
    """

    static func actionJS(_ body: String, _ n: Int) -> String {
        """
        const el = document.querySelector('[data-lai="\(n)"]');
        if (!el) return 'Element [\(n)] nicht gefunden – erst browser_read aufrufen.';
        \(body)
        """
    }

    /// JS in einer Funktion ausführen, damit `return` funktioniert; Ergebnis kommt als String zurück.
    static func wrap(_ body: String) -> String {
        "(function(){ try { \(body) } catch (e) { return 'JS-Fehler: ' + e.message; } })()"
    }

    static func runJS(_ body: String) async throws -> String {
        let wrapped = wrap(body)
        let script: String
        if isSafari {
            script = """
            const app = Application('Safari');
            if (app.windows.length === 0) throw new Error('Kein Safari-Fenster offen');
            app.doJavaScript(\(jsString(wrapped)), {in: app.windows[0].currentTab()});
            """
        } else {
            script = """
            const app = Application(\(jsString(appName)));
            if (app.windows.length === 0) throw new Error('Kein Browserfenster offen');
            app.windows[0].activeTab().execute({javascript: \(jsString(wrapped))});
            """
        }
        let out = try await jxa(script)
        if out.contains("JavaScript") && out.contains("Apple") {
            throw ToolError.invalid("Im Browser „JavaScript von Apple Events erlauben“ einschalten (Ansicht/Entwickler-Menü).")
        }
        return out
    }

    static var tabsScript: String {
        let tabsExpr = isSafari ? "w.tabs()" : "w.tabs()"
        let active = isSafari ? "w.currentTab().index()" : "w.activeTabIndex()"
        return """
        const app = Application(\(jsString(appName)));
        const out = [];
        app.windows().forEach((w, wi) => {
          const act = \(active);
          \(tabsExpr).forEach((t, ti) => out.push((ti + 1 === act ? '* ' : '  ') + 'Fenster ' + (wi + 1) + ' · Tab ' + (ti + 1) + ': ' + t.name() + ' — ' + t.url()));
        });
        out.join('\\n') || 'Keine Tabs offen';
        """
    }

    static func openScript(url: String, newTab: Bool) -> String {
        if isSafari {
            return """
            const app = Application('Safari');
            if (app.windows.length === 0 || \(newTab)) { app.Document().make(); }
            app.windows[0].currentTab().url = \(jsString(url));
            'ok';
            """
        }
        return """
        const app = Application(\(jsString(appName)));
        if (app.windows.length === 0) { app.Window().make(); }
        const w = app.windows[0];
        if (\(newTab)) { w.tabs.push(app.Tab({url: \(jsString(url))})); } else { w.activeTab().url = \(jsString(url)); }
        'ok';
        """
    }

    static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    private static func jxa(_ script: String) async throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-l", "JavaScript", "-e", script]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let (data, errData) = try await p.runAndRead(out, errors: err)
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0 else {
            let e = String(decoding: errData, as: UTF8.self)
            if e.contains("-1743") || e.contains("Not authorized") {
                throw ToolError.invalid("macOS hat den Zugriff auf \(appName) verweigert – Systemeinstellungen → Datenschutz & Sicherheit → Automation → KI/lokal erlauben.")
            }
            if e.contains("JavaScript") && e.contains("Apple") {
                throw ToolError.invalid("Im Browser „JavaScript von Apple Events erlauben“ einschalten (Ansicht → Entwickler bzw. Safari → Entwickler).")
            }
            throw ToolError.invalid("osascript: \(e.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))")
        }
        return text.count > 30_000 ? String(text.prefix(30_000)) + "\n… (gekürzt)" : text
    }
}
