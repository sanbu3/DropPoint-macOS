import Foundation

enum ShelfAction: String, SettingOption {
    case airDrop
    case messages
    case mail
    case open
    case reveal
    case copyPaths
    case createPDF
    case archive
    case copyTo
    case moveTo
    case trash

    static let defaultActions: [ShelfAction] = [
        .airDrop,
        .messages,
        .mail,
        .open,
        .reveal,
        .copyPaths,
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
        case .createPDF: "创建 PDF"
        case .archive: "压缩为 ZIP"
        case .copyTo: "将文件复制到…"
        case .moveTo: "将文件移动到…"
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
        case .createPDF: "document.badge.plus"
        case .archive: "archivebox"
        case .copyTo: "doc.on.doc.fill"
        case .moveTo: "folder.badge.plus"
        case .trash: "trash"
        }
    }

    var detail: String {
        switch self {
        case .airDrop, .messages, .mail: "使用 macOS 系统分享服务"
        case .open: "使用默认应用打开所选内容"
        case .reveal: "在 Finder 中定位所选内容"
        case .copyPaths: "把 POSIX 路径复制到剪贴板"
        case .createPDF: "将图片合并成一份 PDF"
        case .archive: "把所选内容压缩成 ZIP 文件"
        case .copyTo: "保留原文件并复制到选定目录"
        case .moveTo: "将原文件移动到选定目录"
        case .trash: "使用 macOS 废纸篓，可从 Finder 恢复"
        }
    }

    var isDestructive: Bool { self == .trash }
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
