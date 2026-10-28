import AppKit
import Foundation

/// Bildschirmfotos über das Systemwerkzeug `screencapture` (macOS fragt einmal nach der Bildschirmaufnahme-Erlaubnis).
enum ScreenCapture {
    enum Mode: String, CaseIterable, Identifiable {
        case screen, area, window
        var id: String { rawValue }
        var label: String {
            switch self {
            case .screen: return "Ganzer Bildschirm"
            case .area: return "Bereich auswählen"
            case .window: return "Fenster auswählen"
            }
        }
        var icon: String {
            switch self {
            case .screen: return "display"
            case .area: return "rectangle.dashed"
            case .window: return "macwindow"
            }
        }
    }

    /// Nimmt ein Bild auf und liefert es als verkleinertes JPEG (nil = abgebrochen).
    /// Beim ganzen Bildschirm wird das eigene Fenster kurz ausgeblendet.
    @MainActor
    static func capture(_ mode: Mode) async throws -> Data? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kilokal-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        var args = ["-x"]   // ohne Auslösegeräusch
        switch mode {
        case .screen: args += ["-m"]            // Hauptbildschirm
        case .area: args += ["-i", "-s"]        // Bereich ziehen
        case .window: args += ["-i", "-w"]      // Fenster anklicken
        }
        // Im Terminal-Modus (--agent --headless) gibt es kein NSApp – dann nichts ausblenden.
        let app: NSApplication? = NSApp
        let hide = mode == .screen && app?.isActive == true
        if hide {
            app?.hide(nil)
            try await Task.sleep(for: .milliseconds(350))
        }
        defer { if hide { app?.unhide(nil) } }
        _ = try await Shell.exec(["/usr/sbin/screencapture"] + args + [file.path], cwd: FileManager.default.temporaryDirectory, timeout: 120)
        guard FileManager.default.fileExists(atPath: file.path) else {
            // Abgebrochen (Esc) oder keine Erlaubnis.
            if mode == .screen && !CGPreflightScreenCaptureAccess() {
                CGRequestScreenCaptureAccess()
                throw ToolError.invalid("Bildschirmaufnahme nicht erlaubt – Systemeinstellungen → Datenschutz & Sicherheit → Bildschirm- & Systemaudioaufnahme → KI/lokal.")
            }
            return nil
        }
        return ImageAttachment.jpeg(from: file)
    }

    /// Werkzeug für den Agenten: Bildschirm ansehen und eine Frage dazu von einem Vision-Modell beantworten lassen.
    @MainActor
    static func lookTool(visionModel: @escaping @MainActor () -> String?, mainModel: @escaping @MainActor () -> String) -> AgentTool {
        AgentTool(name: "look_at_screen",
                  description: "Macht ein Bildschirmfoto des Hauptbildschirms und lässt ein Vision-Modell eine Frage dazu beantworten (z. B. „Was steht in der Fehlermeldung?“).",
                  parameters: schema([("question", "string", "Was soll auf dem Bildschirm geprüft oder beschrieben werden?")],
                                     required: ["question"]),
                  needsApproval: true, source: "Bildschirm") { args in
            let question = try BuiltinTools.string(args, "question")
            guard let model = await visionModel() else {
                throw ToolError.invalid("Kein Vision-Modell installiert (z. B. Qwen 3.6 · Vision unter Modelle laden).")
            }
            guard let jpeg = try await capture(.screen) else { throw ToolError.invalid("Kein Bild aufgenommen") }
            let text = try await see(jpeg, question: question + " Antworte präzise auf Deutsch.", model: model, mainModel: await mainModel())
            return "Bildschirm (gesehen von \(CloudModels.displayName(model))):\n\(text)"
        }
    }

    /// Ein Bild vom Vision-Modell beschreiben lassen (für look_at_screen und für angehängte Fotos, wenn das Hauptmodell
    /// keine Bilder versteht). Ein eigenes Vision-Modell passt auf kleinen Macs nicht neben das Hauptmodell: vorher das
    /// Hauptmodell, danach das Vision-Modell entladen – sonst kann die Engine das Hauptmodell nicht mehr laden (Fehler 507).
    static func see(_ jpeg: Data, question: String, model: String, mainModel main: String) async throws -> String {
        let messages: [[String: Any]] = [["role": "user", "content": [
            ["type": "text", "text": question],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]],
        ]]]
        let separate = model != main
        let small = ProcessInfo.processInfo.physicalMemory < 48 * 1_073_741_824
        if separate && small { await LLMClient.unload(model: main) }
        var text = ""
        do {
            for try await ev in LLMClient.stream(model: model, messages: messages, tools: [], thinking: false, maxTokens: 1200, mtp: false) {
                if case let .content(c) = ev { text += c }
            }
        } catch {
            if separate { await LLMClient.unload(model: model) }
            throw error
        }
        if separate { await LLMClient.unload(model: model) }
        let seen = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if seen.hasPrefix("[Error") { throw ToolError.invalid("Vision-Modell: \(seen.prefix(300))") }
        guard !seen.isEmpty else {
            throw ToolError.invalid("Das Vision-Modell hat nichts erkannt. Nicht erneut versuchen – nutze andere Werkzeuge (browser_tabs, web_search).")
        }
        return seen
    }
}
