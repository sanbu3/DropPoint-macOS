import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Hashable {
    let url: URL
    let image: NSImage
    let isThumbnail: Bool

    var id: String { url.standardizedFileURL.path }
    var name: String { url.lastPathComponent }

    var typeLabel: String {
        let value = url.pathExtension.isEmpty ? "文件" : url.pathExtension.uppercased()
        return String(value.prefix(8))
    }

    static func == (lhs: ShelfItem, rhs: ShelfItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    @MainActor
    static func make(url: URL) -> ShelfItem? {
        let fileURL = url.standardizedFileURL
        guard fileURL.isFileURL else { return nil }
        // A type icon gives immediate feedback without asking Finder/file providers for an icon.
        let type = UTType(filenameExtension: fileURL.pathExtension) ?? .data
        let workspaceIcon = NSWorkspace.shared.icon(for: type)
        let image = (workspaceIcon.copy() as? NSImage) ?? workspaceIcon
        image.size = NSSize(width: 76, height: 76)
        return ShelfItem(url: fileURL, image: image, isThumbnail: false)
    }

    private static let thumbnailQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "DropPoint.thumbnail-decoding"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    @MainActor
    static func loadPreview(url: URL, maxPixelSize: Int = 152) async -> ShelfItem? {
        let fileURL = url.standardizedFileURL
        guard !Task.isCancelled else { return nil }
        let cancellation = ThumbnailCancellation()
        let preview: FilePreview? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                thumbnailQueue.addOperation {
                    guard !cancellation.isCancelled,
                          FileManager.default.fileExists(atPath: fileURL.path) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let values = try? fileURL.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey])
                    let type = values?.isDirectory == true ? UTType.folder : values?.contentType ?? .data
                    let image: CGImage? = type.conforms(to: .image) && !cancellation.isCancelled
                        ? autoreleasepool { downsampledImage(url: fileURL, maxPixelSize: maxPixelSize) }
                        : nil
                    continuation.resume(returning: FilePreview(type: type, image: image))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        guard !Task.isCancelled, let preview else { return nil }
        let image: NSImage
        if let cgImage = preview.image {
            image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } else {
            let icon = NSWorkspace.shared.icon(for: preview.type)
            image = (icon.copy() as? NSImage) ?? icon
            image.size = NSSize(width: 76, height: 76)
        }
        return ShelfItem(url: fileURL, image: image, isThumbnail: preview.image != nil)
    }

    private struct FilePreview: Sendable {
        let type: UTType
        let image: CGImage?
    }

    func replacingImage(_ image: NSImage, isThumbnail: Bool) -> ShelfItem {
        ShelfItem(url: url, image: image, isThumbnail: isThumbnail)
    }

    nonisolated private static func downsampledImage(
        url: URL,
        maxPixelSize: Int
    ) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// A cancelled queued decode must still resume its continuation without touching the file.
private final class ThumbnailCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }
}
