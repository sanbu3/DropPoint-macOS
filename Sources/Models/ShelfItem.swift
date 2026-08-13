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
        guard fileURL.isFileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let workspaceIcon = NSWorkspace.shared.icon(forFile: fileURL.path)
        let image = (workspaceIcon.copy() as? NSImage) ?? workspaceIcon
        image.size = NSSize(width: 76, height: 76)
        return ShelfItem(url: fileURL, image: image, isThumbnail: false)
    }

    @MainActor
    static func thumbnail(url: URL, maxPixelSize: Int = 152) async -> NSImage? {
        let fileURL = url.standardizedFileURL
        let cgImage = await Task.detached(priority: .utility) {
            downsampledImage(url: fileURL, maxPixelSize: maxPixelSize)
        }.value
        guard let cgImage else { return nil }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
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

enum ShelfPresentation: Equatable {
    case standard
    case tray
}
