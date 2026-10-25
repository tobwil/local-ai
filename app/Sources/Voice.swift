import AVFoundation
import Foundation
import Observation
import Speech

/// Diktat (Spracherkennung auf dem Gerät) und Vorlesen (Systemstimmen) – ohne zusätzliches Modell.
@MainActor @Observable
final class VoiceController: NSObject {
    private(set) var isListening = false
    private(set) var isSpeaking = false
    private(set) var error: String?
    /// Wird mit dem erkannten Text aufgerufen (laufend aktualisiert).
    var onTranscript: ((String) -> Void)?
    /// Gesprächsmodus: nach dieser Sprechpause gilt eine Äußerung als fertig (nil = Diktat ohne Automatik).
    var pauseInterval: TimeInterval?
    /// Fertige Äußerung im Gesprächsmodus.
    var onUtterance: ((String) -> Void)?
    /// Vorlesen beendet (natürlich oder abgebrochen).
    var onSpeechFinished: (() -> Void)?
    /// Mikrofonpegel 0…1 für die Anzeige.
    private(set) var level: Float = 0
    private(set) var liveText = ""
    private var pauseTimer: Task<Void, Never>?
    /// Für Tests: lautlos vorlesen.
    var muted = false

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let synth = AVSpeechSynthesizer()
    private var prefix = ""

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: Diktat

    func toggleListening(currentText: String) {
        isListening ? stopListening() : startListening(currentText: currentText)
    }

    func startListening(currentText: String) {
        error = nil
        prefix = currentText.isEmpty ? "" : currentText + " "
        Task {
            guard await Self.authorize() else {
                error = "Mikrofon oder Spracherkennung nicht erlaubt (Systemeinstellungen → Datenschutz & Sicherheit)."
                return
            }
            do { try begin() } catch {
                self.error = error.localizedDescription
                stopListening()
            }
        }
    }

    func stopListening() {
        pauseTimer?.cancel()
        pauseTimer = nil
        level = 0
        // Den Audioeingang nur anfassen, wenn er läuft (sonst fragt macOS unnötig nach dem Mikrofon).
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        isListening = false
    }

    private func begin() throws {
        let locale = Locale(identifier: Locale.preferredLanguages.first ?? "de-DE")
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "de-DE")),
              recognizer.isAvailable else { throw ToolError.invalid("Spracherkennung für diese Sprache nicht verfügbar") }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // Wenn möglich komplett auf dem Mac erkennen.
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.addsPunctuation = true
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, weak req] buffer, _ in
            req?.append(buffer)
            // Pegel für die Anzeige (RMS des ersten Kanals).
            guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
            let rms = min(1, sqrt(sum / Float(buffer.frameLength)) * 8)
            Task { @MainActor in self?.level = rms }
        }
        engine.prepare()
        try engine.start()
        isListening = true
        liveText = ""

        task = recognizer.recognitionTask(with: req) { [weak self] result, err in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in
                guard let self else { return }
                if let text { self.handlePartial(self.prefix + text) }
                if err != nil || final {
                    if self.isListening { self.stopListening() }
                    // Im Gesprächsmodus eine erkannte Äußerung trotzdem abschicken.
                    if final, self.pauseInterval != nil, !self.liveText.isEmpty { self.finishUtterance() }
                }
            }
        }
    }

    /// Neuer Zwischenstand der Erkennung: anzeigen und im Gesprächsmodus die Pausen-Uhr neu starten.
    func handlePartial(_ text: String) {
        liveText = text
        onTranscript?(text)
        guard let pause = pauseInterval else { return }
        pauseTimer?.cancel()
        pauseTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(pause))
            guard !Task.isCancelled else { return }
            self?.finishUtterance()
        }
    }

    private func finishUtterance() {
        pauseTimer?.cancel()
        pauseTimer = nil
        let text = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        liveText = ""
        if isListening { stopListening() }
        guard !text.isEmpty else { return }
        onUtterance?(text)
    }

    private static func authorize() async -> Bool {
        // Im Selbsttest aus dem Terminal würde macOS die Anfrage dem Terminal zuordnen (ohne Begründungstext) und
        // den Prozess beenden – dort also nie nach Mikrofon/Spracherkennung fragen.
        if CommandLine.arguments.contains("--selftest") { return false }
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        return speech && mic
    }

    // MARK: Vorlesen

    func speak(_ markdown: String) {
        let text = Self.plain(markdown)
        guard !text.isEmpty else { return }
        synth.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        if muted { utterance.volume = 0 }
        synth.speak(utterance)
        isSpeaking = true
    }

    func stopSpeaking() {
        synth.stopSpeaking(at: .immediate)
        isSpeaking = false
        onSpeechFinished?()
    }

    /// Beste installierte Stimme der Sprache (Premium > Erweitert > Standard).
    static func bestVoice() -> AVSpeechSynthesisVoice? {
        let lang = String((Locale.preferredLanguages.first ?? "de-DE").prefix(2))
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
        return voices.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "de-DE")
    }

    /// Markdown für die Sprachausgabe glätten; Code-Blöcke werden nicht vorgelesen.
    nonisolated static func plain(_ md: String) -> String {
        var s = md.replacingOccurrences(of: "```[\\s\\S]*?```", with: " (Code-Block) ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "https?://\\S+", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "[*_#`>|]", with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension VoiceController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.onSpeechFinished?()
        }
    }
}
