// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import CryptoKit
import Foundation

enum ModelStoreError: Error, Equatable {
    case failed(String)
}

/// What a downloadable model consists of: every file with its size and
/// SHA-256 sum, and where to get it. The manifest ships inside the app, so a
/// download is trusted only if it matches what the app was built with.
struct ModelManifest: Decodable, Sendable, Equatable {
    /// A piece of a big file, downloaded and checked on its own: a broken
    /// download starts again from the last whole piece, and a mirror on
    /// GitHub Releases stays under its 2 GB per file (spec 18.10, 11.4).
    struct Part: Decodable, Sendable, Equatable {
        /// Name of the piece in the release.
        var asset: String
        /// Where the piece starts in the whole file.
        var offset: Int64
        var size: Int64
        var sha256: String
    }

    struct File: Decodable, Sendable, Equatable {
        /// Path inside the model's folder, and on Hugging Face.
        var path: String
        /// Name of the file in the release, when it is there whole.
        var asset: String?
        var size: Int64
        var sha256: String
        /// The pieces, in order; `nil` for a file downloaded whole.
        var parts: [Part]?
    }

    struct Sources: Decodable, Sendable, Equatable {
        /// GitHub Releases first.
        var release: String
        /// The fallback.
        var huggingFace: String
    }

    var id: String
    /// How the settings name the model: "Qwen3 4B".
    var name: String?
    var revision: String
    var sources: Sources
    var files: [File]

    var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    static func bundled(named name: String, in bundle: Bundle = .main) throws -> ModelManifest {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw ModelStoreError.failed("no manifest for \(name)")
        }
        return try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: url))
    }
}

/// Downloads a model once and keeps it in
/// `~/Library/Application Support/Stickflow/Models/` (spec 7, 18.10). The
/// network is touched only from `install`, which runs when the user asks for
/// the models (spec 0.8).
final class ModelStore: Sendable {
    let manifest: ModelManifest
    /// The model's own folder.
    let directory: URL

    init(manifest: ModelManifest, root: URL) {
        self.manifest = manifest
        directory = root
            .appendingPathComponent(manifest.id, isDirectory: true)
            .appendingPathComponent(String(manifest.revision.prefix(12)), isDirectory: true)
    }

