//
//  SDModelInstall.swift
//  C4S Suite
//
//  Getting the Generative Clean Up weights onto the client's machine.
//
//  ⚠️ WHY THIS FILE EXISTS AT ALL. Until it did, "Generative Clean Up" worked
//  on exactly one Mac in the world: this one. SDModelStore.resolve() looks in
//  two places — an installed copy in the app's container, and a development
//  copy at ~/Desktop/BriefShow/CoreMLModels. The second is the developer's own
//  folder, and NOTHING EVER WROTE THE FIRST. There was no downloader anywhere
//  in the app: `installedDirectory` was read in two lines and written in none.
//  So every client saw the same greyed-out button and the same "model is not
//  installed on this Mac", and the feature that took weeks to build was dead on
//  arrival everywhere except the machine that built it.
//
//  It is not in the app bundle for a measured reason: the weights are 2.0 GB
//  (the UNet alone is 1.6 GB). Putting them in BriefShow/BriefShow/ — a file
//  system synchronized group — would copy them into the bundle and make a 2.1
//  GB app, and GitHub refuses any file over 100 MB in a repository, so the
//  project would no longer clone and build. They ship as a separate release
//  ASSET instead, which is the decision recorded on 2.09 and measured then:
//  1.99 GB raw, 1.8 GB as an Apple Archive.
//
//  Apple Archive rather than zip, and that is not a preference either: it
//  unarchives through a first-class API. Unzipping would mean spawning `ditto`
//  or `unzip` out of a sandboxed app, which is the kind of thing that works in
//  development and fails once the app is signed.

import Foundation
import AppleArchive
import System
import Combine

/// Downloads and installs the Generative Clean Up weights.
///
/// One object, observed by the panel, so the button and the progress bar read
/// the same state rather than each keeping its own idea of what is happening.
@MainActor
final class SDModelInstaller: NSObject, ObservableObject {

    static let shared = SDModelInstaller()

    enum State: Equatable {
        case idle
        case downloading(fraction: Double)
        case unpacking
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// Bumped when an install finishes, so a view that asked
    /// `SDModelStore.isAvailable` once has something to re-read. The store
    /// itself is a file-system check with no way to announce a change.
    @Published private(set) var installGeneration = 0

    var isWorking: Bool {
        switch state {
        case .downloading, .unpacking: return true
        case .idle, .failed: return false
        }
    }

    /// ⚠️ PINNED TO A TAG, and it has to be a tag that keeps existing.
    ///
    /// This is a GitHub release asset. Moving it, renaming it, or deleting that
    /// release breaks installation for every client who has not installed yet —
    /// the app has no second source. If the asset ever moves, this constant
    /// moves with it, and the old releases keep working only because their own
    /// copy of this constant still points somewhere real.
    private static let archiveURL = URL(
        string: "https://github.com/RocketsBrief/rocketsbrief-briefshow-app/releases/download/v11.0/SD15-Inpainting.aar")!

    /// What the client is told before they agree to spend it.
    static let downloadSizeText = "1.8 GB"

    private var task: URLSessionDownloadTask?
    private lazy var session: URLSession = URLSession(
        configuration: .default, delegate: self, delegateQueue: nil)

    private override init() { super.init() }

    func install() {
        guard !isWorking else {
            return
        }
        state = .downloading(fraction: 0)
        let task = session.downloadTask(with: Self.archiveURL)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    /// Unpacks the archive into the container, then swaps it into place.
    ///
    /// ⚠️ Unpacked BESIDE the destination and moved in only once it is
    /// complete. A download interrupted halfway through unpacking would
    /// otherwise leave a directory holding three of the four models —
    /// `SDModelStore.isComplete` would say no, correctly, but the client would
    /// have paid 1.8 GB for a folder that has to be found and deleted by hand
    /// before a retry can work.
    nonisolated private func unpack(_ archive: URL) throws -> URL {
        let destination = SDModelStore.installedDirectory
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let staging = parent.appendingPathComponent("SD15-Inpainting.incoming-\(UUID().uuidString)",
                                                    isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        guard let readStream = ArchiveByteStream.fileStream(
                path: FilePath(archive.path), mode: .readOnly,
                options: [], permissions: FilePermissions(rawValue: 0o644)),
              let decompressStream = ArchiveByteStream.decompressionStream(readingFrom: readStream),
              let decodeStream = ArchiveStream.decodeStream(readingFrom: decompressStream),
              let extractStream = ArchiveStream.extractStream(
                extractingTo: FilePath(staging.path),
                flags: [.ignoreOperationNotPermitted]) else {
            throw Failure.unpackFailed
        }
        defer {
            try? extractStream.close()
            try? decodeStream.close()
            try? decompressStream.close()
            try? readStream.close()
        }
        _ = try ArchiveStream.process(readingFrom: decodeStream, writingTo: extractStream)

        // The archive was made from the folder, so it unpacks as one directory
        // inside the staging area — unless it was ever remade from the folder's
        // CONTENTS, in which case the models are at the top. Both are accepted:
        // a packaging change should not be a client-facing failure.
        let unpacked = FileManager.default.fileExists(
            atPath: staging.appendingPathComponent("Unet.mlmodelc").path)
            ? staging
            : staging.appendingPathComponent("SD15-Inpainting", isDirectory: true)

        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: unpacked, to: destination)
        try? FileManager.default.removeItem(at: staging)
        return destination
    }

    enum Failure: LocalizedError {
        case unpackFailed
        case incomplete
        var errorDescription: String? {
            switch self {
            case .unpackFailed: return "The model archive could not be unpacked."
            case .incomplete: return "The download finished but some model files are missing."
            }
        }
    }
}

extension SDModelInstaller: URLSessionDownloadDelegate {

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        Task { @MainActor in
            if self.isWorking {
                self.state = .downloading(fraction: min(max(fraction, 0), 1))
            }
        }
    }

    /// ⚠️ The unpack runs HERE, on the delegate's own queue, and the temporary
    /// file is moved out of the way first. URLSession deletes what it hands
    /// over the moment this method returns, so anything that reads it later
    /// reads nothing.
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        let held = FileManager.default.temporaryDirectory
            .appendingPathComponent("sd-download-\(UUID().uuidString).aar")
        do {
            try FileManager.default.moveItem(at: location, to: held)
        } catch {
            Task { @MainActor in self.state = .failed(error.localizedDescription) }
            return
        }

        Task { @MainActor in self.state = .unpacking }

        do {
            _ = try unpack(held)
            try? FileManager.default.removeItem(at: held)
            let complete = SDModelStore.isAvailable
            Task { @MainActor in
                if complete {
                    self.state = .idle
                    self.installGeneration += 1
                } else {
                    self.state = .failed(Failure.incomplete.localizedDescription)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: held)
            Task { @MainActor in self.state = .failed(error.localizedDescription) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else {
            return
        }
        Task { @MainActor in
            if case .unpacking = self.state { return }
            self.state = .failed(error.localizedDescription)
        }
    }
}
