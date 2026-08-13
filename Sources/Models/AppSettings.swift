import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

protocol SettingOption: CaseIterable, Identifiable, Hashable, RawRepresentable where RawValue == String {
    var title: String { get }
}

enum ShelfPosition: String, SettingOption {
    case topRight = "top-right"
    case topLeft = "top-left"
    case bottomRight = "bottom-right"
    case bottomLeft = "bottom-left"
    case center
    case cursor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topRight: "右上角"
        case .topLeft: "左上角"
        case .bottomRight: "右下角"
        case .bottomLeft: "左下角"
        case .center: "中央"
        case .cursor: "靠近光标"
        }
    }
}

enum ShortcutAction: String, SettingOption {
    case toggle
    case spawn

    var id: String { rawValue }
    var title: String { self == .toggle ? "显示/隐藏 DropPoint" : "新建 DropPoint" }
}

enum DragDefaultAction: String, SettingOption {
    case copy
    case move

    var id: String { rawValue }
    var title: String { self == .copy ? "拷贝" : "移动" }
}

enum ShakeSensitivity: String, SettingOption {
    case low
    case medium
    case high

    var id: String { rawValue }
    var title: String {
        switch self {
        case .low: "微弱敏感 · 剧烈晃动"
        case .medium: "中度敏感 · 稍微晃动"
        case .high: "高敏感 · 轻微晃动"
        }
    }

    var requiredReversals: Int {
        switch self {
        case .low: 4
        case .medium: 3
        case .high: 2
        }
    }

    var minimumExcursion: CGFloat {
        switch self {
        case .low: 18
        case .medium: 10
        case .high: 6
        }
    }

    var samplingWindow: TimeInterval {
        switch self {
        case .low: 0.9
        case .medium: 0.75
        case .high: 0.65
        }
    }
}

enum WatchedFileCategory: String, SettingOption {
    case all
    case screenshots
    case documents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部文件"
        case .screenshots: "所有图片"
        case .documents: "文档与其他文件"
        }
    }

    func includes(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey]),
              values.isRegularFile == true else { return false }
        let isImage = values.contentType?.conforms(to: .image) == true
        switch self {
        case .all: return true
        case .screenshots: return isImage
        case .documents: return !isImage
        }
    }
}

enum IdleSnapDelay: String, SettingOption {
    case off
    case fifteenSeconds
    case thirtySeconds
    case oneMinute
    case twoMinutes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "关闭"
        case .fifteenSeconds: "15 秒"
        case .thirtySeconds: "30 秒"
        case .oneMinute: "1 分钟"
        case .twoMinutes: "2 分钟"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .off: 0
        case .fifteenSeconds: 15
        case .thirtySeconds: 30
        case .oneMinute: 60
        case .twoMinutes: 120
        }
    }
}

enum ActivationModifier: String, SettingOption {
    case shift
    case option
    case control
    case command

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shift: "⇧ Shift"
        case .option: "⌥ Option"
        case .control: "⌃ Control"
        case .command: "⌘ Command"
        }
    }

    var eventFlag: NSEvent.ModifierFlags {
        switch self {
        case .shift: .shift
        case .option: .option
        case .control: .control
        case .command: .command
        }
    }
}

enum FileDoubleClickAction: String, SettingOption {
    case open
    case reveal
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: "打开文件"
        case .reveal: "在 Finder 中显示"
        case .none: "不执行操作"
        }
    }
}

enum SnapCorner: String, SettingOption {
    case topRight
    case topLeft

