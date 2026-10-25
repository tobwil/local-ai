import AVFoundation
import Foundation
import Speech

/// Audio und Video lokal in Text umwandeln – mit der Spracherkennung von macOS auf dem Gerät.
/// Ab macOS 26 mit SpeechAnalyzer (auch lange Aufnahmen), sonst mit SFSpeechRecognizer.
enum Transcription {
    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aiff", "aif", "caf", "aac", "flac", "mp4", "mov", "m4v"]

    static func tool(_ workspace: @escaping () -> URL) -> AgentTool {
        AgentTool(name: "transcribe",
                  description: "Wandelt eine Audio- oder Videodatei (m4a, mp3, wav, mp4, mov …) lokal auf dem Mac in Text um – nichts verlässt den Mac. Speichert das Transkript als .md neben der Aufnahme und liefert den Text (mit Zeitmarken).",
                  parameters: schema([("path", "string", "Pfad zur Aufnahme"),
                                      ("language", "string", "Sprache, z. B. de-DE (Standard) oder en-US")],
                                     required: ["path"]),
                  needsApproval: false, source: "Transkription") { args in
            let url = BuiltinTools.resolve(try BuiltinTools.string(args, "path"), in: workspace())
            let locale = Locale(identifier: args["language"] as? String ?? "de-DE")
            let text = try await transcribe(url, locale: locale)
            let out = url.deletingPathExtension().appendingPathExtension("transkript.md")
            try? "# Transkript: \(url.lastPathComponent)\n\n\(text)\n".write(to: out, atomically: true, encoding: .utf8)
            let words = text.split(whereSeparator: \.isWhitespace).count
            return "Transkript (\(words) Wörter) gespeichert unter \(out.path)\n\n" + String(text.prefix(24_000))
                + (text.count > 24_000 ? "\n… (gekürzt – vollständig in der Datei)" : "")
        }
    }

    static func transcribe(_ url: URL, locale: Locale) async throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError.invalid("Datei nicht gefunden: \(url.path)") }
        let audio = try await audioFile(for: url)
        if #available(macOS 26.0, *) {
            if let text = try? await transcribeWithAnalyzer(audio, locale: locale), !text.isEmpty { return text }
        }
        return try await transcribeWithRecognizer(audio, locale: locale)
    }

    /// Videos (und manche Container) erst in eine reine Audiodatei umwandeln.
    private static func audioFile(for url: URL) async throws -> URL {
        guard ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) else { return url }
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ToolError.invalid("Tonspur ließ sich nicht lesen")
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try await export.export(to: out, as: .m4a)
        return out
    }

    @available(macOS 26.0, *)
    private static func transcribeWithAnalyzer(_ url: URL, locale: Locale) async throws -> String {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw ToolError.invalid("Sprache \(locale.identifier) wird nicht unterstützt")
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        // Sprachmodell einmalig von Apple laden, falls noch nicht auf dem Mac
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        let collect = Task {
            var lines: [String] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                lines.append("[\(timestamp(result.range.start.seconds))] \(text)")
            }
            return lines.joined(separator: "\n\n")
        }
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        return try await collect.value
    }

    private static func transcribeWithRecognizer(_ url: URL, locale: Locale) async throws -> String {
        if CommandLine.arguments.contains("--selftest") { throw ToolError.invalid("Spracherkennung im Selbsttest übersprungen") }
        let status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard status == .authorized else { throw ToolError.invalid("Spracherkennung nicht erlaubt (Systemeinstellungen → Datenschutz → Spracherkennung)") }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw ToolError.invalid("Keine Spracherkennung für \(locale.identifier) verfügbar")
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        return try await withCheckedThrowingContinuation { c in
            var done = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !done else { return }
                if let error { done = true; c.resume(throwing: error); return }
                if let result, result.isFinal { done = true; c.resume(returning: result.bestTranscription.formattedString) }
            }
        }
    }

    private static func timestamp(_ s: Double) -> String {
        let t = Int(s.isFinite ? s : 0)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
    }
}
