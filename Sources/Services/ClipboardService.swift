import AppKit
import Foundation

@MainActor
enum ClipboardService {
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "DropPoint.clipboard-materialization"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    static func fileURLs(from pasteboard: NSPasteboard = .general) async -> [URL] {
        let urls = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Snapshot data before suspension: another application can replace the clipboard.
        let imageData = NSImage.imageTypes.lazy.compactMap {
            pasteboard.data(forType: NSPasteboard.PasteboardType($0))
        }.first
        return await withCheckedContinuation { continuation in
            queue.addOperation {
                continuation.resume(returning: materialize(urls: urls, text: text, imageData: imageData))
            }
        }
    }

    nonisolated private static func materialize(urls: [URL], text: String?, imageData: Data?) -> [URL] {
        let existing = urls.filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
        if !existing.isEmpty { return unique(existing) }
        var results: [URL] = []
        if let text, !text.isEmpty {
            let paths = text.components(separatedBy: .newlines).compactMap { line -> URL? in
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let url = value.hasPrefix("file://") ? URL(string: value)
                    : value.hasPrefix("/") ? URL(fileURLWithPath: value) : nil
                guard let url, url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
                return url
            }
            if !paths.isEmpty { return unique(paths) }
            if let source = URL(string: text), ["http", "https"].contains(source.scheme?.lowercased() ?? ""),
               let url = FileDropImporter.writeWebLocation(source) {
                results.append(url)
            } else if text.count <= 2_800, let url = writeTemporary(data: Data(text.utf8), extension: "txt") {
                results.append(url)
            }
        }
        if let imageData, let url = FileDropImporter.writePNG(imageData) { results.append(url) }
        return unique(results)
    }

    nonisolated private static func writeTemporary(data: Data, extension fileExtension: String) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("droppoint-clip-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch { return nil }
    }

    nonisolated private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
