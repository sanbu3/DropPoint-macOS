import AppKit
import SwiftUI

struct ShelfView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    let store: ShelfStore

    @State private var keyDownMonitor: Any?
    @State private var handleOpacity: CGFloat = 0.64

    private var palette: ShelfPalette {
        ShelfPalette(dark: colorScheme == .dark, focused: store.isFocused)
    }

    var body: some View {
        ZStack {
            shelfBackground
            if store.isExpanded {
                ExpandedShelfView(store: store, palette: palette)
            } else {
                compactContent
            }
            controls
            dragHandle
            windowDragAreas
        }
        .clipShape(.rect(cornerRadius: 25, style: .continuous))
        .contentShape(.rect(cornerRadius: 25, style: .continuous))
        .onAppear {
            installKeyMonitor()
            syncMotionPreferences()
        }
        .onDisappear(perform: removeKeyMonitor)
        .onChange(of: reduceMotion) { syncMotionPreferences() }
        .preferredColorScheme(nil)
    }

    private var shelfBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 25, style: .continuous)
        return nativeGlassBackground
            .overlay {
                shape
                    .fill(palette.focusedSurface)
                    .opacity(store.isFocused ? 1 : 0)
            }
            .overlay {
                shape.strokeBorder(palette.highlight, lineWidth: 1)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: store.isFocused)
    }

    @ViewBuilder
    private var nativeGlassBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 25, style: .continuous)
        if #available(macOS 26.0, *) {
            shape
                .fill(.clear)
                .glassEffect(
                    .regular.tint(
                        store.isDropTargeted
                            ? palette.accent.opacity(0.14)
                            : palette.surface.opacity(0.18)
                    ),
                    in: shape
                )
        } else {
            shape
                .fill(.ultraThinMaterial)
                .overlay {
                    shape.fill(
                        store.isDropTargeted
                            ? palette.activeSurface.opacity(0.32)
                            : palette.surface.opacity(0.24)
                    )
                }
        }
    }

    @ViewBuilder
    private var compactContent: some View {
        ZStack {
            if store.isDropTargeted && !store.isDraggingOut {
                DropGuideView(
                    animationEnabled: !reduceMotion,
                    palette: palette,
                    store: store
                )
                .transition(.opacity.combined(with: .scale(scale: 0.965)))
            } else if store.items.isEmpty && !store.isDraggingOut {
                EmptyShelfView(animationEnabled: !reduceMotion, palette: palette, store: store)
                    .transition(.opacity.combined(with: .scale(scale: 0.965)))
            } else {
                ZStack {
                    CompactFileShelfView(store: store, palette: palette)
                        .opacity(store.isClearing ? 0 : 1)
                        .scaleEffect(store.isClearing ? 0.08 : 1, anchor: .center)
                        .animation(reduceMotion ? nil : .linear(duration: 0.24), value: store.isClearing)

                    FileDragOutOverlay(
                        store: store,
                        itemsProvider: { store.items },
                        dragAction: store.dragAction,
                        onDoubleClick: { store.performDoubleClick() },
                        onDragBegan: store.beginInternalDrag,
                        onDragEnded: store.finishInternalDrag,
                        contextMenuProvider: { ShelfContextMenuFactory.make(for: store) }
                    )
                        .frame(width: 92, height: 94)
                        .position(x: 99, y: 95)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
        }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.2),
            value: store.isDropTargeted
        )
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.2),
            value: store.items.isEmpty
        )
    }

    private var controls: some View {
        ZStack {
            ShelfControlButton(
                systemName: "xmark",
                label: "关闭文件架",
                palette: palette,
                showsKeyboardFocus: store.isKeyboardNavigating
            ) {
                store.requestClose(commandPressed: false)
            }
            .frame(width: 26, height: 26)
            .position(
                x: (store.isExpanded ? ShelfGeometry.expandedSize(itemCount: store.items.count).width : ShelfGeometry.compactSize.width) - 21,
                y: 21
            )
        }
    }

    private var dragHandle: some View {
        let holding = store.isOptionClearActive
        let progress = min(max(store.dismissGestureProgress, 0), 1)
        let lengthProgress = min(progress * 1.65, 1)
        let emphasisProgress = min(max((progress - 0.22) / 0.78, 0), 1)
        let active = store.isHovered || store.isDropTargeted || store.isFocused
        let restingWidth: CGFloat = active ? 54 : 38
        let width: CGFloat = holding ? 126 : restingWidth + (110 - restingWidth) * lengthProgress
        let height: CGFloat = holding ? 9 : 4 + 2 * emphasisProgress

        return VStack(spacing: 5) {
            Spacer()
            ZStack(alignment: .leading) {
                Capsule().fill(palette.handle)
                if holding {
                    Rectangle()
                        .fill(palette.danger.gradient)
                        .frame(width: width * store.optionClearProgress)
                } else {
                    Capsule()
                        .fill(store.isDropTargeted ? palette.accent : palette.activeHandle)
                        .opacity(active ? 1 : 0)
                    Capsule()
                        .fill(palette.danger)
                        .opacity(emphasisProgress)
                }
            }
            .frame(width: width, height: height)
            .clipShape(Capsule())
            .opacity(holding || active ? 1 : max(handleOpacity, 0.64 + 0.36 * progress))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(holding ? "清空进度" : "文件架手柄")
            .accessibilityValue(holding ? "\(Int(store.optionClearProgress * 100))%" : "")
            .animation(reduceMotion ? nil : .smooth(duration: 0.16), value: holding)
            .padding(.bottom, 7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .animation(
            reduceMotion || store.isDismissGestureActive ? nil : .smooth(duration: 0.2),
            value: active
        )
        .animation(
            reduceMotion || store.isDismissGestureActive ? nil : .smooth(duration: 0.18),
            value: progress
        )
    }

    private var windowDragAreas: some View {
        ZStack {
            ShelfWindowDragOverlay(store: store)
                .frame(width: 148, height: 42)
                .position(x: 78, y: 21)
                .help("拖动文件架 · 双击清空")

            ShelfWindowDragOverlay(store: store)
                .frame(width: 120, height: 22)
                .position(x: 99, y: 196)
                .help("拖动文件架 · 双击清空 · Control-拖动文件图标也可移动")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func installKeyMonitor() {
        guard keyDownMonitor == nil else { return }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak store = store] event in
            guard let store, store.isFocused, event.window?.isKeyWindow == true,
                  (event.window?.windowController as? ShelfWindowController)?.store === store else { return event }

            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let code = event.keyCode
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

            if code == 49, modifiers.isEmpty, !event.isARepeat,
               store.previewSelection() {
                return nil
            }

            if store.isExpanded, code == 53 {
                store.toggleExpanded()
                return nil
            }
            if (code == 51 || code == 117), modifiers == .command {
                store.clear()
                return nil
            }
            if store.isExpanded, (code == 51 || code == 117) {
                store.removeSelected()
                return nil
            }
            if store.isExpanded, modifiers.isEmpty {
                switch code {
                case 123: store.moveSelection(by: -1)
                case 124: store.moveSelection(by: 1)
                case 125: store.moveSelection(by: 3)
                case 126: store.moveSelection(by: -3)
                default: return event
                }
                return nil
            }

            guard event.modifierFlags.contains(.command) else { return event }

            if (chars == "a" || code == 0), store.isExpanded {
                store.selectAll()
                return nil
            }
            if chars == "c" || code == 8 {
                store.copySelectedToClipboard()
                return nil
            }
            if chars == "v" || code == 9 {
                Task { @MainActor [weak store] in
                    let urls = await ClipboardService.fileURLs()
                    if !urls.isEmpty { store?.add(urls: urls) }
                }
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyDownMonitor { NSEvent.removeMonitor(keyDownMonitor) }
        keyDownMonitor = nil
    }

    private func syncMotionPreferences() {
        store.reduceMotion = reduceMotion
        if reduceMotion {
            withAnimation(nil) { handleOpacity = 0.64 }
        } else {
            handleOpacity = 0.64
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                handleOpacity = 0.35
            }
        }
    }
}

private struct EmptyShelfView: View {
    let animationEnabled: Bool
    let palette: ShelfPalette
    let store: ShelfStore
    @State private var animationReady = false

    private static let firstFrame: NSImage? = Bundle.main.url(forResource: "Cat_in_Box", withExtension: "svg")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if !animationReady, let firstFrame = Self.firstFrame {
                    Image(nsImage: firstFrame)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 112, height: 112)
                        .allowsHitTesting(false)
                }
                AnimatedSVGView(name: "Cat_in_Box", animationEnabled: animationEnabled, pauseAfterCycle: true, randomRestart: true, onReady: { animationReady = true })
                    .frame(width: 112, height: 112)
                    .opacity(animationReady ? 1 : 0)
                DragPassThroughOverlay(store: store)
                    .frame(width: 112, height: 112)
            }
        }
    }
}

private struct DropGuideView: View {
    let animationEnabled: Bool
    let palette: ShelfPalette
    let store: ShelfStore

    var body: some View {
        ZStack {
            AnimatedSVGView(name: "Empty Box", animationEnabled: animationEnabled, pauseAfterCycle: true)
                .frame(width: 152, height: 152)
            DragPassThroughOverlay(store: store)
                .frame(width: 152, height: 152)
        }
    }
}

private struct ShelfControlButton: View {
    let systemName: String
    let label: String
    let palette: ShelfPalette
    var danger = false
    var showsKeyboardFocus = true
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: systemName == "trash" ? 12 : 11, weight: .medium))
                .foregroundStyle(danger ? palette.danger : palette.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .shelfFocusRing(Circle(), color: palette.accent, showsFocus: showsKeyboardFocus)
        .background(hovered ? palette.controlHover : .clear, in: Circle())
        .opacity(hovered ? 0.95 : (danger ? 0.78 : 0.56))
        .onHover { hovered = $0 }
        .help(label)
    }
}

struct ResourceImage: View {
    let name: String
    let `extension`: String

    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: name, withExtension: `extension`),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
    }
}
