import AppKit
import Foundation

enum ClipboardService {
    static func fileURLs(from pasteboard: NSPasteboard = .general) -> [URL] {
        if let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL] {
            let urls = objects
                .map { $0 as URL }
                .filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
            if !urls.isEmpty { return unique(urls) }
        }

        var results: [URL] = []
        if let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            let paths = text.components(separatedBy: .newlines).compactMap { line -> URL? in
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if value.hasPrefix("file://"), let url = URL(string: value),
                   FileManager.default.fileExists(atPath: url.path) { return url }
                if value.hasPrefix("/"), FileManager.default.fileExists(atPath: value) {
                    return URL(fileURLWithPath: value)
                }
                return nil
            }
            if !paths.isEmpty { return unique(paths) }

            if text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://"),
               let url = writeWebloc(urlString: text) {
                results.append(url)
            } else if text.count <= 2_800,
                      let url = writeTemporary(data: Data(text.utf8), extension: "txt") {
                results.append(url)
            }
        }

        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]),
           let url = writeTemporary(data: png, extension: "png") {
            results.append(url)
        }
        return unique(results)
    }

    private static func writeWebloc(urlString: String) -> URL? {
        guard let url = URL(string: urlString) else { return nil }
        let plist: [String: Any] = ["URL": url.absoluteString]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return nil }
        return writeTemporary(data: data, extension: "webloc")
    }

    private static func writeTemporary(data: Data, extension fileExtension: String) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("droppoint-clip-\(Int(Date().timeIntervalSince1970 * 1_000))")
            .appendingPathExtension(fileExtension)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
