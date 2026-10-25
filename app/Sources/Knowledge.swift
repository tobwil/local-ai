import AppKit
import Foundation
import NaturalLanguage
import Observation
import PDFKit

/// Eigene Dokumente als Wissen: Ordner werden indexiert (Text, PDF, Word, Code …), in Abschnitte zerlegt und
/// hybrid durchsucht – Stichwörter (BM25) plus Bedeutung (Embeddings von macOS, auf dem Gerät).
@MainActor @Observable
final class KnowledgeBase {
    struct Chunk: Codable {
        let path: String
        let index: Int
        let text: String
    }

    struct Hit {
        let chunk: Chunk
        let score: Double
    }

    static let dir = Paths.base.appendingPathComponent("knowledge")
    private static let metaURL = dir.appendingPathComponent("index.json")
    private static let vectorsURL = dir.appendingPathComponent("vectors.bin")

    private(set) var folders: [URL] = []
    private(set) var chunkCount = 0
    private(set) var fileCount = 0
    private(set) var indexing = false
    private(set) var progress = ""
    private(set) var lastIndexed: Date?

    private var store = Store()

    init() {
        folders = (UserDefaults.standard.stringArray(forKey: "knowledgeFolders") ?? []).map { URL(fileURLWithPath: $0) }
        Task.detached(priority: .utility) { [weak self] in
            let loaded = Store.load()
            await MainActor.run {
                guard let self else { return }
                self.store = loaded
                self.chunkCount = loaded.chunks.count
                self.fileCount = loaded.files.count
                self.lastIndexed = loaded.updated
            }
        }
    }

    func addFolder(_ url: URL) {
        guard !folders.contains(url) else { return }
        folders.append(url)
        saveFolders()
        reindex()
    }

    func removeFolder(_ url: URL) {
        folders.removeAll { $0 == url }
        saveFolders()
        reindex()
    }

    private func saveFolders() {
        UserDefaults.standard.set(folders.map(\.path), forKey: "knowledgeFolders")
    }

    /// Indexiert neu bzw. inkrementell (nur geänderte Dateien werden neu gelesen).
    func reindex() {
        guard !indexing else { return }
        indexing = true
        progress = "Dateien suchen …"
        let folders = self.folders
        let old = store
        Task.detached(priority: .utility) { [weak self] in
            let new = await Store.build(folders: folders, previous: old) { msg in
                Task { @MainActor in self?.progress = msg }
            }
            new.save()
            await MainActor.run {
                guard let self else { return }
                self.store = new
                self.chunkCount = new.chunks.count
                self.fileCount = new.files.count
                self.lastIndexed = new.updated
                self.indexing = false
                self.progress = "\(new.files.count) Dateien, \(new.chunks.count) Abschnitte"
            }
        }
    }

    func search(_ query: String, topK: Int = 6) async -> [Hit] {
        let store = self.store
        return await Task.detached(priority: .userInitiated) { store.search(query, topK: topK) }.value
    }

    /// Werkzeug für den Agenten.
    func tool() -> AgentTool {
        AgentTool(name: "search_documents",
                  description: "Durchsucht die eigenen Dokumente des Nutzers (indexierte Ordner: Notizen, PDFs, Word, Code …) und liefert die passendsten Abschnitte mit Dateipfad. Für Fragen zu eigenen Unterlagen zuerst diese Suche nutzen und die Quelle nennen.",
                  parameters: schema([("query", "string", "Suchanfrage in natürlicher Sprache"),
                                      ("top_k", "integer", "Anzahl Abschnitte (Standard 6, max. 15)")], required: ["query"]),
                  needsApproval: false, source: "Wissen") { [weak self] args in
            guard let self else { return "Wissensbasis nicht verfügbar" }
            let q = try BuiltinTools.string(args, "query")
            let k = min(max(BuiltinTools.int(args["top_k"]) ?? 6, 1), 15)
            let hits = await self.search(q, topK: k)
            guard !hits.isEmpty else { return "Keine passenden Abschnitte gefunden." }
            return hits.enumerated().map { i, h in
                "[\(i + 1)] \(h.chunk.path) (Abschnitt \(h.chunk.index + 1), Relevanz \(String(format: "%.2f", h.score)))\n\(h.chunk.text)"
            }.joined(separator: "\n\n---\n\n")
        }
    }
}

