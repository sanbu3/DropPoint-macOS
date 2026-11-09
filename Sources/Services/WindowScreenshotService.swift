import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit

enum WindowScreenshotError: LocalizedError {
    case noWindow
    case missingWindowID
    case captureFailed
    case imageWriteFailed

    var errorDescription: String? {
        switch self {
        case .noWindow: "没有找到可截取的窗口。"
        case .missingWindowID: "目标窗口已关闭或暂时不可截取。"
        case .captureFailed: "截取窗口失败。"
        case .imageWriteFailed: "无法保存截图。"
        }
    }
}

struct CapturedWindow {
    let image: CGImage
    /// AppKit screen coordinates (origin bottom-left of the main display).
    let frame: NSRect
    let appName: String
    let windowTitle: String?
    let windowID: CGWindowID
}

@MainActor
enum WindowScreenshotService {
    private struct TargetWindow {
        let id: CGWindowID
        let ownerPID: pid_t
        let ownerName: String
        let title: String?
        let frame: CGRect
    }

    static func captureNearestWindow() async throws -> CapturedWindow {
        let mainScreen = NSScreen.screens.first ?? NSScreen.main
        let mainHeight = mainScreen?.frame.maxY ?? 0
        let cursor = NSEvent.mouseLocation
        let cursorInCG = CGPoint(x: cursor.x, y: mainHeight - cursor.y)
        let ownPID = ProcessInfo.processInfo.processIdentifier

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let rawWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        let targets = rawWindows.compactMap { info -> TargetWindow? in
            guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                  let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 100, rect.height >= 80 else { return nil }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            guard !owner.isEmpty,
                  !["Window Server", "Dock", "Control Center", "Notification Center", "Spotlight"].contains(owner)
            else { return nil }
            let title = info[kCGWindowName as String] as? String
            return TargetWindow(
                id: windowID,
                ownerPID: pid,
                ownerName: owner,
                title: title?.isEmpty == true ? nil : title,
                frame: rect
            )
        }

        guard let target = targets.first(where: { $0.frame.contains(cursorInCG) }) ?? targets.first else {
            throw WindowScreenshotError.noWindow
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let window = content.windows.first(where: { $0.windowID == target.id }) else {
            throw WindowScreenshotError.missingWindowID
        }

        let scale = NSScreen.screens
            .first(where: { $0.frame.contains(NSPoint(x: target.frame.midX, y: mainHeight - target.frame.midY)) })?
            .backingScaleFactor ?? mainScreen?.backingScaleFactor ?? 2
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(target.frame.width * scale))
        configuration.height = max(1, Int(target.frame.height * scale))
        configuration.scalesToFit = false
        configuration.showsCursor = false
        // SCStreamConfiguration.backgroundColor is `assign` in Apple's SDK:
        // a temporary CGColor may die before ScreenCaptureKit copies it.
        // The framework's default is already clear; leave it unset.

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await captureImage(filter: filter, configuration: configuration)
        let appKitFrame = NSRect(
            x: target.frame.minX,
            y: mainHeight - target.frame.maxY,
            width: target.frame.width,
            height: target.frame.height
        )
        return CapturedWindow(
            image: image,
            frame: appKitFrame,
            appName: target.ownerName,
            windowTitle: target.title,
            windowID: target.id
        )
    }

    static func savePNG(
        _ image: CGImage,
        appName: String,
        windowTitle: String?,
        timestamp: Date = Date()
    ) throws -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let directory = base
            .appendingPathComponent("DropPoint", isDirectory: true)
            .appendingPathComponent("Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let timestamp = formatter.string(from: timestamp)
        let rawName = windowTitle ?? "\(appName) 窗口"
        let cleaned = rawName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String(cleaned.prefix(64))
        let url = directory.appendingPathComponent("\(name) 截图 \(timestamp) \(UUID().uuidString).png")

        guard let representation = NSBitmapImageRep(cgImage: image)
            .representation(using: .png, properties: [:]) else {
            throw WindowScreenshotError.imageWriteFailed
        }
        do {
            try representation.write(to: url, options: .withoutOverwriting)
        } catch {
            throw WindowScreenshotError.imageWriteFailed
        }
        return url
    }

    private static func captureImage(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: WindowScreenshotError.captureFailed)
                }
            }
        }
    }
}
