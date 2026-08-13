import AppKit
import CoreServices
import Foundation
import UniformTypeIdentifiers

@MainActor
final class DirectoryWatcher {
    var onNewFiles: (([URL]) -> Void)?
    var fileFilter: ((URL) -> Bool)?
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
    }

    private func restartSources() {
        stopSources()
        for path in watchPaths {
            let url = URL(fileURLWithPath: path)
            knownFiles[path] = directoryContents(at: url)
                .map { Set($0.map(\.standardizedFileURL.path)) } ?? []
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
        knownFiles[path] = current
        guard !isIgnoringChanges else { return }
        let newFiles = files.filter {
            !previous.contains($0.standardizedFileURL.path)
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
            knownFiles[path] = directoryContents(at: url)
                .map { Set($0.map(\.standardizedFileURL.path)) } ?? []
        }
    }
}

enum ScreenshotFileDetector {
    static func includes(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey]),
              values.isRegularFile == true,
              values.contentType?.conforms(to: .image) == true else { return false }

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
}
