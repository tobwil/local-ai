import Foundation

/// Kopiert die mitgelieferten Skills beim ersten Start nach ~/.kilokal/skills.
/// Vorhandene Ordner bleiben unangetastet, damit eigene Änderungen erhalten bleiben.
enum BundledSkills {
    static func installIfNeeded() {
        guard let src = Bundle.main.url(forResource: "Skills", withExtension: nil),
              let dirs = try? FileManager.default.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: PluginManager.skillsDir, withIntermediateDirectories: true)
        for dir in dirs where dir.hasDirectoryPath {
            let dest = PluginManager.skillsDir.appendingPathComponent(dir.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) { try? fm.copyItem(at: dir, to: dest) }
        }
    }
}
