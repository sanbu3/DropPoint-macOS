import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum FileDropImporter {
    enum ImportEvent: Sendable {
        case imported([URL])
        case failed(String)
    }

    private static let importQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "DropPoint.file-import"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    // A file provider may occupy its delivery queue. Keep it separate from our image writes.
    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "DropPoint.promised-file-delivery"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    private static let legacyFileNames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    private static var imageDataTypes: [NSPasteboard.PasteboardType] {
        NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }
    }

    static var readableTypes: [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = [
            .fileURL,
            legacyFileNames,
            .png,
            .tiff,
            .URL,
            .string,
            .html,
        ]
        types.append(contentsOf: imageDataTypes)
        for rawType in NSFilePromiseReceiver.readableDraggedTypes {
            types.append(NSPasteboard.PasteboardType(rawType))
        }
        var seen = Set<NSPasteboard.PasteboardType>()
        return types.filter { seen.insert($0).inserted }
    }

    static func canImport(from pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) { return true }
        if pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self]) { return true }
        if pasteboard.availableType(from: imageDataTypes) != nil { return true }
        return webURL(from: pasteboard) != nil
    }

    /// Returns immediately when the drag was accepted. File promises complete asynchronously.
    @discardableResult
    static func importFiles(
        from pasteboard: NSPasteboard,
        completion: @MainActor @escaping @Sendable (ImportEvent) -> Void
    ) -> Bool {
        // Copy pasteboard payloads while the drag owns them; encode and write off the main thread.
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            importQueue.addOperation {
                let existing = urls.filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
                Task { @MainActor in
                    completion(existing.isEmpty
                        ? .failed("拖入的文件已被移动、删除或暂时无法访问。")
                        : .imported(existing))
                }
            }
            return true
        }

        if let promises = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self]
        ) as? [NSFilePromiseReceiver], !promises.isEmpty {
            Task {
                let destination = await Task.detached(priority: .utility) { makeImportDirectory() }.value
                guard let destination else {
                    completion(.failed("无法创建拖入文件的保存目录。"))
                    return
                }
                let delivery = FilePromiseDelivery(
                    remaining: promises.reduce(0) { $0 + max(1, $1.fileNames.count) },
                    completion: completion
                )
                for promise in promises {
                    promise.receivePromisedFiles(
                        atDestination: destination,
                        options: [:],
                        operationQueue: promiseQueue
                    ) { url, error in
                        let event: ImportEvent
                        if let error { event = .failed(error.localizedDescription) }
                        else if FileManager.default.fileExists(atPath: url.path) { event = .imported([url]) }
                        else { event = .failed("提供文件的应用没有完成传输。") }
                        Task { @MainActor in delivery.receive(event) }
                    }
                }
            }
            return true
        }

        for type in imageDataTypes {
            guard let data = pasteboard.data(forType: type) else { continue }
            importQueue.addOperation {
                let url = writePNG(data)
                Task { @MainActor in
                    completion(url.map { .imported([$0]) } ?? .failed("无法读取或保存拖入的图片。"))
                }
            }
            return true
        }

        if let sourceURL = webURL(from: pasteboard) {
            importQueue.addOperation {
                let url = writeWebLocation(sourceURL)
                Task { @MainActor in
                    completion(url.map { .imported([$0]) } ?? .failed("无法保存拖入的链接。"))
                }
            }
            return true
        }
        return false
    }

    nonisolated private static func makeImportDirectory() -> URL? {
        guard let root = importRootDirectory() else { return nil }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch { return nil }
    }

    nonisolated
    static func cleanupStaleImports(
        rootDirectory: URL? = nil,
        now: Date = Date(),
        maximumAge: TimeInterval = 7 * 24 * 60 * 60,
        fileManager: FileManager = .default
    ) {
        guard let root = rootDirectory ?? importRootDirectory(fileManager: fileManager),
              let directories = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return }
        let cutoff = now.addingTimeInterval(-maximumAge)
        for directory in directories {
            guard let values = try? directory.resourceValues(
                forKeys: [.contentModificationDateKey, .creationDateKey]
            ) else { continue }
            let date = values.contentModificationDate ?? values.creationDate ?? .distantFuture
            if date < cutoff { try? fileManager.removeItem(at: directory) }
        }
    }

    nonisolated private static func importRootDirectory(fileManager: FileManager = .default) -> URL? {
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return support
            .appendingPathComponent("DropPoint", isDirectory: true)
            .appendingPathComponent("Imported Files", isDirectory: true)
    }

    nonisolated static func writePNG(_ data: Data) -> URL? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let directory = makeImportDirectory() else { return nil }
        let url = directory.appendingPathComponent("Dragged Image.png")
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        do {
            try (output as Data).write(to: url, options: .atomic)
            return url
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    private static func webURL(from pasteboard: NSPasteboard) -> URL? {
        for type in [NSPasteboard.PasteboardType.URL, .string] {
            guard let value = pasteboard.string(forType: type),
                  let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { continue }
            return url
        }

        guard let html = pasteboard.string(forType: .html),
              let detector = try? NSDataDetector(
                types: NSTextCheckingResult.CheckingType.link.rawValue
              ),
              let match = detector.firstMatch(
                in: html,
                range: NSRange(html.startIndex..., in: html)
              ),
              let url = match.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    nonisolated static func writeWebLocation(_ sourceURL: URL) -> URL? {
        guard let directory = makeImportDirectory(),
              let data = try? PropertyListSerialization.data(
                fromPropertyList: ["URL": sourceURL.absoluteString],
                format: .xml,
                options: 0
              ) else { return nil }
        let url = directory.appendingPathComponent("Dragged Link.webloc")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

@MainActor
private final class FilePromiseDelivery {
    private var remaining: Int
    private var isFinished = false
    private let completion: @MainActor @Sendable (FileDropImporter.ImportEvent) -> Void
    private var timeoutTask: Task<Void, Never>?

    init(remaining: Int, completion: @MainActor @escaping @Sendable (FileDropImporter.ImportEvent) -> Void) {
        self.remaining = remaining
        self.completion = completion
        timeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard let self, !self.isFinished else { return }
            self.isFinished = true
            self.completion(.failed("提供文件的应用长时间没有完成传输，请重试拖入。"))
        }
    }

    func receive(_ event: FileDropImporter.ImportEvent) {
        guard !isFinished else { return }
        completion(event)
        remaining -= 1
        if remaining <= 0 {
            isFinished = true
            timeoutTask?.cancel()
            timeoutTask = nil
        }
    }
}
