import AppKit
import PDFKit
import UniformTypeIdentifiers

@MainActor
enum ShelfActionService {
    static func perform(
        _ action: ShelfAction,
        urls: [URL],
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        let fileURLs = urls.map(\.standardizedFileURL)
        guard !fileURLs.isEmpty else { return }

        switch action {
        case .airDrop:
            share(using: .sendViaAirDrop, urls: fileURLs)
            completion?(true)
        case .messages:
            share(using: .composeMessage, urls: fileURLs)
            completion?(true)
        case .mail:
            share(using: .composeEmail, urls: fileURLs)
            completion?(true)
        case .open:
            fileURLs.forEach { NSWorkspace.shared.open($0) }
            completion?(true)
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting(fileURLs)
            completion?(true)
        case .copyPaths:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                fileURLs.map(\.path).joined(separator: "\n"),
                forType: .string
            )
            completion?(true)
        case .createPDF:
            createPDF(from: fileURLs)
        case .archive:
            createArchive(from: fileURLs)
        case .copyTo:
            chooseAndTransfer(fileURLs, moving: false, completion: completion)
        case .moveTo:
            chooseAndTransfer(fileURLs, moving: true, completion: completion)
        case .trash:
            NSWorkspace.shared.recycle(fileURLs) { _, error in
                Task { @MainActor in
                    if let error {
                        showError("无法移到废纸篓", error.localizedDescription)
                    }
                    completion?(error == nil)
                }
            }
        }
    }

    static func perform(
        _ action: CustomShelfAction,
        urls: [URL],
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        let destination = URL(fileURLWithPath: action.destinationPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: destination.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            showError("自定义操作不可用", "目标文件夹已被移动或删除。")
            completion?(false)
            return
        }
        transfer(
            urls.map(\.standardizedFileURL),
            moving: action.kind == .moveTo,
            destination: destination,
            completion: completion
        )
    }

    private static func share(using name: NSSharingService.Name, urls: [URL]) {
        guard let service = NSSharingService(named: name) else {
            showError("分享服务不可用", "当前 Mac 没有提供此分享方式。")
            return
        }
        service.perform(withItems: urls)
    }

    private static func chooseAndTransfer(
        _ urls: [URL],
        moving: Bool,
        completion: (@MainActor @Sendable (Bool) -> Void)?
    ) {
        guard let destination = chooseDirectory(
            message: moving ? "选择文件移动目标" : "选择文件复制目标"
        ) else { return }

        transfer(
            urls,
            moving: moving,
            destination: destination,
            completion: completion
        )
    }

    private static func transfer(
        _ urls: [URL],
        moving: Bool,
        destination: URL,
        completion: (@MainActor @Sendable (Bool) -> Void)?
    ) {
        Task {
            let errorMessage = await Task.detached(priority: .utility) { () -> String? in
                do {
                    let fileManager = FileManager.default
                    for source in urls {
                        let target = uniqueDestination(
                            named: source.lastPathComponent,
                            in: destination,
                            fileManager: fileManager
                        )
                        if moving {
                            try fileManager.moveItem(at: source, to: target)
                        } else {
                            try fileManager.copyItem(at: source, to: target)
                        }
                    }
                    return nil as String?
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let errorMessage {
                showError(moving ? "移动失败" : "复制失败", errorMessage)
            }
            completion?(errorMessage == nil)
        }
    }

    private static func createArchive(from urls: [URL]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = urls.count == 1
            ? "\(urls[0].deletingPathExtension().lastPathComponent).zip"
            : "DropPoint 文件.zip"
        panel.message = "选择 ZIP 归档保存位置"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        Task {
            let errorMessage = await Task.detached(priority: .utility) { () -> String? in
                let fileManager = FileManager.default
                let staging = fileManager.temporaryDirectory
                    .appendingPathComponent("DropPoint-Archive-\(UUID().uuidString)")
                do {
                    try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
                    defer { try? fileManager.removeItem(at: staging) }
                    for source in urls {
                        let target = uniqueDestination(
                            named: source.lastPathComponent,
                            in: staging,
                            fileManager: fileManager
                        )
                        try fileManager.copyItem(at: source, to: target)
                    }

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    process.arguments = [
                        "-c", "-k", "--sequesterRsrc",
                        staging.path,
                        destination.path,
                    ]
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        return "ditto 返回错误代码 \(process.terminationStatus)"
                    }
                    return nil as String?
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let errorMessage { showError("创建 ZIP 失败", errorMessage) }
        }
    }

    private static func createPDF(from urls: [URL]) {
        let imageURLs = urls.filter {
            guard let type = try? $0.resourceValues(forKeys: [.contentTypeKey]).contentType else {
                return false
            }
            return type.conforms(to: .image)
        }
        guard !imageURLs.isEmpty else {
            showError("无法创建 PDF", "请选择至少一张图片。")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "DropPoint 图片.pdf"
        panel.message = "选择 PDF 保存位置"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        Task {
            let errorMessage = await Task.detached(priority: .utility) { () -> String? in
                let document = PDFDocument()
                for (index, url) in imageURLs.enumerated() {
                    guard let image = NSImage(contentsOf: url),
                          let page = PDFPage(image: image) else { continue }
                    document.insert(page, at: index)
                }
                guard document.pageCount > 0 else { return "没有可写入的图片" }
                return document.write(to: destination) ? nil : "PDF 写入失败"
            }.value
            if let errorMessage { showError("创建 PDF 失败", errorMessage) }
        }
    }

    private static func chooseDirectory(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    nonisolated private static func uniqueDestination(
        named name: String,
        in directory: URL,
        fileManager: FileManager
    ) -> URL {
        var destination = directory.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: destination.path) else { return destination }

        let source = URL(fileURLWithPath: name)
        let base = source.deletingPathExtension().lastPathComponent
        let pathExtension = source.pathExtension
        var counter = 2
        repeat {
            let candidateName = pathExtension.isEmpty
                ? "\(base) \(counter)"
                : "\(base) \(counter).\(pathExtension)"
            destination = directory.appendingPathComponent(candidateName)
            counter += 1
        } while fileManager.fileExists(atPath: destination.path)
        return destination
    }

    private static func showError(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
