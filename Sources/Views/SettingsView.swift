import AppKit
import SwiftUI

private enum SettingsPage: String, CaseIterable, Identifiable {
    case activation
    case interaction
    case general
    case actions
    case folders
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activation: "唤出方式"
        case .interaction: "文件架行为"
        case .general: "通用"
        case .actions: "快捷操作"
        case .folders: "自动收集"
        case .about: "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .activation: "cursorarrow.motionlines"
        case .interaction: "cursorarrow.rays"
        case .general: "gearshape"
        case .actions: "bolt.fill"
        case .folders: "folder.badge.plus"
        case .about: "info.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .activation: "唤出文件架与窗口位置"
        case .interaction: "默认行为与窗口操作"
        case .general: "外观、启动与生命周期"
        case .actions: "服务与系统集成"
        case .folders: "监听文件夹与桌面截图"
        case .about: "版本与应用信息"
        }
    }
}

struct SettingsView: View {
    let settings: AppSettings
    let onDismiss: () -> Void

    @State private var draft: SettingsDraft
    @State private var selection = SettingsPage.activation
    @State private var launchAtLogin = LaunchAtLoginService.isEnabled
    @State private var loginItemError: String?
    @State private var keyMonitor: Any?

    init(settings: AppSettings, onDismiss: @escaping () -> Void) {
        self.settings = settings
        self.onDismiss = onDismiss
        _draft = State(initialValue: SettingsDraft(settings))
    }

