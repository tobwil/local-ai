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
        let hide = mode == .screen && NSApp.isActive
        if hide {
            NSApp.hide(nil)
            try await Task.sleep(for: .milliseconds(350))
        }
        defer { if hide { NSApp.unhide(nil) } }
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
    static func lookTool(visionModel: @escaping @MainActor () -> String?) -> AgentTool {
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
            let messages: [[String: Any]] = [["role": "user", "content": [
                ["type": "text", "text": question + " Antworte präzise auf Deutsch."],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]],
            ]]]
            var text = ""
            for try await ev in LLMClient.stream(model: model, messages: messages, tools: [], thinking: false, maxTokens: 1200, mtp: false) {
                if case let .content(c) = ev { text += c }
            }
            return "Bildschirm (gesehen von \(CloudModels.displayName(model))):\n\(text)"
        }
    }
}