// MARK: Index

/// Unveränderlicher Index-Stand (wird als Ganzes ersetzt; sicher zwischen Threads zu teilen).
struct Store: @unchecked Sendable {
    var chunks: [KnowledgeBase.Chunk] = []
    /// Normalisierte Vektoren, `dim` Werte pro Abschnitt (leer, wenn kein Embedding verfügbar war).
    var vectors: [Float] = []
    var dim = 0
    /// Mittelwert aller Roh-Vektoren; abgezogen, damit sich die Vektoren besser unterscheiden (Zentrierung).
    var mean: [Float] = []
    /// Zentrierte, normalisierte Vektoren für die Suche (aus `vectors` berechnet, nicht gespeichert).
    var centered: [Float] = []
    /// Pfad → Änderungsdatum zum Zeitpunkt der Indexierung.
    var files: [String: Double] = [:]
    var updated: Date?
    // BM25
    private var postings: [String: [(Int, Int)]] = [:]
    private var lengths: [Int] = []
    private var avgLength = 1.0

    static let textExtensions: Set<String> = ["txt", "md", "markdown", "csv", "tsv", "json", "yaml", "yml", "toml", "xml", "log",
        "swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "java", "kt", "c", "h", "cpp", "m", "rb", "php", "sh", "sql", "css", "tex"]
    static let richExtensions: Set<String> = ["pdf", "docx", "doc", "rtf", "odt", "html", "htm"]

    // MARK: Aufbau

    static func build(folders: [URL], previous: Store, progress: @escaping @Sendable (String) -> Void) async -> Store {
        let files = collect(folders)
        var result = Store()
        result.dim = previous.dim
        let embedder = Embedder()
        // Unveränderte Dateien übernehmen.
        var reuse: [String: [(KnowledgeBase.Chunk, ArraySlice<Float>)]] = [:]
        for (i, c) in previous.chunks.enumerated() {
            let vec = previous.dim > 0 && previous.vectors.count >= (i + 1) * previous.dim
                ? previous.vectors[(i * previous.dim)..<((i + 1) * previous.dim)] : []
            reuse[c.path, default: []].append((c, vec))
        }
        for (n, (url, mtime)) in files.enumerated() {
            if n % 10 == 0 { progress("Lese \(n + 1) von \(files.count): \(url.lastPathComponent)") }
            let path = url.path
            if previous.files[path] == mtime, let kept = reuse[path], embedder.dim == previous.dim {
                for (c, v) in kept { result.chunks.append(c); result.vectors += v }
                result.files[path] = mtime
                continue
            }
            guard let text = extract(url), !text.isEmpty else { continue }
            for (i, piece) in chunk(text).enumerated() {
                result.chunks.append(KnowledgeBase.Chunk(path: path, index: i, text: piece))
                if embedder.dim > 0 { result.vectors += embedder.vector(piece) }
            }
            result.files[path] = mtime
        }
        result.dim = embedder.dim
        result.updated = Date()
        result.center(previousMean: previous.mean)
        result.buildBM25()
        return result
    }

    private static func collect(_ folders: [URL]) -> [(URL, Double)] {
        let skip: Set<String> = [".git", "node_modules", ".build", "build", "DerivedData", ".venv", "venv", "Library", ".Trash"]
        var out: [(URL, Double)] = []
        for folder in folders {
            let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey],
                                                   options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = e?.nextObject() as? URL {
                let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey])
                if v?.isDirectory == true { if skip.contains(url.lastPathComponent) { e?.skipDescendants() }; continue }
                let ext = url.pathExtension.lowercased()
                guard textExtensions.contains(ext) || richExtensions.contains(ext), (v?.fileSize ?? 0) < 20_000_000 else { continue }
                out.append((url, v?.contentModificationDate?.timeIntervalSince1970 ?? 0))
                if out.count >= 20_000 { return out }
            }
        }
        return out
    }

    static func extract(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return PDFDocument(url: url)?.string }
        if ext == "html" || ext == "htm" {
            return (try? String(contentsOf: url, encoding: .utf8)).map { HTMLText.markdown($0, base: url, includeLinks: false) }
        }
        if richExtensions.contains(ext) {
            return try? NSAttributedString(url: url, options: [:], documentAttributes: nil).string
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Abschnitte von ~1200 Zeichen an Absatzgrenzen, mit etwas Überlappung.
    static func chunk(_ text: String, size: Int = 1200, overlap: Int = 200) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var out: [String] = []
        var current = ""
        for p in paragraphs {
            if current.count + p.count > size, !current.isEmpty {
                out.append(current)
                current = String(current.suffix(overlap))
            }
            if p.count > size * 2 {
                // Sehr lange Absätze hart teilen.
                var rest = Substring(p)
                while !rest.isEmpty {
                    out.append(String(current + rest.prefix(size)))
                    current = ""
                    rest = rest.dropFirst(size - overlap)
                    if rest.count <= overlap { break }
                }
            } else {
                current += (current.isEmpty ? "" : "\n\n") + p
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(current) }
        return out
    }

    /// Roh-Vektoren um den Mittelwert des Bestands zentrieren und normalisieren – gemittelte Token-Vektoren
    /// liegen sonst alle in derselben Richtung und unterscheiden sich kaum.
    mutating func center(previousMean: [Float] = []) {
        guard dim > 0, vectors.count == chunks.count * dim, !chunks.isEmpty else { mean = []; centered = []; return }
        var m = [Float](repeating: 0, count: dim)
        for i in 0..<chunks.count { for d in 0..<dim { m[d] += vectors[i * dim + d] } }
        for d in 0..<dim { m[d] /= Float(chunks.count) }
        var c = vectors
        for i in 0..<chunks.count {
            var norm: Float = 0
            for d in 0..<dim { let v = c[i * dim + d] - m[d]; c[i * dim + d] = v; norm += v * v }
            norm = max(sqrt(norm), 1e-9)
            for d in 0..<dim { c[i * dim + d] /= norm }
        }
        mean = m
        centered = c
    }

    // MARK: Suche

    /// Wörter klein und ohne Akzente; lange Wörter zusätzlich als 6-Zeichen-Stamm, damit deutsche
    /// Komposita zusammenfinden („Steuerberater“ ↔ „Steuerkanzlei“).
    static func tokens(_ s: String) -> [String] {
        let words = s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .split { !($0.isLetter || $0.isNumber) }.map(String.init).filter { $0.count > 1 && !stopwords.contains($0) }
        return words.flatMap { $0.count > 7 ? [$0, String($0.prefix(6)) + "~"] : [$0] }
    }

    static let stopwords: Set<String> = ["der", "die", "das", "und", "oder", "ein", "eine", "einen", "ich", "du", "wir", "ihr", "sie", "es",
        "ist", "sind", "war", "den", "dem", "des", "im", "in", "am", "an", "zu", "zum", "zur", "mit", "fur", "von", "auf", "wie", "was",
        "wann", "wer", "wo", "mein", "meine", "the", "and", "of", "to", "is", "for", "on", "bei", "auch", "nicht", "noch", "dann"]

    mutating func buildBM25() {
        postings = [:]
        lengths = []
        for (i, c) in chunks.enumerated() {
            let toks = Self.tokens(c.text)
            lengths.append(toks.count)
            var tf: [String: Int] = [:]
            for t in toks { tf[t, default: 0] += 1 }
            for (t, n) in tf { postings[t, default: []].append((i, n)) }
        }
        avgLength = Double(max(lengths.reduce(0, +), 1)) / Double(max(lengths.count, 1))
    }

    func search(_ query: String, topK: Int) -> [KnowledgeBase.Hit] {
        guard !chunks.isEmpty else { return [] }
        var bm25 = [Double](repeating: 0, count: chunks.count)
        let n = Double(chunks.count), k1 = 1.4, b = 0.75
        for t in Set(Self.tokens(query)) {
            guard let list = postings[t] else { continue }
            let idf = log(1 + (n - Double(list.count) + 0.5) / (Double(list.count) + 0.5))
            for (i, tf) in list {
                let f = Double(tf), len = Double(lengths[i])
                bm25[i] += idf * f * (k1 + 1) / (f + k1 * (1 - b + b * len / avgLength))
            }
        }
        let maxBM = bm25.max() ?? 0
        var cosine = [Double](repeating: 0, count: chunks.count)
        if dim > 0, centered.count == chunks.count * dim {
            var q = Embedder().raw(query)
            if q.count == dim, mean.count == dim {
                var norm: Float = 0
                for d in 0..<dim { q[d] -= mean[d]; norm += q[d] * q[d] }
                norm = max(sqrt(norm), 1e-9)
                for d in 0..<dim { q[d] /= norm }
                for i in 0..<chunks.count {
                    var s: Float = 0
                    let base = i * dim
                    for d in 0..<dim { s += centered[base + d] * q[d] }
                    cosine[i] = Double(s)
                }
            }
        }
        let scored = (0..<chunks.count).map { i -> (Int, Double) in
            let kw = maxBM > 0 ? bm25[i] / maxBM : 0
            return (i, dim > 0 ? 0.45 * kw + 0.55 * max(cosine[i], 0) : kw)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(topK).filter { $0.1 > 0.01 }.map { KnowledgeBase.Hit(chunk: chunks[$0.0], score: $0.1) }
    }

    // MARK: Speichern

    func save() {
        try? FileManager.default.createDirectory(at: KnowledgeBase.dir, withIntermediateDirectories: true)
        struct Meta: Codable { var chunks: [KnowledgeBase.Chunk]; var files: [String: Double]; var dim: Int; var updated: Date?; var mean: [Float] }
        if let data = try? JSONEncoder().encode(Meta(chunks: chunks, files: files, dim: dim, updated: updated, mean: mean)) {
            try? data.write(to: KnowledgeBase.dir.appendingPathComponent("index.json"), options: .atomic)
        }
        let raw = vectors.withUnsafeBufferPointer { Data(buffer: $0) }
        try? raw.write(to: KnowledgeBase.dir.appendingPathComponent("vectors.bin"), options: .atomic)
    }

    static func load() -> Store {
        struct Meta: Codable { var chunks: [KnowledgeBase.Chunk]; var files: [String: Double]; var dim: Int; var updated: Date?; var mean: [Float]? }
        guard let data = try? Data(contentsOf: KnowledgeBase.dir.appendingPathComponent("index.json")),
              let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return Store() }
        var s = Store()
        s.chunks = meta.chunks
        s.files = meta.files
        s.dim = meta.dim
        s.updated = meta.updated
        s.mean = meta.mean ?? []
        if let raw = try? Data(contentsOf: KnowledgeBase.dir.appendingPathComponent("vectors.bin")) {
            s.vectors = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        if s.vectors.count != s.chunks.count * s.dim { s.vectors = []; s.dim = 0 }
        s.center()
        s.buildBM25()
        return s
    }
}

/// Satz-Vektoren aus dem kontextuellen Embedding von macOS (Mittelwert über Tokens, normalisiert).
final class Embedder: @unchecked Sendable {
    private let model: NLContextualEmbedding?
    let dim: Int

    init() {
        let m = NLContextualEmbedding(language: .german) ?? NLContextualEmbedding(language: .english)
        if let m, m.hasAvailableAssets, (try? m.load()) != nil {
            model = m
            dim = m.dimension
        } else {
            model = nil
            dim = 0
        }
    }

    func vector(_ text: String) -> [Float] { raw(text) }

    /// Mittelwert der Token-Vektoren (nicht normalisiert – zentriert und normalisiert wird im Index).
    func raw(_ text: String) -> [Float] {
        let s = String(text.prefix(2000))
        guard let model, let result = try? model.embeddingResult(for: s, language: nil) else { return [] }
        var sum = [Double](repeating: 0, count: dim)
        var count = 0
        result.enumerateTokenVectors(in: s.startIndex..<s.endIndex) { vec, _ in
            for i in 0..<min(vec.count, sum.count) { sum[i] += vec[i] }
            count += 1
            return true
        }
        guard count > 0 else { return [] }
        return sum.map { Float($0 / Double(count)) }
    }
}
