import AppKit
import Foundation

@MainActor
enum FileDropImporter {
    private static let legacyFileNames = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    static var readableTypes: [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = [.fileURL, legacyFileNames, .png, .tiff]
        for rawType in NSFilePromiseReceiver.readableDraggedTypes {
            types.append(NSPasteboard.PasteboardType(rawType))
        }
        return types
    }

    static func canImport(from pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) { return true }
        if pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self]) { return true }
        return pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    /// Returns immediately when the drag was accepted. File promises complete asynchronously.
    @discardableResult
    static func importFiles(
        from pasteboard: NSPasteboard,
        completion: @MainActor @escaping @Sendable ([URL]) -> Void
    ) -> Bool {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            let existing = existingFiles(in: urls)
            if !existing.isEmpty {
                completion(existing)
                return true
            }
        }

        if let promises = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self]
        ) as? [NSFilePromiseReceiver], !promises.isEmpty,
           let destination = makeImportDirectory() {
            for promise in promises {
                promise.receivePromisedFiles(
                    atDestination: destination,
                    options: [:],
                    operationQueue: .main
                ) { url, _ in
                    Task { @MainActor in completion([url]) }
                }
            }
            return true
        }

        if let image = NSImage(pasteboard: pasteboard),
           let url = writePNG(image) {
            completion([url])
            return true
        }
        return false
    }

    private static func existingFiles(in urls: [URL]) -> [URL] {
        urls.filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func makeImportDirectory() -> URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let directory = support
            .appendingPathComponent("DropPoint", isDirectory: true)
            .appendingPathComponent("Imported Files", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            return directory
        } catch {
            return nil
        }
    }

    private static func writePNG(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]),
              let directory = makeImportDirectory() else { return nil }
        let url = directory.appendingPathComponent("Dragged Image.png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