    var body: some View {
        ZStack {
            DropPointGlassBackground()

            HStack(spacing: 0) {
                sidebar
                Divider().opacity(0.5)
                page.padding(.top, 42)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(.thinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .focusEffectDisabled()
            .help("关闭设置（⌘W）")
            .accessibilityLabel("关闭设置")
            .padding(.top, 10)
            .padding(.trailing, 14)
        }
        .frame(minWidth: 820, minHeight: 560)
        .focusEffectDisabled()
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: draft) { settings.apply(draft) }
        .alert("无法更改登录启动设置", isPresented: loginErrorPresented) {
            Button("好", role: .cancel) { loginItemError = nil }
        } message: {
            Text(loginItemError ?? "未知错误")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                DropPointLogoImage(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("DropPoint")
                        .font(.system(size: 16, weight: .bold))
                    Text("设置")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            VStack(spacing: 5) {
            ForEach(SettingsPage.allCases) { page in
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        selection = page
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: page.systemImage)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(selection == page ? Color.dropPointBlue : .primary)
                            .frame(width: 30, height: 30)
                            .background(
                                selection == page ? Color.dropPointBlue.opacity(0.12) : Color.primary.opacity(0.05),
                                in: .rect(cornerRadius: 10)
                            )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(page.title)
                                .font(.system(size: 13, weight: .semibold))
                            Text(page.subtitle)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(
                        selection == page ? Color.dropPointBlue.opacity(0.09) : .clear,
                        in: .rect(cornerRadius: 14)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(selection == page ? Color.dropPointBlue.opacity(0.34) : .clear)
                    }
                    .contentShape(.rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled()
                .help(page.title)
            }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 16)
            sidebarBrandCard
                .padding(12)
        }
        .frame(width: 230)
        .background(.ultraThinMaterial)
    }

    private var sidebarBrandCard: some View {
        DropPointSettingsCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 11) {
                    DropPointLogoImage(size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("DropPoint")
                            .font(.system(size: 15, weight: .bold))
                        Text("版本 \(appVersion)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("适用于 macOS 的原生临时文件架")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("在 Finder 中显示应用") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                .controlSize(.small)
                .focusEffectDisabled()
                .frame(maxWidth: .infinity)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                pageHeader
                switch selection {
                case .activation: activationPage
                case .interaction: interactionPage
                case .general: generalPage
                case .actions: actionsPage
                case .folders: foldersPage
                case .about: aboutPage
                }
            }
            .frame(maxWidth: 690, alignment: .leading)
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .id(selection)
    }

    private var pageHeader: some View {
        DropPointSettingsCard {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(selection.title)
                        .font(.system(size: 26, weight: .bold))
                    Text(pageDescription)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                headerIllustration
            }
            .padding(.horizontal, 22)
            .frame(minHeight: 118)
        }
    }

    private var headerIllustration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.dropPointBlue.opacity(0.08))
                .frame(width: 116, height: 72)
                .offset(x: -18, y: -12)
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.dropPointBlue.opacity(0.22))
                .frame(width: 104, height: 52)
                .offset(x: 16, y: 16)
            DropPointLogoImage(size: 40)
                .offset(x: 26, y: 15)
            Image(systemName: "cursorarrow")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
                .offset(x: 76, y: 42)
        }
        .frame(width: 148, height: 88)
        .accessibilityHidden(true)
    }

    private var pageDescription: String {
        switch selection {
        case .activation: "决定拖动文件时如何唤出文件架，以及新窗口出现的位置。"
        case .interaction: "设置文件、窗口和拖出内容时的默认行为。"
        case .general: "管理菜单栏、程序坞、登录启动和应用生命周期。"
        case .actions: "选择文件架菜单中可直接执行的系统分享与文件操作。"
        case .folders: "监视文件夹中的新增内容，并自动创建文件架。"
        case .about: "DropPoint 是完全原生的 macOS 拖放辅助工具。"
        }
    }

    private var activationPage: some View {
        VStack(spacing: 18) {
            DropPointSettingsCard {
                VStack(spacing: 0) {
                    settingRow(
                        icon: "cursorarrow.motionlines",
                        title: "晃动激活",
                        detail: "拖动文件时左右晃动光标，在当前位置创建文件架。"
                    ) {
                        Toggle("", isOn: $draft.shakeActivationEnabled).labelsHidden()
                            .focusEffectDisabled()
                    }
                    Divider().padding(.leading, 54)
                    settingRow(
                        icon: "dial.medium",
                        title: "晃动灵敏度",
                        detail: "高敏感适合轻微晃动；微弱敏感需要更明显的往返动作。"
                    ) {
                        optionPicker($draft.shakeSensitivity)
                    }
                    .disabled(!draft.shakeActivationEnabled)
                }
            }

            DropPointSettingsCard {
                VStack(spacing: 0) {
                    settingRow(
                        icon: "keyboard",
                        title: "按键激活",
                        detail: "拖动开始前或拖动过程中按住修饰键，在光标附近创建文件架。"
                    ) {
                        Toggle("", isOn: $draft.modifierActivationEnabled).labelsHidden()
                            .focusEffectDisabled()
                    }
                    Divider().padding(.leading, 54)
                    settingRow(
                        icon: "command",
                        title: "激活按键",
                        detail: "不影响 Shift 拖出后保持窗口的行为。"
                    ) {
                        optionPicker($draft.activationModifier)
                    }
                    .disabled(!draft.modifierActivationEnabled)
                }
            }

            DropPointSettingsCard {
                VStack(spacing: 0) {
                    settingRow(icon: "rectangle.inset.filled", title: "默认文件架位置", detail: "适用于快捷键和菜单栏创建的窗口。") {
                        optionPicker($draft.shelfPosition)
                    }
                    Divider().padding(.leading, 54)
                    settingRow(icon: "keyboard.badge.ellipsis", title: "全局快捷键", detail: "Shift+Tab 创建或显示；⌥⇧A 从剪贴板创建。") {
                        optionPicker($draft.shortcutAction)
                    }
                }
            }
        }
    }

    private var interactionPage: some View {
        VStack(spacing: 18) {
            DropPointSettingsCard {
                VStack(spacing: 0) {
                    settingRow(icon: "cursorarrow.click.2", title: "双击文件", detail: "双击紧凑文件架或详细列表中的文件。") {
                        optionPicker($draft.doubleClickAction)
                    }
                    Divider().padding(.leading, 54)
                    settingRow(icon: "arrow.up.doc", title: "拖出默认行为", detail: "决定拖出成功后文件架中的项目是否保留。") {
                        optionPicker($draft.dragAction)
                    }
                }
            }

            DropPointSettingsCard {
                VStack(spacing: 0) {
                    toggleSetting("自动关闭详细窗口", detail: "文件架失去焦点时自动收起详细列表。", icon: "rectangle.compress.vertical", value: $draft.autoCollapseExpanded)
                    Divider().padding(.leading, 54)
                    toggleSetting("窗口显示时获取焦点", detail: "文件架默认不抢焦点；启用后将成为活动窗口。", icon: "scope", value: $draft.focusShelfOnShow)
                    Divider().padding(.leading, 54)
                    settingRow(icon: "rectangle.topthird.inset.filled", title: "放置后贴边位置", detail: "文件架收到文件后会立即停靠到所选屏幕角落。") {
                        optionPicker($draft.snapCorner)
                    }
                    Divider().padding(.leading, 54)
                    settingRow(
                        icon: "moon.zzz",
                        title: "闲置后归位",
                        detail: "长时间未操作时，平滑移动到屏幕右上角。"
                    ) {
                        optionPicker($draft.idleSnapDelay)
                    }
                }
            }

            DropPointSettingsCard {
                sliderSetting(
                    "空文件架自动关闭",
                    detail: draft.emptyShelfTimeout == 0 ? "永不自动关闭" : "等待 \(Int(draft.emptyShelfTimeout)) 秒",
                    icon: "timer",
                    value: $draft.emptyShelfTimeout,
                    range: 0...30
                )
            }
        }
    }

    private var generalPage: some View {
        VStack(spacing: 18) {
            DropPointSettingsCard {
                VStack(spacing: 0) {
                    toggleSetting("显示菜单栏图标", detail: "点击图标打开操作菜单，并可从菜单进入设置。", icon: "menubar.rectangle", value: menuBarBinding)
                    Divider().padding(.leading, 54)
                    toggleSetting("在程序坞中显示", detail: "切换后立即更新应用的激活策略。", icon: "dock.rectangle", value: dockBinding)
                    Divider().padding(.leading, 54)
                    toggleSetting("登录时启动", detail: "使用 macOS 登录项服务，不安装额外后台程序。", icon: "person.crop.circle.badge.checkmark", value: launchAtLoginBinding)
                }
            }

            DropPointSettingsCard {
                VStack(spacing: 0) {
                    toggleSetting("启动时新建文件架", detail: "每次启动 DropPoint 时显示一个空文件架。", icon: "plus.rectangle.on.rectangle", value: $draft.spawnOnLaunch)
                    Divider().padding(.leading, 54)
                    toggleSetting("始终置顶", detail: "让文件架保持在普通应用窗口上方。", icon: "pin.fill", value: $draft.alwaysOnTop)
                    Divider().padding(.leading, 54)
                    toggleSetting("调试日志", detail: "在标准错误输出中记录窗口和贴边事件。", icon: "ladybug", value: $draft.debug)
                }
            }
        }
    }

    private var actionsPage: some View {
        VStack(spacing: 18) {
            DropPointSettingsCard {
                toggleSetting(
                    "启用直接行动",
                    detail: "在文件架的更多菜单中显示下方操作。",
                    icon: "bolt.fill",
                    value: $draft.instantActionsEnabled
                )
            }

            DropPointSettingsCard {
                VStack(spacing: 0) {
                    ForEach(Array(ShelfAction.allCases.enumerated()), id: \.element.id) { index, action in
                        if index > 0 { Divider().padding(.leading, 54) }
                        settingRow(icon: action.systemImage, title: action.title, detail: action.detail) {
                            Toggle("", isOn: actionBinding(action)).labelsHidden()
                                .focusEffectDisabled()
                        }
                    }
                }
                .disabled(!draft.instantActionsEnabled)
            }

            DropPointSettingsCard {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.dropPointBlue)
                            .frame(width: 30, height: 30)
                            .background(Color.dropPointBlue.opacity(0.10), in: .rect(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("自定义操作").font(.system(size: 13, weight: .semibold))
                            Text("保存常用目标文件夹，下次无需重复选择。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu("新增…") {
                            Button("复制文件到文件夹…") { addCustomAction(kind: .copyTo) }
                            Button("移动文件到文件夹…") { addCustomAction(kind: .moveTo) }
                        }
                    }
                    .padding(16)

                    if draft.customActions.isEmpty {
                        Divider().padding(.leading, 54)
                        Text("没有自定义操作")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 54)
                    } else {
                        ForEach(draft.customActions) { action in
                            Divider().padding(.leading, 54)
                            HStack(spacing: 12) {
                                Image(systemName: action.kind.systemImage)
                                    .foregroundStyle(Color.dropPointBlue)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(action.name).font(.system(size: 13, weight: .medium))
                                    Text(action.destinationPath)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Button {
                                    draft.customActions.removeAll { $0.id == action.id }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("删除自定义操作")
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 54)
                        }
                    }
                }
                .disabled(!draft.instantActionsEnabled)
            }

            Label(
                "AirDrop、信息和邮件使用系统分享服务；DropPoint 不会上传文件到自己的服务器。",
                systemImage: "lock.shield"
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private var foldersPage: some View {
        VStack(spacing: 18) {
            DropPointSettingsCard {
                toggleSetting(
                    "识别桌面截图",
                    detail: "独立识别系统及第三方截图；启用后不会把桌面的其他新增文件当成截图。",
                    icon: "camera.viewfinder",
                    value: $draft.screenshotDetectionEnabled
                )
            }

            DropPointSettingsCard {
                settingRow(
                    icon: "line.3.horizontal.decrease.circle",
                    title: "普通文件夹过滤",
                    detail: "筛选下方观察文件夹中的新增内容；桌面截图使用独立识别规则。"
                ) {
                    optionPicker($draft.watchedFileCategory)
                }
            }

            DropPointSettingsCard {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.dropPointBlue)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("观察的文件夹").font(.system(size: 13, weight: .semibold))
                            Text("检测新加入的文件，并为每一批变化创建一个文件架。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("添加文件夹…", action: addWatchedDirectory)
                            .focusEffectDisabled()
                    }
                    .padding(16)

                    if draft.watchedDirectories.isEmpty {
                        Divider().padding(.leading, 54)
                        ContentUnavailableView(
                            "没有观察的文件夹",
                            systemImage: "folder",
                            description: Text("添加文件夹后，DropPoint 会在本机监听新文件。")
                        )
                        .frame(minHeight: 210)
                    } else {
                        ForEach(draft.watchedDirectories, id: \.self) { path in
                            Divider().padding(.leading, 54)
                            watchedFolderRow(path)
                        }
                    }
                }
            }
        }
    }

    private var aboutPage: some View {
        DropPointSettingsCard {
            VStack(spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 92, height: 92)
                    .accessibilityHidden(true)

                VStack(spacing: 5) {
                    Text("DropPoint")
                        .font(.system(size: 24, weight: .bold))
                    Text("版本 \(appVersion)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("适用于 macOS 的原生临时文件架")
                        .font(.system(size: 13))
                }

                HStack(spacing: 8) {
                    aboutBadge("原生 SwiftUI", icon: "swift")
                    aboutBadge("本地文件处理", icon: "lock.shield")
                }

                HStack(spacing: 14) {
                    Button("在 Finder 中显示应用") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                    .focusEffectDisabled()

                    Link("查看原生源码", destination: ProjectAttribution.sourceRepositoryURL)
                        .focusEffectDisabled()
                }

                HStack {
                    Spacer()
                    Link(destination: ProjectAttribution.nativeMaintainerURL) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(ProjectAttribution.maintainerWatermark)
                                .font(.system(size: 10, weight: .medium))
                            Text(ProjectAttribution.nativeMaintainerAddress)
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("原生版本维护者：\(ProjectAttribution.nativeMaintainerName)（\(ProjectAttribution.nativeMaintainerHandle)）")
                    .accessibilityLabel("原生版本维护者 \(ProjectAttribution.nativeMaintainerName)，GitHub \(ProjectAttribution.nativeMaintainerHandle)")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(28)
        }
    }

    private func settingRow<Control: View>(
        icon: String,
        title: String,
        detail: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.dropPointBlue)
                .frame(width: 30, height: 30)
                .background(Color.dropPointBlue.opacity(0.10), in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 16)
            control()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 54)
    }

    private func toggleSetting(
        _ title: String,
        detail: String,
        icon: String,
        value: Binding<Bool>
    ) -> some View {
        settingRow(icon: icon, title: title, detail: detail) {
            Toggle("", isOn: value).labelsHidden()
                .focusEffectDisabled()
        }
    }

    private func sliderSetting(
        _ title: String,
        detail: String,
        icon: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        settingRow(icon: icon, title: title, detail: detail) {
            Slider(value: value, in: range, step: 1)
                .frame(width: 170)
                .focusEffectDisabled()
        }
    }

    private func optionPicker<T: SettingOption>(_ selection: Binding<T>) -> some View {
        Picker("", selection: selection) {
            ForEach(Array(T.allCases)) { option in
                Text(option.title).tag(option)
            }
        }
        .labelsHidden()
        .fixedSize()
        .focusEffectDisabled()
    }

    private func watchedFolderRow(_ path: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Color.dropPointBlue)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                Text(path)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                draft.watchedDirectories.removeAll { $0 == path }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("停止观察")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 54)
    }

    private func aboutBadge(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 27)
            .background(Color.dropPointBlue.opacity(0.10), in: Capsule())
            .foregroundStyle(Color.dropPointBlue)
    }

    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { draft.showMenuBarIcon },
            set: { draft.showMenuBarIcon = $0 || !draft.showInDock }
        )
    }

    private var dockBinding: Binding<Bool> {
        Binding(
            get: { draft.showInDock },
            set: { enabled in
                draft.showInDock = enabled
                if !enabled { draft.showMenuBarIcon = true }
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { enabled in
                do {
                    try LaunchAtLoginService.setEnabled(enabled)
                    launchAtLogin = LaunchAtLoginService.isEnabled
                } catch {
                    launchAtLogin = LaunchAtLoginService.isEnabled
                    loginItemError = error.localizedDescription
                }
            }
        )
    }

    private var loginErrorPresented: Binding<Bool> {
        Binding(
            get: { loginItemError != nil },
            set: { if !$0 { loginItemError = nil } }
        )
    }

    private func actionBinding(_ action: ShelfAction) -> Binding<Bool> {
        Binding(
            get: { draft.enabledActions.contains(action) },
            set: { enabled in
                if enabled {
                    guard !draft.enabledActions.contains(action) else { return }
                    let desiredOrder = ShelfAction.allCases
                    draft.enabledActions.append(action)
                    draft.enabledActions.sort {
                        desiredOrder.firstIndex(of: $0)! < desiredOrder.firstIndex(of: $1)!
                    }
                } else {
                    draft.enabledActions.removeAll { $0 == action }
                }
            }
        )
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.4.1"
    }

    private func addWatchedDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择要观察的文件夹"
        if panel.runModal() == .OK, let path = panel.url?.path,
           !draft.watchedDirectories.contains(path) {
            draft.watchedDirectories.append(path)
        }
    }

    private func addCustomAction(kind: CustomShelfActionKind) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择“\(kind.title)”操作的目标文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folderName = url.lastPathComponent
        let action = CustomShelfAction(
            name: "\(kind.title) \(folderName)",
            kind: kind,
            destinationPath: url.path
        )
        draft.customActions.append(action)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if chars == "w",
               event.modifierFlags.contains(.command),
               event.window?.title == "DropPoint 设置" {
                onDismiss()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
