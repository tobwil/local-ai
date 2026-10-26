import Foundation

/// Sandbox für `run_shell` (macOS `sandbox-exec`): Schreiben nur im Arbeitsordner und in Temp-/Cache-Ordnern,
/// kein Lesen von Zugangsdaten (~/.ssh, ~/.aws …), keine Änderungen an Shell-Startdateien oder ~/.kilokal.
/// Grundsatz: Was ohne menschliche Freigabe läuft (YOLO, Automationen, Terminal mit --yolo), läuft in der Sandbox.
enum ShellSandbox {
    enum Mode: String, CaseIterable, Identifiable {
        /// Nur Befehle ohne Freigabe (YOLO, Automationen) – Standard.
        case unattended
        /// Jeder Shell-Befehl des Agenten, auch freigegebene.
        case always
        case off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .unattended: return "Ohne Freigabe (YOLO, Automationen)"
            case .always: return "Immer"
            case .off: return "Aus"
            }
        }
    }

    /// Markiert in den Argumenten eines Werkzeug-Aufrufs, dass der Nutzer genau diesen Aufruf freigegeben hat.
    static let approvedKey = "__vom_nutzer_freigegeben"

    static var mode: Mode {
        UserDefaults.standard.string(forKey: "shellSandbox").flatMap(Mode.init(rawValue:)) ?? .unattended
    }

    static var available: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") }

    static func applies(approved: Bool, mode: Mode = mode) -> Bool {
        switch mode {
        case .off: return false
        case .always: return true
        case .unattended: return !approved
        }
    }

    /// Ordner mit Zugangsdaten (relativ zum Benutzerordner): weder lesen noch schreiben.
    static let secretPaths = [".ssh", ".gnupg", ".aws", ".azure", ".kube", ".config/gcloud", ".config/gh", ".docker/config.json",
                              ".netrc", ".password-store", "Library/Keychains", ".kiro/crew/.vault"]
    /// Schreibbar außer dem Arbeitsordner (Paketmanager-Caches, Build-Ordner).
    static let writablePaths = ["Library/Caches", ".cache", ".npm", ".pnpm-store", ".yarn", ".bun", ".cargo/registry",
                                "Library/Developer/Xcode/DerivedData", "Library/org.swift.swiftpm", ".swiftpm"]
    /// Startdateien und Autostart: hier eingeschleuste Befehle würden später ohne Sandbox laufen.
    static let protectedFiles = [".zshrc", ".zprofile", ".zshenv", ".zlogin", ".bashrc", ".bash_profile", ".profile",
                                 "Library/LaunchAgents", ".gitconfig", ".kilokal"]

    /// SBPL-Profil (Seatbelt). Bei mehreren passenden Regeln gilt die letzte.
    static func profile(workspace: URL, home: URL = Paths.home) -> String {
        func q(_ path: String) -> String {
            "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        func real(_ url: URL) -> String { url.resolvingSymlinksInPath().path }
        let h = real(home)
        func under(_ rel: String) -> String { q(h + "/" + rel) }
        var p = """
        (version 1)
        (allow default)
        (deny file-write*)
        (allow file-write*
          (subpath \(q(real(workspace))))
          (subpath "/private/tmp")
          (subpath "/private/var/folders")
          (literal "/dev/null") (literal "/dev/zero") (literal "/dev/dtracehelper")
          (regex #"^/dev/(tty|ttys|fd/|ptmx)")
        """
        for rel in writablePaths { p += "\n  (subpath \(under(rel)))" }
        p += ")\n(deny file-write*"
        for rel in protectedFiles { p += "\n  (subpath \(under(rel)))" }
        p += ")\n(allow file-write* (subpath \(under(".kilokal/skills"))))\n(deny file-read* file-write*"
        for rel in secretPaths { p += "\n  (subpath \(under(rel)))" }
        return p + ")\n"
    }

    static func argv(command: String, workspace: URL) -> [String] {
        ["/usr/bin/sandbox-exec", "-p", profile(workspace: workspace), "/bin/zsh", "-l", "-c", command]
    }

    /// Hinweis an das Modell, wenn ein Befehl an der Sandbox gescheitert ist.
    static func hint(for output: String) -> String? {
        let lower = output.lowercased()
        guard ["operation not permitted", "read-only file system", "sandbox", "permission denied"].contains(where: lower.contains)
        else { return nil }
        return "(Hinweis der App: Der Befehl lief in der Sandbox – Schreiben ist nur im Arbeitsordner, in /tmp und in Cache-Ordnern erlaubt, Zugangsdaten wie ~/.ssh sind gesperrt. Arbeite innerhalb des Arbeitsordners. Ist der Zugriff wirklich nötig, sag dem Nutzer, welcher Befehl es ist – er kann ihn ohne YOLO einzeln freigeben.)"
    }
}

/// Zugangsdaten in Werkzeug-Ergebnissen und im Protokoll unkenntlich machen.
/// Nur eindeutige Formate (feste Präfixe), damit gewöhnlicher Code beim Lesen nicht verfälscht wird.
enum Redaction {
    private static let patterns: [(String, String)] = [
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, "privater Schlüssel"),
        (#"\bsk-ant-[A-Za-z0-9_-]{20,}"#, "Anthropic-Schlüssel"),
        (#"\bsk-(proj-)?[A-Za-z0-9_-]{32,}"#, "OpenAI-Schlüssel"),
        (#"\bgithub_pat_[A-Za-z0-9_]{40,}"#, "GitHub-Token"),
        (#"\bgh[pousr]_[A-Za-z0-9]{30,}"#, "GitHub-Token"),
        (#"\bglpat-[A-Za-z0-9_-]{20,}"#, "GitLab-Token"),
        (#"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#, "AWS-Schlüssel"),
        (#"\bxox[abpr]-[A-Za-z0-9-]{10,}"#, "Slack-Token"),
        (#"\bAIza[0-9A-Za-z_-]{35}\b"#, "Google-Schlüssel"),
        (#"\bhf_[A-Za-z0-9]{30,}"#, "Hugging-Face-Token"),
        (#"(?i)(?<=authorization: bearer )[A-Za-z0-9._~+/-]{20,}=*"#, "Bearer-Token"),
    ]

    static func scrub(_ text: String) -> String {
        guard text.count > 15 else { return text }
        var out = text
        for (pattern, label) in patterns {
            out = out.replacingOccurrences(of: pattern, with: "[\(label) ausgeblendet]", options: .regularExpression)
        }
        return out
    }

    /// Pfad zeigt auf Zugangsdaten (~/.ssh, ~/.aws …)?
    static func isSecretPath(_ path: String, workspace: URL? = nil) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        let full = expanded.hasPrefix("/") ? expanded : (workspace?.appendingPathComponent(expanded).standardizedFileURL.path ?? expanded)
        let home = Paths.home.path
        return ShellSandbox.secretPaths.contains { full == home + "/" + $0 || full.hasPrefix(home + "/" + $0 + "/") }
    }

    /// Shell-Befehl greift erkennbar auf Zugangsdaten zu.
    static func touchesSecrets(command: String) -> Bool {
        command.range(of: #"(~|\$home|/users/[^/\s]+)/\.(ssh|gnupg|aws|azure|kube|netrc|password-store)\b|\bid_(rsa|ed25519|ecdsa)\b|library/keychains|\bsecurity\s+(find|dump)-"#,
                      options: [.regularExpression, .caseInsensitive]) != nil
    }
}
