// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import CryptoKit
import Foundation

/// What a downloadable speech model consists of: every file with its size and
/// SHA-256 sum, and where to get it. The manifest ships inside the app, so a
/// download is trusted only if it matches what the app was built with.
struct SpeechModelManifest: Decodable, Sendable, Equatable {
    struct File: Decodable, Sendable, Equatable {
        /// Path inside the model's folder.
        var path: String
        /// Name of the file in the release.
        var asset: String
        var size: Int64
        var sha256: String
    }

    struct Sources: Decodable, Sendable, Equatable {
        /// Spec 7: GitHub Releases first.
        var release: String
        /// The fallback.
        var huggingFace: String
    }

    var id: String
    var revision: String
    var sources: Sources
    var files: [File]

    var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    /// Where a file may be downloaded from, in the order to try.
    func urls(for file: File) -> [URL] {
        [URL(string: sources.release + file.asset), URL(string: sources.huggingFace + file.path)].compactMap { $0 }
    }

    static func bundled(named name: String, in bundle: Bundle = .main) throws -> SpeechModelManifest {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw SpeechError.failed("no manifest for \(name)")
        }
        return try JSONDecoder().decode(SpeechModelManifest.self, from: Data(contentsOf: url))
    }
}

/// Downloads a speech model once and keeps it in
/// `~/Library/Application Support/Stickflow/Models/` (spec 7). The network is
/// touched only from `install`, which runs when the user presses the
/// microphone (spec 0.8).
final class SpeechModelStore: Sendable {
    let manifest: SpeechModelManifest
    /// The model's own folder.
    let directory: URL

    init(manifest: SpeechModelManifest, root: URL) {
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

    /// Every file is in place and was checked when it was installed.
    var isInstalled: Bool {
        let files = FileManager.default
        guard files.fileExists(atPath: marker.path) else { return false }
        return manifest.files.allSatisfy { file in
            let attributes = try? files.attributesOfItem(atPath: url(for: file.path).path)
            return (attributes?[.size] as? NSNumber)?.int64Value == file.size
        }
    }

    /// Downloads what is missing and checks every file against its sum.
    /// - Parameter progress: the share of the model's bytes that is in place, 0…1.
    func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try? files.removeItem(at: marker)
        let total = Double(max(manifest.totalSize, 1))
        var done: Int64 = 0
        progress(0)
        for file in manifest.files {
            let target = url(for: file.path)
            let base = done
            if !Self.matches(target, file: file) {
                try await download(file, to: target) { received in
                    progress(min(Double(base + received) / total, 1))
                }
            }
            done += file.size
            progress(min(Double(done) / total, 1))
        }
        try Data(manifest.revision.utf8).write(to: marker, options: .atomic)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func download(_ file: SpeechModelManifest.File, to target: URL, received: @escaping @Sendable (Int64) -> Void) async throws {
        var lastError: any Error = SpeechError.failed("no source for \(file.path)")
        for source in manifest.urls(for: file) {
            do {
                let temporary = try await Self.fetch(source, received: received)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard Self.matches(temporary, file: file) else {
                    throw SpeechError.failed("\(file.path) from \(source.host ?? "?") does not match its checksum")
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
    private static func fetch(_ source: URL, received: @escaping @Sendable (Int64) -> Void) async throws -> URL {
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
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
                let task = session.downloadTask(with: source) { location, response, error in
                    continuation.resume(with: Result { try keep(location: location, response: response, error: error, source: source) })
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
    private static func keep(location: URL?, response: URLResponse?, error: (any Error)?, source: URL) throws -> URL {
        if let error {
            throw (error as? URLError)?.code == .cancelled ? CancellationError() : error
        }
        guard let location, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SpeechError.failed("\(source.host ?? "?") answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("stickflow-model-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: location, to: kept)
        return kept
    }

    /// The file exists, has the right size and the right SHA-256 sum.
    static func matches(_ url: URL, file: SpeechModelManifest.File) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes?[.size] as? NSNumber)?.int64Value == file.size else { return false }
        return (try? sha256(of: url)) == file.sha256.lowercased()
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
