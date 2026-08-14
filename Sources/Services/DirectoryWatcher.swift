import AppKit
import CoreServices
import Foundation
import UniformTypeIdentifiers

@MainActor
final class DirectoryWatcher {
    var onNewFiles: (([URL]) -> Void)?
    var fileFilter: ((URL) -> Bool)?
    var ignoresReappearingFiles = false
    var watchPaths: [String] = [] {
        didSet {
            guard isRunning, watchPaths != oldValue else { return }
            restartSources()
        }
    }
    var fileCategory: WatchedFileCategory = .all

    private var sources: [DispatchSourceFileSystemObject] = []
    private var pendingFiles: [String: [URL]] = [:]
    private var knownFiles: [String: Set<String>] = [:]
    private var knownFileIdentities: [String: [String: FileIdentity]] = [:]
    private var disappearedFileIdentities: [FileIdentity: Date] = [:]
    private var flushWorkItem: DispatchWorkItem?
    private var resumeObservationWorkItem: DispatchWorkItem?
    private var isIgnoringChanges = false
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        restartSources()
    }

    func stop() {
        isRunning = false
        resumeObservationWorkItem?.cancel()
        resumeObservationWorkItem = nil
        isIgnoringChanges = false
        stopSources()
    }

    /// Finder completes a copy before ending our drag source session, but the
    /// directory notification can arrive slightly later. Keep advancing the
    /// directory baseline throughout that short interval without publishing
    /// those files as externally-created items.
    func setIgnoringChangesFromInternalDrag(_ ignoring: Bool) {
        resumeObservationWorkItem?.cancel()
        resumeObservationWorkItem = nil

        if ignoring {
            isIgnoringChanges = true
            return
        }

        guard isIgnoringChanges else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refreshKnownFiles()
            self.isIgnoringChanges = false
            self.resumeObservationWorkItem = nil
        }
        resumeObservationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
    }

    private func stopSources() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        flushWorkItem?.cancel()
        flushWorkItem = nil
        pendingFiles.removeAll()
        knownFiles.removeAll()
        knownFileIdentities.removeAll()
        disappearedFileIdentities.removeAll()
    }

    private func restartSources() {
        stopSources()
        for path in watchPaths {
            let url = URL(fileURLWithPath: path)
            let files = directoryContents(at: url) ?? []
            knownFiles[path] = Set(files.map(\.standardizedFileURL.path))
            knownFileIdentities[path] = fileIdentities(for: files)
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                self?.directoryChanged(path: url.path)
            }
            source.setCancelHandler {
                close(descriptor)
            }
            source.resume()
            sources.append(source)
        }
    }

    private func directoryChanged(path: String) {
        let url = URL(fileURLWithPath: path)
        guard let files = directoryContents(at: url) else { return }
        let current = Set(files.map { $0.standardizedFileURL.path })
        let previous = knownFiles[path] ?? []
        let currentIdentities = fileIdentities(for: files)
        let previousIdentities = knownFileIdentities[path] ?? [:]

        if ignoresReappearingFiles {
            for (filePath, identity) in previousIdentities where !current.contains(filePath) {
                disappearedFileIdentities[identity] = Date()
            }
            pruneDisappearedFileIdentities()
        }

        knownFiles[path] = current
        knownFileIdentities[path] = currentIdentities
        guard !isIgnoringChanges else { return }
        let newFiles = files.filter {
            let filePath = $0.standardizedFileURL.path
            guard !previous.contains(filePath) else { return false }
            guard ignoresReappearingFiles,
                  let identity = currentIdentities[filePath],
                  disappearedFileIdentities.removeValue(forKey: identity) != nil else {
                return true
            }
            return false
        }
        guard !newFiles.isEmpty else { return }

        pendingFiles[path, default: []].append(contentsOf: newFiles)

        flushWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPending()
        }
        flushWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    private func flushPending() {
        for (_, files) in pendingFiles where !files.isEmpty {
            let unique = Array(Set(files)).filter { url in
                fileFilter?(url) ?? fileCategory.includes(url)
            }
            if !unique.isEmpty {
                onNewFiles?(unique)
            }
        }
        pendingFiles.removeAll()
    }

    private func directoryContents(at url: URL) -> [URL]? {
        try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    }

    private func refreshKnownFiles() {
        for path in watchPaths {
            let url = URL(fileURLWithPath: path)
            let files = directoryContents(at: url) ?? []
            knownFiles[path] = Set(files.map(\.standardizedFileURL.path))
            knownFileIdentities[path] = fileIdentities(for: files)
        }
    }

    private func fileIdentities(for files: [URL]) -> [String: FileIdentity] {
        Dictionary(uniqueKeysWithValues: files.compactMap { url in
            guard let identity = FileIdentity(url: url) else { return nil }
            return (url.standardizedFileURL.path, identity)
        })
    }

    private func pruneDisappearedFileIdentities() {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        disappearedFileIdentities = disappearedFileIdentities.filter { $0.value >= cutoff }
    }
}

private struct FileIdentity: Hashable {
    let volumeNumber: UInt64
    let fileNumber: UInt64

    init?(url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let volume = attributes[.systemNumber] as? NSNumber,
              let file = attributes[.systemFileNumber] as? NSNumber else { return nil }
        volumeNumber = volume.uint64Value
        fileNumber = file.uint64Value
    }
}

enum ScreenshotFileDetector {
    static func includes(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .contentTypeKey,
            .creationDateKey,
            .contentModificationDateKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              values.contentType?.conforms(to: .image) == true,
              isRecentlyCreatedOrModified(values) else { return false }

        if let item = MDItemCreate(nil, url.path as CFString),
           let value = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? NSNumber,
           value.boolValue {
            return true
        }

        // Spotlight metadata may lag behind the directory notification. These
        // names cover the macOS tool plus common third-party screenshot apps.
        let name = url.deletingPathExtension().lastPathComponent
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let markers = [
            "screenshot", "screen shot", "screen_shot", "screen-shot",
            "截屏", "截图", "屏幕快照", "capture_", "capture-", "capture ",
            "cleanshot", "shottr", "xnip", "ishot", "snipaste"
        ]
        return markers.contains { name.contains($0) }
    }

    private static func isRecentlyCreatedOrModified(_ values: URLResourceValues) -> Bool {
        let newestDate = [values.creationDate, values.contentModificationDate]
            .compactMap { $0 }
            .max() ?? .distantPast
        return newestDate >= Date().addingTimeInterval(-60)
    }
}
