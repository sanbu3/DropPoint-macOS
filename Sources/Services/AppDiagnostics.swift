import AppKit
import Foundation
import OSLog

/// Always on in Debug and Release. Records lifecycle metadata, never file
/// contents, pasteboard payloads, typed characters, or imported file paths.
enum AppDiagnostics {
    static let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Logs/DropPoint", isDirectory: true)
    static let sessionID = UUID().uuidString
    static let writer = DiagnosticLogWriter(directory: directory)
    private static let logger = Logger(subsystem: "io.github.sanbu3.droppoint.macos", category: "Diagnostics")
    private static let metadata: [String: String] = {
        let info = Bundle.main.infoDictionary ?? [:]
        let provenance = Bundle.main.url(forResource: "ReleaseProvenance", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        return ["version": info["CFBundleShortVersionString"] as? String ?? "unknown",
                "build": info["CFBundleVersion"] as? String ?? "unknown",
                "commit": provenance?["commit"] ?? "development",
                "applicationPath": Bundle.main.bundlePath,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "configuration": configuration]
    }()
    private static var configuration: String {
        #if DEBUG
        "Debug"
        #else
        "Release"
        #endif
    }

    static func record(_ event: String, category: String = "Lifecycle", fields: [String: String] = [:]) {
        var entry: [String: Any] = ["timestamp": Date().timeIntervalSince1970,
            "uptime": ProcessInfo.processInfo.systemUptime, "session": sessionID,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "mainThread": Thread.isMainThread, "event": event, "category": category,
            "context": metadata, "fields": fields]
        entry["schema"] = 1
        guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        writer.append(data)
        logger.notice("\(category, privacy: .public) \(event, privacy: .public) session=\(sessionID, privacy: .public)")
    }

    static func error(_ event: String, error: Error, category: String) {
        let e = error as NSError
        record(event, category: category, fields: ["errorDomain": e.domain, "errorCode": String(e.code)])
    }

    @MainActor static func openFolder() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    @MainActor static func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "DropPoint-diagnostics-\(Int(Date().timeIntervalSince1970)).zip"
        panel.title = "导出 DropPoint 诊断信息"
        panel.message = "包含本地运行日志和本应用的崩溃报告；导出文件保存在你选择的位置。"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            record("diagnostics-export-requested")
            Task.detached(priority: .utility) {
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent("DropPoint-diagnostics-\(UUID())")
                defer { try? FileManager.default.removeItem(at: temp) }
                do {
                    try writer.snapshot(to: temp.appendingPathComponent("Logs"))
                    let reports = temp.appendingPathComponent("CrashReports")
                    try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
                    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
                    let files = [root, root.appendingPathComponent("Retired")].flatMap {
                        (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                    }.filter { $0.lastPathComponent.hasPrefix("DropPoint-") && $0.pathExtension == "ips" }
                    for file in files.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).prefix(8) {
                        try FileManager.default.copyItem(at: file, to: reports.appendingPathComponent(file.lastPathComponent))
                    }
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    process.arguments = ["-c", "-k", "--keepParent", temp.path, destination.path]
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
                    record("diagnostics-export-completed")
                    await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
                } catch {
                    AppDiagnostics.error("diagnostics-export-failed", error: error, category: "Diagnostics")
                    await MainActor.run {
                        let alert = NSAlert()
                        alert.messageText = "诊断信息导出失败"
                        alert.informativeText = "请尝试其他保存位置，也可以直接打开日志文件夹。"
                        alert.runModal()
                    }
                }
            }
        }
    }
}

/// Mutable state is confined to one queue. Per-process files prevent a debug
/// build and an installed build from corrupting each other's journals.
final class DiagnosticLogWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.sanbu3.droppoint.diagnostic-log", qos: .utility)
    let directory: URL
    private let maxBytes: Int
    private let retainedFiles: Int
    private let prefix: String
    private var segment = 0
    private var bytes = 0
    private var reportedFailure = false

    init(directory: URL, maxBytes: Int = 2_000_000, retainedFiles: Int = 12) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.retainedFiles = retainedFiles
        prefix = "events-\(Int(Date().timeIntervalSince1970))-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))"
    }
    private var url: URL { directory.appendingPathComponent("\(prefix)-\(segment).jsonl") }

    func append(_ data: Data) {
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if bytes > 0 && bytes + data.count > maxBytes { segment += 1; bytes = 0 }
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                    try prune()
                }
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                try file.seekToEnd()
                try file.write(contentsOf: data)
                bytes += data.count
            } catch {
                if !reportedFailure { NSLog("DropPoint diagnostic journal unavailable: %@", (error as NSError).domain) }
                reportedFailure = true
            }
        }
    }
    func flush() { queue.sync {} }
    func snapshot(to destination: URL) throws {
        try queue.sync {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "jsonl" {
                try FileManager.default.copyItem(at: file, to: destination.appendingPathComponent(file.lastPathComponent))
            }
        }
    }
    private func prune() throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
        for file in files.dropFirst(retainedFiles) where file != url { try? FileManager.default.removeItem(at: file) }
    }
}
