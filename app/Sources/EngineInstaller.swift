import Foundation
import Observation

/// Richtet die Engine (oMLX) ohne Terminal ein: Python finden oder per uv holen, oMLX in einer
/// festen Version laden, den MTP-pro-Anfrage-Patch anwenden, installieren und Metal-Kernels bauen.
@MainActor @Observable
final class EngineInstaller {
    /// oMLX-Stand, gegen den der Patch in engine/patches erstellt und getestet wurde.
    static let omlxRepo = "https://github.com/jundot/omlx.git"
    static let omlxCommit = "78fa08bc1aef7290c93c83bb70811547763ebf33"
    /// Eigene Patches in dieser Reihenfolge (engine/patches, im App-Paket unter Resources/Engine).
    static let patches = [
        ("omlx-mtp-per-request", "MTP pro Anfrage (X-oMLX-MTP)"),
        ("omlx-preflight-prefix-cache", "Speicherprüfung zählt den Prompt-Cache mit (lange Agent-Läufe auf 24 GB)"),
    ]

    /// Bereits eingerichtete Engine: fehlende eigene Patches nachtragen (nur Python-Dateien, wirkt beim nächsten Start
    /// der Engine). Liefert die Namen der eingespielten Patches.
    @discardableResult
    nonisolated static func applyMissingPatches() -> [String] {
        let src = prefix.appendingPathComponent("src-omlx")
        guard FileManager.default.fileExists(atPath: src.appendingPathComponent(".git").path) else { return [] }
        func git(_ args: [String]) -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", src.path] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return false }
            p.waitUntilExit()
            return p.terminationStatus == 0
        }
        var applied: [String] = []
        for (name, _) in patches {
            guard let patch = Bundle.main.url(forResource: name, withExtension: "patch") else { continue }
            if git(["apply", "--check", "--reverse", "--whitespace=nowarn", patch.path]) { continue }   // schon drin
            if git(["apply", "--check", "--whitespace=nowarn", patch.path]), git(["apply", "--whitespace=nowarn", patch.path]) {
                applied.append(name)
            }
        }
        return applied
    }

    private(set) var running = false
    private(set) var log: [String] = []
    private(set) var step = ""
    private(set) var finished: Bool?

    /// Zielordner; für Tests per LOCALAI_ENGINE_PREFIX umlenkbar.
    nonisolated static var prefix: URL {
        ProcessInfo.processInfo.environment["LOCALAI_ENGINE_PREFIX"].map { URL(fileURLWithPath: $0) } ?? Paths.base
    }

    func install() {
        guard !running else { return }
        running = true
        finished = nil
        log = []
        Task {
            do {
                try await run()
                finished = true
                step = "Fertig – die Engine ist eingerichtet."
            } catch {
                finished = false
                step = "Fehler: \(error.localizedDescription)"
                append("✗ \(error.localizedDescription)")
            }
            running = false
        }
    }

    private func run() async throws {
        let base = Self.prefix
        let src = base.appendingPathComponent("src-omlx")
        let venv = base.appendingPathComponent("omlx-venv")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        step = "1/5 · Python suchen"
        let python = try await findPython()
        append("Python: \(python)")

        step = "2/5 · oMLX laden (\(Self.omlxCommit.prefix(7)))"
        if !FileManager.default.fileExists(atPath: src.appendingPathComponent(".git").path) {
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            try await sh(["git", "init", "-q"], in: src)
            try await sh(["git", "remote", "add", "origin", Self.omlxRepo], in: src)
        }
        try await sh(["git", "fetch", "-q", "--depth", "1", "origin", Self.omlxCommit], in: src)
        try await sh(["git", "checkout", "-q", "-f", "FETCH_HEAD"], in: src)

        step = "3/5 · Patches anwenden"
        for (name, what) in Self.patches {
            if let patch = Bundle.main.url(forResource: name, withExtension: "patch") {
                try await sh(["git", "apply", "--whitespace=nowarn", patch.path], in: src)
                append("Patch angewendet: \(what)")
            } else {
                append("Patch \(name) nicht im App-Paket gefunden")
            }
        }

        step = "4/5 · Python-Umgebung und Pakete (dauert einige Minuten)"
        if !FileManager.default.fileExists(atPath: venv.appendingPathComponent("bin/python").path) {
            try await sh([python, "-m", "venv", venv.path], in: base)
        }
        let py = venv.appendingPathComponent("bin/python").path
        try await sh([py, "-m", "pip", "install", "-q", "--upgrade", "pip", "cmake"], in: base)
        let hasMetal = (try? await sh(["xcrun", "--find", "metal"], in: base, quiet: true)) != nil
        var env = ["PATH": venv.appendingPathComponent("bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"]
        env["PYTHON"] = py
        try await sh(["make", hasMetal ? "install" : "install-no-kernels", "PYTHON=\(py)"], in: src, env: env)
        if !hasMetal { append("Hinweis: Ohne Xcode/Metal-Toolchain laufen die schnellen Spezial-Kernels nicht.") }

        step = "5/5 · Prüfen"
        let version = try await sh([venv.appendingPathComponent("bin/omlx").path, "--version"], in: base)
        append("oMLX \(version.trimmingCharacters(in: .whitespacesAndNewlines)) bereit")
    }

    /// Python 3.11–3.13 suchen; wenn keins da ist, uv installieren und Python 3.12 holen.
    private func findPython() async throws -> String {
        let home = Paths.home.path
        let candidates = ["\(home)/.local/bin/python3.12", "\(home)/.local/bin/python3.13", "\(home)/.local/bin/python3.11",
                          "/opt/homebrew/bin/python3.12", "/opt/homebrew/bin/python3.13", "/opt/homebrew/bin/python3.11",
                          "/usr/local/bin/python3.12", "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return found }
        append("Kein passendes Python gefunden – installiere uv und Python 3.12")
        let uv = "\(home)/.local/bin/uv"
        if !FileManager.default.isExecutableFile(atPath: uv) {
            try await sh(["/bin/sh", "-c", "curl -LsSf https://astral.sh/uv/install.sh | sh"], in: Paths.home)
        }
        try await sh([uv, "python", "install", "3.12"], in: Paths.home)
        let path = try await sh([uv, "python", "find", "3.12"], in: Paths.home).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw ToolError.invalid("Python 3.12 konnte nicht eingerichtet werden") }
        return path
    }

    @discardableResult
    private func sh(_ argv: [String], in dir: URL, env: [String: String] = [:], quiet: Bool = false) async throws -> String {
        if !quiet { append("$ " + argv.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0].hasPrefix("/") ? argv[0] : "/usr/bin/env")
        p.arguments = argv[0].hasPrefix("/") ? Array(argv.dropFirst()) : argv
        p.currentDirectoryURL = dir
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        // Ausgabe live ins Protokoll, damit lange pip/make-Läufe sichtbar bleiben.
        let collected = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            collected.append(d)
            let text = String(decoding: d, as: UTF8.self)
            if !quiet { Task { @MainActor in self?.appendRaw(text) } }
        }
        let exited = AsyncStream<Void> { cont in p.terminationHandler = { _ in cont.yield(); cont.finish() } }
        try p.run()
        for await _ in exited {}
        pipe.fileHandleForReading.readabilityHandler = nil
        let out = collected.string
        guard p.terminationStatus == 0 else {
            throw ToolError.invalid("\(argv.prefix(3).joined(separator: " ")) fehlgeschlagen (Status \(p.terminationStatus)): \(out.suffix(400))")
        }
        return out
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 600 { log.removeFirst(log.count - 600) }
    }

    private func appendRaw(_ text: String) {
        for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            append("  " + line)
        }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.withLock { data.append(d) } }
    var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
