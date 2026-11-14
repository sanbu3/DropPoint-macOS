import Foundation

enum ShelfAction: String, SettingOption {
    case airDrop
    case messages
    case mail
    case open
    case reveal
    case copyPaths
    case compressImages
    case resizeImages
    case createPDF
    case archive
    case copyTo
    case moveTo
    case groupInFolder
    case trash

    static let defaultActions: [ShelfAction] = [
        .airDrop,
        .messages,
        .mail,
        .open,
        .reveal,
        .copyPaths,
        .groupInFolder,
        .compressImages,
        .createPDF,
        .archive,
    ]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .airDrop: "AirDrop"
        case .messages: "信息"
        case .mail: "邮件"
        case .open: "打开文件"
        case .reveal: "在 Finder 中显示"
        case .copyPaths: "复制路径"
        case .compressImages: "压缩图片大小…"
        case .resizeImages: "调整图片尺寸…"
        case .createPDF: "创建 PDF"
        case .archive: "压缩为 ZIP"
        case .copyTo: "将文件复制到…"
        case .moveTo: "将文件移动到…"
        case .groupInFolder: "新建文件夹并移入…"
        case .trash: "移到废纸篓"
        }
    }

    var systemImage: String {
        switch self {
        case .airDrop: "airplayaudio"
        case .messages: "message"
        case .mail: "envelope"
        case .open: "arrow.up.forward.app"
        case .reveal: "folder"
        case .copyPaths: "doc.on.doc"
        case .compressImages: "arrow.down.right.and.arrow.up.left"
        case .resizeImages: "ruler"
        case .createPDF: "document.badge.plus"
        case .archive: "archivebox"
        case .copyTo: "doc.on.doc.fill"
        case .moveTo: "folder.badge.plus"
        case .groupInFolder: "folder.badge.plus"
        case .trash: "trash"
        }
    }

    var detail: String {
        switch self {
        case .airDrop, .messages, .mail: "使用 macOS 系统分享服务"
        case .open: "使用默认应用打开所选内容"
        case .reveal: "在 Finder 中定位所选内容"
        case .copyPaths: "把 POSIX 路径复制到剪贴板"
        case .compressImages: "按目标文件大小输出 JPEG，不覆盖原图"
        case .resizeImages: "按最长边像素等比缩小，输出 PNG"
        case .createPDF: "将图片合并成一份 PDF"
        case .archive: "把所选内容压缩成 ZIP 文件"
        case .copyTo: "保留原文件并复制到选定目录"
        case .moveTo: "将原文件移动到选定目录"
        case .groupInFolder: "为所选文件新建文件夹，并移动到指定位置"
        case .trash: "使用 macOS 废纸篓，可从 Finder 恢复"
        }
    }

    var isDestructive: Bool { self == .trash }
}

enum ShelfMenuOption: String, CaseIterable, Identifiable {
    case preview, renameItem, openWith, customActions
    case renameShelf, colors, pin, remove, moveUp, moveDown, clear, hide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preview: "快速查看"
        case .renameItem: "重命名项目…"
        case .openWith: "打开方式"
        case .customActions: "自定义操作"
        case .renameShelf: "重命名文件架…"
        case .colors: "文件架颜色"
        case .pin: "固定／取消固定文件架"
        case .remove: "从文件架移除"
        case .moveUp: "上移"
        case .moveDown: "下移"
        case .clear: "清空文件架"
        case .hide: "隐藏文件架"
        }
    }

    var systemImage: String {
        switch self {
        case .preview: "eye"
        case .renameItem, .renameShelf: "pencil"
        case .openWith: "arrow.up.forward.app"
        case .customActions: "bolt"
        case .colors: "paintpalette"
        case .pin: "pin"
        case .remove: "minus.circle"
        case .moveUp: "arrow.up"
        case .moveDown: "arrow.down"
        case .clear: "clear"
        case .hide: "rectangle.compress.vertical"
        }
    }
}

enum CustomShelfActionKind: String, Codable, CaseIterable {
    case copyTo
    case moveTo

    var title: String { self == .copyTo ? "复制到" : "移动到" }
    var systemImage: String { self == .copyTo ? "doc.on.doc.fill" : "folder.badge.plus" }
}

struct CustomShelfAction: Codable, Hashable, Identifiable {
    let id: UUID
    var name: String
    var kind: CustomShelfActionKind
    var destinationPath: String

    init(
        id: UUID = UUID(),
        name: String,
        kind: CustomShelfActionKind,
        destinationPath: String
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.destinationPath = destinationPath
    }
}
