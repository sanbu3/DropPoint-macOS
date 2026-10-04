import AppKit
import CoreServices
import Foundation
import UniformTypeIdentifiers

@MainActor
final class DirectoryWatcher {
    var onNewFiles: (([URL]) -> Void)?
    var onReady: (() -> Void)?
    var onError: ((String) -> Void)?
    var fileFilter: (@Sendable (URL) -> Bool)? { didSet { restartIfRunning() } }
    var ignoresReappearingFiles = false { didSet { restartIfRunning() } }
    var watchPaths: [String] = [] {
        didSet { if watchPaths != oldValue { restartIfRunning() } }
    }
    var fileCategory: WatchedFileCategory = .all {
        didSet { if fileCategory != oldValue { restartIfRunning() } }
    }

    private let queue = DispatchQueue(label: "DropPoint.directory-observation", qos: .utility)
    private var worker: DirectoryWatchWorker?
    private var isRunning = false
    private var isIgnoringChanges = false
    private var generation = 0

    func start() {
        guard !isRunning else { return }
        isRunning = true
        restartIfRunning()
    }

    func stop() {
        isRunning = false
        isIgnoringChanges = false
        generation += 1
        if let worker { queue.async { worker.stop() } }
        worker = nil
    }

    func setIgnoringChangesFromInternalDrag(_ ignoring: Bool) {
        isIgnoringChanges = ignoring
        if let worker { queue.async { worker.setIgnoringChangesFromInternalDrag(ignoring) } }
    }

    private func restartIfRunning() {
        guard isRunning else { return }
        generation += 1
        let currentGeneration = generation
        if let worker { queue.async { worker.stop() } }
        let next = DirectoryWatchWorker(
            queue: queue,
            watchPaths: Array(Set(watchPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })),
            fileCategory: fileCategory,
            fileFilter: fileFilter,
            ignoresReappearingFiles: ignoresReappearingFiles,
            onNewFiles: { [weak self] urls in
                Task { @MainActor in
                    guard let self, self.isRunning, self.generation == currentGeneration,
                          !self.isIgnoringChanges else { return }
                    self.onNewFiles?(urls)
                }
            },
            onReady: { [weak self] in
                Task { @MainActor in
                    guard let self, self.isRunning, self.generation == currentGeneration else { return }
                    self.onReady?()
                }
            },
            onError: { [weak self] message in
                Task { @MainActor in
                    guard let self, self.isRunning, self.generation == currentGeneration else { return }
                    self.onError?(message)
                }
            }
        )
        worker = next
        let ignoring = isIgnoringChanges
        queue.async {
            next.start()
            if ignoring { next.setIgnoringChangesFromInternalDrag(true) }
        }
    }

    deinit {
        if let worker { queue.async { worker.stop() } }
    }
}

/// All mutable state and file-system work are confined to this serial utility queue.
private final class DirectoryWatchWorker: @unchecked Sendable {
    private let queue: DispatchQueue
    private let watchPaths: [String]
    private let fileCategory: WatchedFileCategory
    private let fileFilter: (@Sendable (URL) -> Bool)?
    private let ignoresReappearingFiles: Bool
    private let onNewFiles: @Sendable ([URL]) -> Void
    private let onReady: @Sendable () -> Void
    private let onError: @Sendable (String) -> Void

    init(
        queue: DispatchQueue,
        watchPaths: [String],
        fileCategory: WatchedFileCategory,
        fileFilter: (@Sendable (URL) -> Bool)?,
        ignoresReappearingFiles: Bool,
        onNewFiles: @escaping @Sendable ([URL]) -> Void,
        onReady: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) {
        self.queue = queue
        self.watchPaths = watchPaths
        self.fileCategory = fileCategory
        self.fileFilter = fileFilter
        self.ignoresReappearingFiles = ignoresReappearingFiles
        self.onNewFiles = onNewFiles
        self.onReady = onReady
        self.onError = onError
    }

    private var sources: [DispatchSourceFileSystemObject] = []
    private var pendingFiles: [String: [URL]] = [:]
    private var knownFiles: [String: Set<String>] = [:]
    private var knownFileIdentities: [String: [String: FileIdentity]] = [:]
    private var disappearedFileIdentities: [FileIdentity: Date] = [:]
    private var flushWorkItems: [String: DispatchWorkItem] = [:]
    private var resumeObservationWorkItem: DispatchWorkItem?
    private var isIgnoringChanges = false
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        restartSources()
        onReady()
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
        queue.asyncAfter(deadline: .now() + 0.45, execute: workItem)
    }

    private func stopSources() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        flushWorkItems.values.forEach { $0.cancel() }
        flushWorkItems.removeAll()
        pendingFiles.removeAll()
        knownFiles.removeAll()
        knownFileIdentities.removeAll()
        disappearedFileIdentities.removeAll()
    }

    private func restartSources() {
        stopSources()
        for path in watchPaths {
            let url = URL(fileURLWithPath: path)
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else {
                onError("无法监听 \(path)：\(String(cString: strerror(errno)))")
                continue
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.directoryChanged(path: url.path)
            }
            source.setCancelHandler {
                close(descriptor)
            }
            source.resume()
            sources.append(source)
            if let files = directoryContents(at: url) {
                knownFiles[path] = Set(files.map(\.standardizedFileURL.path))
                knownFileIdentities[path] = ignoresReappearingFiles ? fileIdentities(for: files) : [:]
            }
        }
    }

    private func directoryChanged(path: String) {
        guard isRunning else { return }
        let url = URL(fileURLWithPath: path)
        guard let files = directoryContents(at: url) else { return }
        let current = Set(files.map { $0.standardizedFileURL.path })
        guard let previous = knownFiles[path] else {
            knownFiles[path] = current
            knownFileIdentities[path] = ignoresReappearingFiles ? fileIdentities(for: files) : [:]
            return
        }
        let currentIdentities = ignoresReappearingFiles ? fileIdentities(for: files) : [:]
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

        guard flushWorkItems[path] == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPending(path: path)
        }
        flushWorkItems[path] = workItem
        queue.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    private func flushPending(path: String) {
        flushWorkItems.removeValue(forKey: path)
        let files = pendingFiles.removeValue(forKey: path) ?? []
        guard !files.isEmpty else { return }
        let unique = Array(Set(files)).filter { url in
            fileFilter?(url) ?? fileCategory.includes(url)
        }
        if !unique.isEmpty {
            onNewFiles(unique)
        }
    }

    private func directoryContents(at url: URL) -> [URL]? {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            onError("无法读取 \(url.path)：\(error.localizedDescription)")
            return nil
        }
    }

    private func refreshKnownFiles() {
        for path in watchPaths {
            let url = URL(fileURLWithPath: path)
            guard let files = directoryContents(at: url) else { continue }
            knownFiles[path] = Set(files.map(\.standardizedFileURL.path))
            knownFileIdentities[path] = ignoresReappearingFiles ? fileIdentities(for: files) : [:]
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