    var id: String { rawValue }
    var title: String {
        switch self {
        case .topRight: "右上角"
        case .topLeft: "左上角"
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isApplyingDraft = false
    @ObservationIgnored var onChange: (() -> Void)?

    var spawnOnLaunch: Bool { didSet { persistPropertyChange() } }
    var alwaysOnTop: Bool { didSet { persistPropertyChange() } }
    var shelfPosition: ShelfPosition { didSet { persistPropertyChange() } }
    var shortcutAction: ShortcutAction { didSet { persistPropertyChange() } }
    var shakeActivationEnabled: Bool { didSet { persistPropertyChange() } }
    var shakeSensitivity: ShakeSensitivity { didSet { persistPropertyChange() } }
    var modifierActivationEnabled: Bool { didSet { persistPropertyChange() } }
    var activationModifier: ActivationModifier { didSet { persistPropertyChange() } }
    var dragAction: DragDefaultAction { didSet { persistPropertyChange() } }
    var doubleClickAction: FileDoubleClickAction { didSet { persistPropertyChange() } }
    var autoCollapseExpanded: Bool { didSet { persistPropertyChange() } }
    var focusShelfOnShow: Bool { didSet { persistPropertyChange() } }
    var emptyShelfTimeout: Double { didSet { persistPropertyChange() } }
    var autoSnapAfterDrop: Bool { didSet { persistPropertyChange() } }
    var snapCorner: SnapCorner { didSet { persistPropertyChange() } }
    var showMenuBarIcon: Bool { didSet { persistPropertyChange() } }
    var showInDock: Bool { didSet { persistPropertyChange() } }
    var instantActionsEnabled: Bool { didSet { persistPropertyChange() } }
    var enabledActions: [ShelfAction] { didSet { persistPropertyChange() } }
    var customActions: [CustomShelfAction] { didSet { persistPropertyChange() } }
    var screenshotDetectionEnabled: Bool { didSet { persistPropertyChange() } }
    var watchedDirectories: [String] { didSet { persistPropertyChange() } }
    var watchedFileCategory: WatchedFileCategory { didSet { persistPropertyChange() } }
    var idleSnapDelay: IdleSnapDelay { didSet { persistPropertyChange() } }
    var debug: Bool { didSet { persistPropertyChange() } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        spawnOnLaunch = defaults.object(forKey: Keys.spawnOnLaunch) as? Bool ?? true
        alwaysOnTop = defaults.object(forKey: Keys.alwaysOnTop) as? Bool ?? true
        shelfPosition = ShelfPosition(
            rawValue: defaults.string(forKey: Keys.shelfPosition) ?? "cursor"
        ) ?? .cursor
        shortcutAction = ShortcutAction(
            rawValue: defaults.string(forKey: Keys.shortcutAction) ?? "toggle"
        ) ?? .toggle
        shakeActivationEnabled = defaults.object(forKey: Keys.shakeActivationEnabled) as? Bool ?? true
        shakeSensitivity = ShakeSensitivity(
            rawValue: defaults.string(forKey: Keys.shakeSensitivity) ?? "medium"
        ) ?? .medium
        modifierActivationEnabled = defaults.object(forKey: Keys.modifierActivationEnabled) as? Bool ?? true
        activationModifier = ActivationModifier(
            rawValue: defaults.string(forKey: Keys.activationModifier) ?? "shift"
        ) ?? .shift
        dragAction = DragDefaultAction(
            rawValue: defaults.string(forKey: Keys.dragAction) ?? "copy"
        ) ?? .copy
        doubleClickAction = FileDoubleClickAction(
            rawValue: defaults.string(forKey: Keys.doubleClickAction) ?? "open"
        ) ?? .open
        autoCollapseExpanded = defaults.object(forKey: Keys.autoCollapseExpanded) as? Bool ?? true
        focusShelfOnShow = defaults.object(forKey: Keys.focusShelfOnShow) as? Bool ?? false
        emptyShelfTimeout = defaults.object(forKey: Keys.emptyShelfTimeout) as? Double ?? 6
        autoSnapAfterDrop = defaults.object(forKey: Keys.autoSnapAfterDrop) as? Bool ?? true
        snapCorner = SnapCorner(
            rawValue: defaults.string(forKey: Keys.snapCorner) ?? "topRight"
        ) ?? .topRight
        showMenuBarIcon = defaults.object(forKey: Keys.showMenuBarIcon) as? Bool ?? true
        showInDock = defaults.object(forKey: Keys.showInDock) as? Bool ?? false
        instantActionsEnabled = defaults.object(forKey: Keys.instantActionsEnabled) as? Bool ?? true
        if let rawActions = defaults.array(forKey: Keys.enabledActions) as? [String] {
            enabledActions = rawActions.compactMap(ShelfAction.init(rawValue:))
        } else {
            enabledActions = ShelfAction.defaultActions
        }
        if let data = defaults.data(forKey: Keys.customActions),
           let actions = try? JSONDecoder().decode([CustomShelfAction].self, from: data) {
            customActions = actions
        } else {
            customActions = []
        }
        screenshotDetectionEnabled = defaults.object(forKey: Keys.screenshotDetectionEnabled) as? Bool ?? true
        if let paths = defaults.array(forKey: Keys.watchedDirectories) as? [String] {
            watchedDirectories = paths
        } else {
            watchedDirectories = []
        }
        watchedFileCategory = WatchedFileCategory(
            rawValue: defaults.string(forKey: Keys.watchedFileCategory) ?? "all"
        ) ?? .all
        idleSnapDelay = IdleSnapDelay(
            rawValue: defaults.string(forKey: Keys.idleSnapDelay) ?? "oneMinute"
        ) ?? .oneMinute
        debug = defaults.object(forKey: Keys.debug) as? Bool ?? false
    }

    func apply(_ draft: SettingsDraft) {
        guard draft != SettingsDraft(self) else { return }
        isApplyingDraft = true
        spawnOnLaunch = draft.spawnOnLaunch
        alwaysOnTop = draft.alwaysOnTop
        shelfPosition = draft.shelfPosition
        shortcutAction = draft.shortcutAction
        shakeActivationEnabled = draft.shakeActivationEnabled
        shakeSensitivity = draft.shakeSensitivity
        modifierActivationEnabled = draft.modifierActivationEnabled
        activationModifier = draft.activationModifier
        dragAction = draft.dragAction
        doubleClickAction = draft.doubleClickAction
        autoCollapseExpanded = draft.autoCollapseExpanded
        focusShelfOnShow = draft.focusShelfOnShow
        emptyShelfTimeout = draft.emptyShelfTimeout
        autoSnapAfterDrop = draft.autoSnapAfterDrop
        snapCorner = draft.snapCorner
        showMenuBarIcon = draft.showMenuBarIcon
        showInDock = draft.showInDock
        instantActionsEnabled = draft.instantActionsEnabled
        enabledActions = draft.enabledActions
        customActions = draft.customActions
        screenshotDetectionEnabled = draft.screenshotDetectionEnabled
        watchedDirectories = draft.watchedDirectories
        watchedFileCategory = draft.watchedFileCategory
        idleSnapDelay = draft.idleSnapDelay
        debug = draft.debug
        isApplyingDraft = false
        persist()
    }

    private func persistPropertyChange() {
        guard !isApplyingDraft else { return }
        persist()
    }

    private func persist() {
        defaults.set(spawnOnLaunch, forKey: Keys.spawnOnLaunch)
        defaults.set(alwaysOnTop, forKey: Keys.alwaysOnTop)
        defaults.set(shelfPosition.rawValue, forKey: Keys.shelfPosition)
        defaults.set(shortcutAction.rawValue, forKey: Keys.shortcutAction)
        defaults.set(shakeActivationEnabled, forKey: Keys.shakeActivationEnabled)
        defaults.set(shakeSensitivity.rawValue, forKey: Keys.shakeSensitivity)
        defaults.set(modifierActivationEnabled, forKey: Keys.modifierActivationEnabled)
        defaults.set(activationModifier.rawValue, forKey: Keys.activationModifier)
        defaults.set(dragAction.rawValue, forKey: Keys.dragAction)
        defaults.set(doubleClickAction.rawValue, forKey: Keys.doubleClickAction)
        defaults.set(autoCollapseExpanded, forKey: Keys.autoCollapseExpanded)
        defaults.set(focusShelfOnShow, forKey: Keys.focusShelfOnShow)
        defaults.set(emptyShelfTimeout, forKey: Keys.emptyShelfTimeout)
        defaults.set(autoSnapAfterDrop, forKey: Keys.autoSnapAfterDrop)
        defaults.set(snapCorner.rawValue, forKey: Keys.snapCorner)
        defaults.set(showMenuBarIcon, forKey: Keys.showMenuBarIcon)
        defaults.set(showInDock, forKey: Keys.showInDock)
        defaults.set(instantActionsEnabled, forKey: Keys.instantActionsEnabled)
        defaults.set(enabledActions.map(\.rawValue), forKey: Keys.enabledActions)
        defaults.set(try? JSONEncoder().encode(customActions), forKey: Keys.customActions)
        defaults.set(screenshotDetectionEnabled, forKey: Keys.screenshotDetectionEnabled)
        defaults.set(watchedDirectories, forKey: Keys.watchedDirectories)
        defaults.set(watchedFileCategory.rawValue, forKey: Keys.watchedFileCategory)
        defaults.set(idleSnapDelay.rawValue, forKey: Keys.idleSnapDelay)
        defaults.set(debug, forKey: Keys.debug)
        onChange?()
    }

    private enum Keys {
        static let spawnOnLaunch = "spawnOnLaunch"
        static let alwaysOnTop = "alwaysOnTop"
        static let shelfPosition = "shelfPosition"
        static let shortcutAction = "shortcutAction"
        static let shakeActivationEnabled = "shakeActivationEnabled"
        static let shakeSensitivity = "shakeSensitivity"
        static let modifierActivationEnabled = "modifierActivationEnabled"
        static let activationModifier = "activationModifier"
        static let dragAction = "dragAction"
        static let doubleClickAction = "doubleClickAction"
        static let autoCollapseExpanded = "autoCollapseExpanded"
        static let focusShelfOnShow = "focusShelfOnShow"
        static let emptyShelfTimeout = "emptyShelfTimeout"
        static let autoSnapAfterDrop = "autoSnapAfterDrop"
        static let snapCorner = "snapCorner"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let showInDock = "showInDock"
        static let instantActionsEnabled = "instantActionsEnabled"
        static let enabledActions = "enabledActions"
        static let customActions = "customActions"
        static let screenshotDetectionEnabled = "screenshotDetectionEnabled"
        static let watchedDirectories = "watchedDirectories"
        static let watchedFileCategory = "watchedFileCategory"
        static let idleSnapDelay = "idleSnapDelay"
        static let debug = "debug"
    }
}

struct SettingsDraft: Equatable {
    var spawnOnLaunch: Bool
    var alwaysOnTop: Bool
    var shelfPosition: ShelfPosition
    var shortcutAction: ShortcutAction
    var shakeActivationEnabled: Bool
    var shakeSensitivity: ShakeSensitivity
    var modifierActivationEnabled: Bool
    var activationModifier: ActivationModifier
    var dragAction: DragDefaultAction
    var doubleClickAction: FileDoubleClickAction
    var autoCollapseExpanded: Bool
    var focusShelfOnShow: Bool
    var emptyShelfTimeout: Double
    var autoSnapAfterDrop: Bool
    var snapCorner: SnapCorner
    var showMenuBarIcon: Bool
    var showInDock: Bool
    var instantActionsEnabled: Bool
    var enabledActions: [ShelfAction]
    var customActions: [CustomShelfAction]
    var screenshotDetectionEnabled: Bool
    var watchedDirectories: [String]
    var watchedFileCategory: WatchedFileCategory
    var idleSnapDelay: IdleSnapDelay
    var debug: Bool

    @MainActor
    init(_ settings: AppSettings) {
        spawnOnLaunch = settings.spawnOnLaunch
        alwaysOnTop = settings.alwaysOnTop
        shelfPosition = settings.shelfPosition
        shortcutAction = settings.shortcutAction
        shakeActivationEnabled = settings.shakeActivationEnabled
        shakeSensitivity = settings.shakeSensitivity
        modifierActivationEnabled = settings.modifierActivationEnabled
        activationModifier = settings.activationModifier
        dragAction = settings.dragAction
        doubleClickAction = settings.doubleClickAction
        autoCollapseExpanded = settings.autoCollapseExpanded
        focusShelfOnShow = settings.focusShelfOnShow
        emptyShelfTimeout = settings.emptyShelfTimeout
        autoSnapAfterDrop = settings.autoSnapAfterDrop
        snapCorner = settings.snapCorner
        showMenuBarIcon = settings.showMenuBarIcon
        showInDock = settings.showInDock
        instantActionsEnabled = settings.instantActionsEnabled
        enabledActions = settings.enabledActions
        customActions = settings.customActions
        screenshotDetectionEnabled = settings.screenshotDetectionEnabled
        watchedDirectories = settings.watchedDirectories
        watchedFileCategory = settings.watchedFileCategory
        idleSnapDelay = settings.idleSnapDelay
        debug = settings.debug
    }
}
