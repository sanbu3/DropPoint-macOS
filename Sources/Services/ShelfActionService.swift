import AppKit
import PDFKit
import UniformTypeIdentifiers

enum ImagePDFComposer {
    static func makeDocument(from imageURLs: [URL]) -> PDFDocument {
        let document = PDFDocument()
        for url in imageURLs {
            guard let image = NSImage(contentsOf: url),
                  let page = PDFPage(image: image) else { continue }
            document.insert(page, at: document.pageCount)
        }
        return document
    }
}

private enum ImageCompressionDestination: Sendable {
    case file(URL)
    case directory(URL)
}

private struct ImageCompressionBatchOutcome: Sendable {
    let outputs: [URL]
    let errors: [String]
    let targetMisses: [String]
    let originalByteCount: Int
    let compressedByteCount: Int
}

@MainActor
enum ShelfActionService {
    private struct TransferOutcome: Sendable {
        let succeeded: Set<URL>
        let errors: [String]
    }

    static func perform(
        _ action: ShelfAction,
        urls: [URL],
        completion: (@MainActor @Sendable (Set<URL>) -> Void)? = nil
    ) {
        let fileURLs = urls.map(\.standardizedFileURL)
        guard !fileURLs.isEmpty else { return }

        switch action {
        case .airDrop:
            completion?(share(using: .sendViaAirDrop, urls: fileURLs) ? Set(fileURLs) : [])
        case .messages:
            completion?(share(using: .composeMessage, urls: fileURLs) ? Set(fileURLs) : [])
        case .mail:
            completion?(share(using: .composeEmail, urls: fileURLs) ? Set(fileURLs) : [])
        case .open:
            fileURLs.forEach { NSWorkspace.shared.open($0) }
            completion?(Set(fileURLs))
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting(fileURLs)
            completion?(Set(fileURLs))
        case .copyPaths:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                fileURLs.map(\.path).joined(separator: "\n"),
                forType: .string
            )
            completion?(Set(fileURLs))
        case .compressImages:
            compressImages(from: fileURLs, completion: completion)
        case .createPDF:
            createPDF(from: fileURLs)
        case .archive:
            createArchive(from: fileURLs)
        case .copyTo:
            chooseAndTransfer(fileURLs, moving: false, completion: completion)
        case .moveTo:
            chooseAndTransfer(fileURLs, moving: true, completion: completion)
        case .trash:
            NSWorkspace.shared.recycle(fileURLs) { recycled, error in
                Task { @MainActor in
                    if let error {
                        showError("无法移到废纸篓", error.localizedDescription)
                    }
                    completion?(Set(recycled.keys.map(\.standardizedFileURL)))
                }
            }
        }
    }

    static func perform(
        _ action: CustomShelfAction,
        urls: [URL],
        completion: (@MainActor @Sendable (Set<URL>) -> Void)? = nil
    ) {
        let destination = URL(fileURLWithPath: action.destinationPath)
        Task {
            let available = await Task.detached(priority: .utility) {
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }.value
            guard available else {
                showError("自定义操作不可用", "目标文件夹已被移动或删除。")
                completion?([])
                return
            }
            transfer(
                urls.map(\.standardizedFileURL),
                moving: action.kind == .moveTo,
                destination: destination,
                completion: completion
            )
        }
    }

    private static func share(using name: NSSharingService.Name, urls: [URL]) -> Bool {
        guard let service = NSSharingService(named: name) else {
            showError("分享服务不可用", "当前 Mac 没有提供此分享方式。")
            return false
        }
        service.perform(withItems: urls)
        return true
    }

    private static func chooseAndTransfer(
        _ urls: [URL],
        moving: Bool,
        completion: (@MainActor @Sendable (Set<URL>) -> Void)?
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
        completion: (@MainActor @Sendable (Set<URL>) -> Void)?
    ) {
        Task {
            let outcome = await Task.detached(priority: .utility) { () -> TransferOutcome in
                let fileManager = FileManager.default
                var succeeded = Set<URL>()
                var errors: [String] = []
                for source in urls {
                    do {
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
                        succeeded.insert(source.standardizedFileURL)
                    } catch {
                        errors.append("\(source.lastPathComponent)：\(error.localizedDescription)")
                    }
                }
                return TransferOutcome(succeeded: succeeded, errors: errors)
            }.value
            if !outcome.errors.isEmpty {
                showError(
                    moving ? "部分文件移动失败" : "部分文件复制失败",
                    outcome.errors.joined(separator: "\n")
                )
            }
            completion?(outcome.succeeded)
        }
    }

    private static func compressImages(
        from urls: [URL],
        completion: (@MainActor @Sendable (Set<URL>) -> Void)?
    ) {
        Task {
            let imageURLs = await Task.detached(priority: .utility) { imageFiles(in: urls) }.value
            guard !imageURLs.isEmpty else {
                showError("无法压缩图片", "请选择至少一张可读取的图片。")
                completion?([])
                return
            }
            guard let targetBytes = chooseCompressionTarget(),
                  let destination = chooseCompressionDestination(for: imageURLs) else {
                return
            }

            let outcome = await Task.detached(priority: .utility) {
                performCompressionBatch(
                    imageURLs,
                    targetBytes: targetBytes,
                    destination: destination
                )
            }.value
            showCompressionResult(outcome, targetBytes: targetBytes)
            completion?(Set(outcome.outputs.map(\.standardizedFileURL)))
        }
    }

    private static func chooseCompressionTarget() -> Int? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "压缩图片大小"
        alert.informativeText = "设置每张图片的最大目标大小。输出为 JPEG，透明区域会填充为白色，原图不会被修改。"
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")

        let sizeField = NSTextField(string: "800")
        sizeField.alignment = .right
        sizeField.placeholderString = "800"
        sizeField.frame.size.width = 96

        let unitPicker = NSPopUpButton()
        unitPicker.addItems(withTitles: ["KB", "MB"])
        unitPicker.selectItem(at: 0)

        let row = NSStackView(views: [
            NSTextField(labelWithString: "每张图片最大"),
            sizeField,
            unitPicker,
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.frame = NSRect(x: 0, y: 0, width: 300, height: 28)
        alert.accessoryView = row

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = sizeField.doubleValue
        let multiplier = unitPicker.indexOfSelectedItem == 1 ? 1_024.0 * 1_024.0 : 1_024.0
        guard let bytes = compressionTargetBytes(value: value, multiplier: multiplier) else {
            showError("目标大小无效", "请输入至少 10 KB 的目标大小。")
            return nil
        }
        return bytes
    }

    nonisolated static func compressionTargetBytes(value: Double, multiplier: Double) -> Int? {
        let bytes = value * multiplier
        guard value.isFinite, multiplier.isFinite, value > 0, multiplier > 0,
              bytes.isFinite, bytes >= 10 * 1_024, bytes < Double(Int.max) else { return nil }
        return Int(bytes)
    }

    private static func chooseCompressionDestination(
        for imageURLs: [URL]
    ) -> ImageCompressionDestination? {
        if imageURLs.count == 1, let source = imageURLs.first {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.jpeg]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = compressedFileName(for: source)
            panel.message = "选择压缩图片的保存位置"
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            return .file(url)
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "选择压缩图片的输出文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return .directory(url)
    }

    nonisolated private static func performCompressionBatch(
        _ imageURLs: [URL],
        targetBytes: Int,
        destination: ImageCompressionDestination
    ) -> ImageCompressionBatchOutcome {
        let fileManager = FileManager.default
        var outputs: [URL] = []
        var errors: [String] = []
        var targetMisses: [String] = []
        var originalByteCount = 0
        var compressedByteCount = 0

        for (index, source) in imageURLs.enumerated() {
            let output: URL
            switch destination {
            case .file(let url):
                guard index == 0 else { continue }
                output = url
            case .directory(let directory):
                output = uniqueDestination(
                    named: compressedFileName(for: source),
                    in: directory,
                    fileManager: fileManager
                )
            }

            do {
                let result = try ImageCompressionService.compressFile(
                    at: source,
                    to: output,
                    targetBytes: targetBytes
                )
                outputs.append(output)
                originalByteCount += result.originalByteCount
                compressedByteCount += result.data.count
                if !result.didMeetTarget { targetMisses.append(source.lastPathComponent) }
            } catch {
                errors.append("\(source.lastPathComponent)：\(error.localizedDescription)")
            }
        }

        return ImageCompressionBatchOutcome(
            outputs: outputs,
            errors: errors,
            targetMisses: targetMisses,
            originalByteCount: originalByteCount,
            compressedByteCount: compressedByteCount
        )
    }

    private static func showCompressionResult(
        _ outcome: ImageCompressionBatchOutcome,
        targetBytes: Int
    ) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        guard !outcome.outputs.isEmpty else {
            showError("图片压缩失败", outcome.errors.joined(separator: "\n"))
            return
        }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let original = formatter.string(fromByteCount: Int64(outcome.originalByteCount))
        let compressed = formatter.string(fromByteCount: Int64(outcome.compressedByteCount))
        let target = formatter.string(fromByteCount: Int64(targetBytes))
        var details = "已生成 \(outcome.outputs.count) 张图片：\(original) → \(compressed)；每张目标不超过 \(target)。"
        if !outcome.targetMisses.isEmpty {
            details += "\n\n以下图片已压到安全下限，但仍略高于目标：\n"
                + outcome.targetMisses.joined(separator: "\n")
        }
        if !outcome.errors.isEmpty {
            details += "\n\n未能处理：\n" + outcome.errors.joined(separator: "\n")
        }

        let alert = NSAlert()
        alert.alertStyle = outcome.errors.isEmpty ? .informational : .warning
        alert.messageText = outcome.errors.isEmpty ? "图片压缩完成" : "部分图片压缩完成"
        alert.informativeText = details
        alert.addButton(withTitle: "在 Finder 中显示")
        alert.addButton(withTitle: "好")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting(outcome.outputs)
        }
    }

    nonisolated private static func imageFiles(in urls: [URL]) -> [URL] {
        urls.filter {
            (try? $0.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .image) == true
        }
    }

    nonisolated private static func compressedFileName(for source: URL) -> String {
        "\(source.deletingPathExtension().lastPathComponent)-compressed.jpg"
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
                    if let timeoutError = try runProcess(process, timeout: 300) { return timeoutError }
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

    /// Runs on a utility worker. A stalled archiver cannot leave an operation waiting forever.
    nonisolated static func runProcess(_ process: Process, timeout: TimeInterval) throws -> String? {
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        try process.run()
        guard terminated.wait(timeout: .now() + timeout) == .timedOut else { return nil }
        process.terminate()
        if terminated.wait(timeout: .now() + 2) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = terminated.wait(timeout: .now() + 2)
        }
        return "压缩进程长时间没有完成，已停止。请检查目标位置和文件是否可访问后重试。"
    }

    private static func createPDF(from urls: [URL]) {
        Task {
            let imageURLs = await Task.detached(priority: .utility) { imageFiles(in: urls) }.value
            guard !imageURLs.isEmpty else {
                showError("无法创建 PDF", "请选择至少一张图片。")
                return
            }

            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = "DropPoint 图片.pdf"
            panel.message = "选择 PDF 保存位置"
            guard panel.runModal() == .OK, let destination = panel.url else { return }

            let errorMessage = await Task.detached(priority: .utility) { () -> String? in
                let document = ImagePDFComposer.makeDocument(from: imageURLs)
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
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
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
