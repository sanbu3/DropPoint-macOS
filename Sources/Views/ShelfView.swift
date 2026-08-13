import AppKit
import SwiftUI

struct ShelfView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    let store: ShelfStore

    @State private var keyDownMonitor: Any?
    @State private var handleOpacity: CGFloat = 0.64

    private var palette: ShelfPalette { ShelfPalette(dark: colorScheme == .dark) }

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
        }
        .clipShape(.rect(cornerRadius: 25, style: .continuous))
        .contentShape(.rect(cornerRadius: 25, style: .continuous))
        .scaleEffect(store.isDropTargeted ? 0.992 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: store.isDropTargeted)
        .focusEffectDisabled()
        .onAppear {
            installKeyMonitor()
            syncMotionPreferences()
        }
        .onDisappear(perform: removeKeyMonitor)
        .onChange(of: reduceMotion) { syncMotionPreferences() }
        .preferredColorScheme(nil)
    }

    private var shelfBackground: some View {
        nativeGlassBackground
            .overlay {
                RoundedRectangle(cornerRadius: 25, style: .continuous)
                    .stroke(palette.highlight, lineWidth: store.isFocused ? 1.5 : 1)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(.black.opacity(colorScheme == .dark ? 0.34 : 0.055)).frame(height: 1)
            }
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
            if (store.isDropTargeted && !store.isDraggingOut) || store.presentation == .tray {
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
                palette: palette
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
        let progress = min(max(store.dismissGestureProgress, 0), 1)
        let lengthProgress = min(progress * 1.65, 1)
        let emphasisProgress = min(max((progress - 0.22) / 0.78, 0), 1)

        return VStack {
            Spacer()
            ZStack {
                ZStack {
                    Capsule().fill(palette.handle)
                    Capsule()
                        .fill(palette.danger)
                        .opacity(emphasisProgress)
                }
                .frame(
                    width: 38 + 46 * lengthProgress,
                    height: 4 + 4 * emphasisProgress
                )
                .opacity(max(handleOpacity, 0.64 + 0.36 * progress))
            }
            .frame(width: 92, height: 8)
            .padding(.bottom, 7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .animation(
            reduceMotion || store.isDismissGestureActive
                ? nil
                : .smooth(duration: 0.18),
            value: progress
        )
    }

    private func installKeyMonitor() {
        guard keyDownMonitor == nil else { return }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak store = store] event in
            guard let store, store.isFocused else { return event }

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
            if store.isExpanded, (code == 51 || code == 117) {
                store.removeSelected()
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
                let urls = ClipboardService.fileURLs()
                if !urls.isEmpty { store.add(urls: urls) }
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

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                AnimatedSVGView(name: "Cat_in_Box", animationEnabled: animationEnabled, pauseAfterCycle: true, randomRestart: true)
                    .frame(width: 112, height: 112)
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
        .focusable(false)
        .background(hovered ? palette.controlHover : .clear, in: Circle())
        .opacity(hovered ? 0.9 : (danger ? 0.72 : 0.34))
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