    static func defaultRoot() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Stickflow", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    func url(for path: String) -> URL {
        directory.appendingPathComponent(path, isDirectory: false)
    }

    /// Written last, once every file has been checked.
    private var marker: URL { directory.appendingPathComponent(".verified", isDirectory: false) }
    /// Pieces that are already here and checked, kept until their file is whole.
    private var partsDirectory: URL { directory.appendingPathComponent(".parts", isDirectory: true) }

    /// Every file is in place and was checked when it was installed.
    var isInstalled: Bool {
        let files = FileManager.default
        guard files.fileExists(atPath: marker.path) else { return false }
        return manifest.files.allSatisfy { file in
            let attributes = try? files.attributesOfItem(atPath: url(for: file.path).path)
            return (attributes?[.size] as? NSNumber)?.int64Value == file.size
        }
    }

    /// Bytes already on this Mac and checked, with the pieces of a download that broke off.
    var bytesInPlace: Int64 {
        manifest.files.reduce(0) { sum, file in
            if Self.size(of: url(for: file.path)) == file.size { return sum + file.size }
            let parts = file.parts ?? []
            return sum + parts.indices.reduce(0) { $0 + (Self.size(of: partURL(file, $1)) == parts[$1].size ? parts[$1].size : 0) }
        }
    }

    /// Downloads what is missing and checks every file against its sum.
    /// - Parameter progress: bytes of the model in place.
    func install(progress: @escaping @Sendable (Int64) -> Void) async throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try? files.removeItem(at: marker)
        var done: Int64 = 0
        progress(bytesInPlace)
        for file in manifest.files {
            let target = url(for: file.path)
            if Self.size(of: target) == file.size, file.parts != nil || Self.matches(target, size: file.size, sha256: file.sha256) {
                done += file.size
                continue
            }
            if let parts = file.parts {
                try await installParts(of: file, parts: parts, to: target, before: done, progress: progress)
            } else {
                let base = done
                try await download(file, to: target) { received in progress(base + received) }
            }
            done += file.size
            progress(done)
        }
        try? files.removeItem(at: partsDirectory)
        try Data(manifest.revision.utf8).write(to: marker, options: .atomic)
    }

    /// Frees the disk: the settings' "Delete" (spec 18.10 C1).
    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Pieces

    private func partURL(_ file: ModelManifest.File, _ index: Int) -> URL {
        partsDirectory.appendingPathComponent("\(file.path.replacingOccurrences(of: "/", with: "__")).\(index)", isDirectory: false)
    }

    private func installParts(
        of file: ModelManifest.File, parts: [ModelManifest.Part], to target: URL, before: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        try FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true)
        var done = before
        for (index, part) in parts.enumerated() {
            let place = partURL(file, index)
            if !Self.matches(place, size: part.size, sha256: part.sha256) {
                let base = done
                try await download(part, of: file, to: place) { received in progress(base + received) }
            }
            done += part.size
            progress(done)
        }
        // The pieces become the file: each was checked, so the whole is the one in the manifest.
        let joined = target.appendingPathExtension("joining")
        try? FileManager.default.removeItem(at: joined)
        FileManager.default.createFile(atPath: joined.path, contents: nil)
        let output = try FileHandle(forWritingTo: joined)
        do {
            for index in parts.indices {
                let input = try FileHandle(forReadingFrom: partURL(file, index))
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 8 << 20), !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                }
            }
            try output.close()
        } catch {
            try? output.close()
            throw error
        }
        guard Self.size(of: joined) == file.size else { throw ModelStoreError.failed("\(file.path) came together wrong") }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: joined, to: target)
        for index in parts.indices {
            try? FileManager.default.removeItem(at: partURL(file, index))
        }
    }

    /// A piece comes from the release whole, or from Hugging Face as a range of the file.
    private func download(
        _ part: ModelManifest.Part, of file: ModelManifest.File, to target: URL, received: @escaping @Sendable (Int64) -> Void
    ) async throws {
        var sources: [URLRequest] = []
        if let mirror = URL(string: manifest.sources.release + part.asset) { sources.append(URLRequest(url: mirror)) }
        if let original = URL(string: manifest.sources.huggingFace + file.path) {
            var request = URLRequest(url: original)
            request.setValue("bytes=\(part.offset)-\(part.offset + part.size - 1)", forHTTPHeaderField: "Range")
            sources.append(request)
        }
        try await fetchFirst(of: sources, to: target, size: part.size, sha256: part.sha256, received: received)
    }

    private func download(_ file: ModelManifest.File, to target: URL, received: @escaping @Sendable (Int64) -> Void) async throws {
        var sources: [URLRequest] = []
        if let asset = file.asset, let mirror = URL(string: manifest.sources.release + asset) { sources.append(URLRequest(url: mirror)) }
        if let original = URL(string: manifest.sources.huggingFace + file.path) { sources.append(URLRequest(url: original)) }
        try await fetchFirst(of: sources, to: target, size: file.size, sha256: file.sha256, received: received)
    }

    private func fetchFirst(
        of sources: [URLRequest], to target: URL, size: Int64, sha256: String, received: @escaping @Sendable (Int64) -> Void
    ) async throws {
        var lastError: any Error = ModelStoreError.failed("no source for \(target.lastPathComponent)")
        for source in sources {
            do {
                let temporary = try await Self.fetch(source, received: received)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard Self.matches(temporary, size: size, sha256: sha256) else {
                    throw ModelStoreError.failed("\(target.lastPathComponent) from \(source.url?.host ?? "?") does not match its checksum")
                }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: temporary, to: target)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Downloads to a temporary file that the caller owns.
    private static func fetch(_ source: URLRequest, received: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let handle = DownloadHandle()
        // The task is asked how far it is; that works whatever way it was started.
        let poller = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                received(handle.bytesReceived)
            }
        }
        defer { poller.cancel() }
        let ranged = source.value(forHTTPHeaderField: "Range") != nil
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
                let task = session.downloadTask(with: source) { location, response, error in
                    continuation.resume(with: Result {
                        try keep(location: location, response: response, error: error, host: source.url?.host, ranged: ranged)
                    })
                }
                handle.attach(task)
                task.resume()
            }
        } onCancel: {
            handle.cancel()
        }
    }

    /// Runs in the download's completion handler: the system deletes its file
    /// as soon as the handler returns, so the file is moved away here.
    private static func keep(location: URL?, response: URLResponse?, error: (any Error)?, host: String?, ranged: Bool) throws -> URL {
        if let error {
            throw (error as? URLError)?.code == .cancelled ? CancellationError() : error
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // A range must come back as a range: a whole file would not be the piece.
        guard let location, ranged ? status == 206 : (200..<300).contains(status) else {
            throw ModelStoreError.failed("\(host ?? "?") answered \(status)")
        }
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("stickflow-model-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: location, to: kept)
        return kept
    }

    static func size(of url: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
    }

    /// The file exists, has the right size and the right SHA-256 sum.
    static func matches(_ url: URL, size: Int64, sha256: String) -> Bool {
        guard self.size(of: url) == size else { return false }
        return (try? Self.sha256(of: url)) == sha256.lowercased()
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { byte in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
    }
}

/// A running download that can be asked how far it is and told to stop.
private final class DownloadHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var isCancelled = false

    func attach(_ task: URLSessionDownloadTask) {
        lock.lock()
        self.task = task
        let stop = isCancelled
        lock.unlock()
        if stop { task.cancel() }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let running = task
        lock.unlock()
        running?.cancel()
    }

    var bytesReceived: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return task?.countOfBytesReceived ?? 0
    }
}
