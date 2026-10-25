import Foundation
import Observation

/// Lädt Modelle direkt von Hugging Face, Datei für Datei, mit Fortschritt.
/// Bereits vollständige Dateien werden übersprungen, ein Abbruch lässt sich also fortsetzen.
@MainActor @Observable
final class Downloads {
    nonisolated static let incompleteMarker = ".download-incomplete"

    struct Progress {
        var done: Int64
        var total: Int64
        var file: String
        var bytesPerSecond: Double = 0
        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    private(set) var active: [String: Progress] = [:]
    private(set) var errors: [String: String] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    func isRunning(_ id: String) -> Bool { tasks[id] != nil }

    func start(_ model: ModelInfo, onFinish: @escaping @MainActor () -> Void) {
        guard tasks[model.id] == nil else { return }
        errors[model.id] = nil
        tasks[model.id] = Task {
            do {
                try await download(model)
                onFinish()
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                errors[model.id] = error.localizedDescription
            }
            active[model.id] = nil
            tasks[model.id] = nil
        }
    }

    func cancel(_ id: String) { tasks[id]?.cancel() }

    private func download(_ model: ModelInfo) async throws {
        let files = try await HuggingFace.files(repo: model.repo)
        let fm = FileManager.default
        try fm.createDirectory(at: model.folder, withIntermediateDirectories: true)
        let marker = model.folder.appendingPathComponent(Self.incompleteMarker)
        fm.createFile(atPath: marker.path, contents: nil)

        let total = files.reduce(Int64(0)) { $0 + $1.size }
        var done: Int64 = 0
        let started = Date()
        for file in files {
            try Task.checkCancellation()
            let dest = model.folder.appendingPathComponent(file.path)
            if let size = (try? fm.attributesOfItem(atPath: dest.path))?[.size] as? Int64, size == file.size {
                done += file.size
                continue
            }
            let base = done
            active[model.id] = Progress(done: done, total: total, file: file.path)
            try await FileDownload.fetch(HuggingFace.resolveURL(repo: model.repo, path: file.path), to: dest) { written in
                Task { @MainActor in
                    let now = base + written
                    let rate = Double(now - base) / max(Date().timeIntervalSince(started), 0.1)
                    self.active[model.id] = Progress(done: now, total: total, file: file.path, bytesPerSecond: rate)
                }
            }
            done += file.size
        }
        try fm.removeItem(at: marker)
    }
}

enum HuggingFace {
    struct File { let path: String; let size: Int64 }

    static func files(repo: String) async throws -> [File] {
        let url = URL(string: "https://huggingface.co/api/models/\(repo)?blobs=true")!
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let siblings = json["siblings"] as? [[String: Any]] else {
            throw URLError(.badServerResponse)
        }
        return siblings.compactMap { s in
            guard let path = s["rfilename"] as? String, path != ".gitattributes" else { return nil }
            return File(path: path, size: (s["size"] as? NSNumber)?.int64Value ?? 0)
        }
    }

    static func resolveURL(repo: String, path: String) -> URL {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "https://huggingface.co/\(repo)/resolve/main/\(encoded)")!
    }
}

/// Eine einzelne Datei per URLSessionDownloadTask, mit Fortschritt und Abbruch.
final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let dest: URL
    private let progress: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var finished = false
    private var moveError: Error?

    private init(dest: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.dest = dest
        self.progress = progress
    }

    static func fetch(_ url: URL, to dest: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let d = FileDownload(dest: dest, progress: progress)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                d.begin(url, continuation: c)
            }
        } onCancel: {
            d.task?.cancel()
        }
    }

    private func begin(_ url: URL, continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: queue)
        session = s
        task = s.downloadTask(with: url)
        task?.resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Die temporäre Datei verschwindet nach diesem Aufruf, also hier sofort verschieben.
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let fm = FileManager.default
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: location, to: dest)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        finished = true
        if let e = error ?? moveError { continuation?.resume(throwing: e) } else { continuation?.resume() }
        continuation = nil
        session.finishTasksAndInvalidate()
    }
}
