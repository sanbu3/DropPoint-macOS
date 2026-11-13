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

    private static let chromiumImageHTML = NSPasteboard.PasteboardType("org.chromium.image-html")
    private static let promisedContentType = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type")
    private static let imageSourcePattern = try! NSRegularExpression(
        pattern: #"<img\b[^>]*?\s+src\s*=\s*(?:"([^"]+)"|'([^']+)'|([^\s>]+))"#,
        options: .caseInsensitive
    )

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
            chromiumImageHTML,
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

    /// Inspect the advertised format without requesting promised files or image bytes.
    static func containsOnlyImages(_ pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return urls.allSatisfy { url in
                if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey]) {
                    if values.isDirectory == true { return false }
                    if let type = values.contentType { return type.conforms(to: .image) }
                }
                return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
            }
        }

        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return false }
        let imageTypes = Set(imageDataTypes)
        let allAdvertiseImages = items.allSatisfy { item in
            if !imageTypes.isDisjoint(with: item.types) { return true }
            guard let identifier = item.string(forType: promisedContentType) else { return false }
            return UTType(identifier)?.conforms(to: .image) == true
        }
        if allAdvertiseImages { return true }

        if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !promises.isEmpty, promises.count == items.count,
           promises.allSatisfy({ receiver in
               !receiver.fileTypes.isEmpty && receiver.fileTypes.allSatisfy {
                   UTType($0)?.conforms(to: .image) == true
               }
           }) { return true }

        return items.count == 1 && remoteImageURL(from: pasteboard) != nil
    }

    /// Returns immediately when the drag was accepted. File promises complete asynchronously.
    @discardableResult
    static func importFiles(
        from pasteboard: NSPasteboard,
        completion: @MainActor @escaping @Sendable (ImportEvent) -> Void
    ) -> Bool {
        let importID = String(UUID().uuidString.prefix(8))
        AppDiagnostics.record("import-start", category: "Import", fields: [
            "import": importID,
            "types": (pasteboard.types ?? []).prefix(32).map { String($0.rawValue.prefix(160)) }.joined(separator: ","),
            "items": String(pasteboard.pasteboardItems?.count ?? 0)])
        let deliver: @MainActor @Sendable (ImportEvent) -> Void = { event in
            switch event {
            case .imported(let urls):
                AppDiagnostics.record("import-completed", category: "Import", fields: ["import": importID, "count": String(urls.count)])
            case .failed:
                AppDiagnostics.record("import-failed", category: "Import", fields: ["import": importID])
            }
            completion(event)
        }
        // Copy pasteboard payloads while the drag owns them; encode and write off the main thread.
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            AppDiagnostics.record("import-file-urls", category: "Import", fields: ["import": importID, "count": String(urls.count)])
            importQueue.addOperation {
                let existing = urls.filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
                Task { @MainActor in
                    deliver(existing.isEmpty
                        ? .failed("拖入的文件已被移动、删除或暂时无法访问。")
                        : .imported(existing))
                }
            }
            return true
        }

        // Chromium can advertise both image bytes and a legacy file promise
        // for the same item. Copy the bytes while its drag still owns them.
        // For multiple items, prefer promises so every file can be delivered.
        let isSingleItem = pasteboard.pasteboardItems?.count == 1
        if isSingleItem, importImage(from: pasteboard, importID: importID, deliver: deliver) {
            return true
        }

        let remoteImage = isSingleItem ? remoteImageURL(from: pasteboard) : nil
        if let promises = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self]
        ) as? [NSFilePromiseReceiver], !promises.isEmpty {
            AppDiagnostics.record("import-file-promises", category: "Import", fields: ["import": importID, "count": String(promises.count)])
            guard let destination = makeImportDirectory() else {
                Task { @MainActor in deliver(.failed("无法创建拖入文件的保存目录。")) }
                return true
            }
            let delivery = FilePromiseDelivery(receivers: promises) { event in
                if case .failed = event, let remoteImage {
                    AppDiagnostics.record("import-promise-fallback", category: "Import", fields: ["import": importID])
                    importRemoteImage(remoteImage, importID: importID, deliver: deliver)
                } else {
                    deliver(event)
                }
            }
            // Legacy browser providers can require the live drag pasteboard.
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
            delivery.start(timeout: remoteImage == nil ? .seconds(60) : .seconds(2))
            return true
        }

        if let remoteImage {
            importRemoteImage(remoteImage, importID: importID, deliver: deliver)
            return true
        }

        if !isSingleItem, importImage(from: pasteboard, importID: importID, deliver: deliver) {
            return true
        }

        if let sourceURL = webURL(from: pasteboard) {
            AppDiagnostics.record("import-web-link", category: "Import", fields: ["import": importID])
            importQueue.addOperation {
                let url = writeWebLocation(sourceURL)
                Task { @MainActor in
                    deliver(url.map { .imported([$0]) } ?? .failed("无法保存拖入的链接。"))
                }
            }
            return true
        }
        AppDiagnostics.record("import-unsupported", category: "Import", fields: ["import": importID])
        return false
    }

    static func remoteImageURL(from pasteboard: NSPasteboard) -> URL? {
        let pageURL = webURL(from: pasteboard)
        for type in [chromiumImageHTML, .html] {
            guard let html = pasteboard.string(forType: type), html.utf16.count <= 256_000,
                  let match = imageSourcePattern.firstMatch(
                    in: html, range: NSRange(html.startIndex..., in: html)
                  ) else { continue }
            for index in 1..<match.numberOfRanges {
                guard let range = Range(match.range(at: index), in: html) else { continue }
                let source = html[range]
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&#38;", with: "&")
                if let url = URL(string: source, relativeTo: pageURL)?.absoluteURL,
                   isRemoteURL(url) { return url }
            }
        }
        if let pageURL,
           let rawType = pasteboard.string(forType: promisedContentType),
           UTType(rawType)?.conforms(to: .image) == true {
            return pageURL
        }
        return nil
    }

    private static func isRemoteURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
        return url.host != nil && url.user == nil && url.password == nil
    }

    private static func importRemoteImage(
        _ url: URL,
        importID: String,
        deliver: @MainActor @escaping @Sendable (ImportEvent) -> Void
    ) {
        AppDiagnostics.record("import-remote-image", category: "Import", fields: ["import": importID])
        Task {
            let result = await Task.detached(priority: .utility) { await downloadImage(url) }.value
            deliver(result)
        }
    }

    nonisolated static func downloadImage(_ url: URL) async -> ImportEvent {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 25
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let failure = ImportEvent.failed("无法获取拖入的网页图片。")
        do {
            let (temporaryFile, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: temporaryFile) }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let fileSize = try temporaryFile.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  fileSize <= 50 * 1_024 * 1_024,
                  let image = CGImageSourceCreateWithURL(temporaryFile as CFURL, nil),
                  CGImageSourceGetCount(image) > 0,
                  CGImageSourceGetStatusAtIndex(image, 0) == .statusComplete,
                  let type = CGImageSourceGetType(image).flatMap({ UTType($0 as String) }),
                  type.conforms(to: .image),
                  let ext = type.preferredFilenameExtension,
                  let directory = makeImportDirectory() else { return failure }
            let output = directory.appendingPathComponent("Dragged Image").appendingPathExtension(ext)
            do {
                try FileManager.default.moveItem(at: temporaryFile, to: output)
                return .imported([output])
            } catch {
                try? FileManager.default.removeItem(at: directory)
                return failure
            }
        } catch {
            return failure
        }
    }

    private static func importImage(
        from pasteboard: NSPasteboard,
        importID: String,
        deliver: @MainActor @escaping @Sendable (ImportEvent) -> Void
    ) -> Bool {
        let advertisedTypes = Set(pasteboard.types ?? [])
        for type in imageDataTypes where advertisedTypes.contains(type) {
            AppDiagnostics.record("import-image-read", category: "Import", fields: ["import": importID, "type": type.rawValue])
            guard let data = pasteboard.data(forType: type), !data.isEmpty else { continue }
            AppDiagnostics.record("import-image-copied", category: "Import", fields: ["import": importID, "bytes": String(data.count)])
            importQueue.addOperation {
                let url = writePNG(data)
                Task { @MainActor in
                    deliver(url.map { .imported([$0]) } ?? .failed("无法读取或保存拖入的图片。"))
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
    private var receivers: [NSFilePromiseReceiver]
    private var remaining = 0
    private var urls: [URL] = []
    private var failure: String?
    private var isFinished = false
    private let completion: @MainActor @Sendable (FileDropImporter.ImportEvent) -> Void
    private var timeoutTask: Task<Void, Never>?

    init(
        receivers: [NSFilePromiseReceiver],
        completion: @MainActor @escaping @Sendable (FileDropImporter.ImportEvent) -> Void
    ) {
        self.receivers = receivers
        self.completion = completion
    }

    func start(timeout: Duration) {
        // AppKit populates fileNames when receivePromisedFiles is called.
        remaining = receivers.reduce(0) { $0 + max(1, $1.fileNames.count) }
        timeoutTask = Task { @MainActor in
            do { try await Task.sleep(for: timeout) } catch { return }
            finish()
        }
    }

    func receive(_ event: FileDropImporter.ImportEvent) {
        guard !isFinished else { return }
        switch event {
        case .imported(let delivered): urls.append(contentsOf: delivered)
        case .failed(let message): failure = message
        }
        remaining -= 1
        if remaining <= 0 { finish() }
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        receivers.removeAll()
        if !urls.isEmpty {
            completion(.imported(urls))
        } else {
            completion(.failed(failure ?? "提供文件的应用长时间没有完成传输，请重试拖入。"))
        }
    }
}
