import Foundation
import Observation

/// Ein Projekt bündelt Gespräche, einen Ordner und eigene Anweisungen (wie Projekte bei ChatGPT/Claude).
/// Wie der Agent arbeitet, ergibt sich daraus: Sieht der Ordner nach Code aus, arbeitet er wie ein Coding-Agent.
struct Project: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case auto, chat, work, code
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return "Automatisch"
            case .chat: return "Nur Chat"
            case .work: return "Arbeiten"
            case .code: return "Code"
            }
        }
    }

    var id = UUID()
    var name: String
    var folder: String?
    var instructions = ""
    var kind: Kind = .auto
    var lastUsed = Date()

    var folderURL: URL? { folder.map { URL(fileURLWithPath: $0) } }

    /// Arbeitsweise: fest eingestellt oder aus dem Ordner erkannt.
    var mode: WorkMode {
        switch kind {
        case .chat: return .chat
        case .work: return .work
        case .code: return .code
        case .auto: return folderURL.map(Self.looksLikeCode) == true ? .code : .work
        }
    }

    private static let codeMarkers: Set<String> = [".git", "package.json", "Package.swift", "pyproject.toml", "requirements.txt",
                                                   "Cargo.toml", "go.mod", "Makefile", "pom.xml", "build.gradle", "Gemfile",
                                                   "composer.json", "index.html", "tsconfig.json", "project.yml", "CMakeLists.txt"]
    private static let codeExtensions: Set<String> = ["js", "ts", "tsx", "jsx", "py", "swift", "java", "kt", "go", "rs", "c", "cpp",
                                                      "h", "rb", "php", "cs", "html", "css", "vue", "svelte", "sh", "xcodeproj"]

    /// Code-Projekt, wenn typische Projektdateien oder mehrere Quelltexte im Ordner (oder in js/, src/) liegen.
    static func looksLikeCode(_ url: URL) -> Bool {
        let fm = FileManager.default
        var names = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        if names.contains(where: codeMarkers.contains) { return true }
        for sub in ["src", "js", "lib", "app", "Sources"] where names.contains(sub) {
            names += (try? fm.contentsOfDirectory(atPath: url.appendingPathComponent(sub).path)) ?? []
        }
        return names.filter { codeExtensions.contains(($0 as NSString).pathExtension.lowercased()) }.count >= 2
    }
}

@MainActor @Observable
final class ProjectStore {
    static let file = Paths.base.appendingPathComponent("projects.json")
    private(set) var projects: [Project] = []

    init() {
        if let d = try? Data(contentsOf: Self.file), let list = try? JSONDecoder().decode([Project].self, from: d) { projects = list }
    }

    /// Zuletzt genutzte zuerst.
    var sorted: [Project] { projects.sorted { $0.lastUsed > $1.lastUsed } }

    func project(id: UUID?) -> Project? { id.flatMap { id in projects.first { $0.id == id } } }

    /// Projekt zu einem Ordner – gibt es keins, wird eins mit dem Ordnernamen angelegt (z. B. für Terminal-Aufträge).
    func project(forFolder url: URL) -> Project {
        let path = url.standardizedFileURL.path
        if let p = projects.first(where: { $0.folder == path }) { return p }
        let p = Project(name: url.lastPathComponent.isEmpty ? "Projekt" : url.lastPathComponent, folder: path)
        upsert(p)
        return p
    }

    func upsert(_ p: Project) {
        if let i = projects.firstIndex(where: { $0.id == p.id }) { projects[i] = p } else { projects.append(p) }
        save()
    }

    func touch(_ id: UUID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].lastUsed = Date()
        save()
    }

    /// Gespräche bleiben erhalten und erscheinen danach ohne Projekt.
    func remove(_ p: Project) {
        projects.removeAll { $0.id == p.id }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Paths.base, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        try? enc.encode(projects).write(to: Self.file, options: .atomic)
    }
}
