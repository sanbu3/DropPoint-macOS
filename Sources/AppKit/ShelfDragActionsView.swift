import AppKit
import SwiftUI

/// The renderer and native drop targets share fixed centers throughout the animation.
@MainActor
final class ShelfDragActionsView: NSView {
    static let actionDiameter: CGFloat = 28
    static let triggerDiameter: CGFloat = 24
    static let targetDiameter: CGFloat = 36
    static let spacing: CGFloat = 6
    static let margin: CGFloat = 4
    static let hoverScale: CGFloat = 1.12
    static let transitionDuration = 0.28

    static func panelSize(for actions: [ShelfAction]) -> NSSize {
        let slots = 2 * ((actions.count + 1) / 2) + 1
        return NSSize(
            width: targetDiameter * CGFloat(slots) + spacing * CGFloat(slots - 1) + 2 * margin,
            height: targetDiameter + 2 * margin
        )
    }

    let actions: [ShelfAction]
    private weak var store: ShelfStore?
    private let renderingView: ShelfRenderingView

    init(store: ShelfStore, actions: [ShelfAction]) {
        self.store = store
        self.actions = actions
        renderingView = ShelfRenderingView(rootView: AnyView(DragActionCircles(store: store, actions: actions)))
        super.init(frame: NSRect(origin: .zero, size: Self.panelSize(for: actions)))
        renderingView.frame = bounds
        renderingView.autoresizingMask = [.width, .height]
        renderingView.sizingOptions = []
        renderingView.wantsLayer = true
        renderingView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(renderingView)
        registerForDraggedTypes(FileDropImporter.readableTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard store?.showsDragActions == true else { return nil }
        let location = convert(point, from: superview)
        return isOverTrigger(location) || action(at: location) != nil ? self : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let store, store.showsDragActions, !store.isClosed,
              store.updateExternalDrop(sender), actions == store.dragActions else { return [] }
        return updateTarget(at: convert(sender.draggingLocation, from: nil))
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        store?.targetedDragAction = nil
        store?.scheduleDropTargetExit()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        store?.updateDropTargeted(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let store, store.showsDragActions, store.updateExternalDrop(sender),
              actions == store.dragActions else { return false }
        let location = convert(sender.draggingLocation, from: nil)
        if isOverTrigger(location) {
            return ShelfDropCoordinator.accept(sender.draggingPasteboard, into: store)
        }
        guard let action = action(at: location) else { return false }
        return ShelfDropCoordinator.accept(sender.draggingPasteboard, into: store, action: action)
    }

    static func actionOffset(_ index: Int, count: Int) -> CGFloat {
        let leftCount = (count + 1) / 2
        let slot = index < leftCount ? index - leftCount : index - leftCount + 1
        return CGFloat(slot) * (targetDiameter + spacing)
    }

    func updateTarget(at point: NSPoint) -> NSDragOperation {
        guard let store, store.showsDragActions else { return [] }
        if isOverTrigger(point) {
            store.expandDragActions()
            store.targetedDragAction = nil
            return .copy
        }
        let action = action(at: point)
        store.targetedDragAction = action
        return action == nil ? [] : .copy
    }

    private func isOverTrigger(_ point: NSPoint) -> Bool {
        hypot(point.x - bounds.midX, point.y - bounds.midY) <= Self.targetDiameter / 2
    }

    func action(at point: NSPoint) -> ShelfAction? {
        guard store?.showsDragActions == true, store?.dragActionsExpanded == true else { return nil }
        for (index, action) in actions.enumerated() {
            let centerX = bounds.midX + Self.actionOffset(index, count: actions.count)
            let isTargeted = store?.targetedDragAction == action && store?.reduceMotion == false
            let radius = Self.targetDiameter / 2 * (isTargeted ? Self.hoverScale : 1)
            if hypot(point.x - centerX, point.y - bounds.midY) <= radius { return action }
        }
        return nil
    }
}

private struct DragActionCircles: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let store: ShelfStore
    let actions: [ShelfAction]
    @State private var ready = false

    var body: some View {
        let palette = ShelfPalette(dark: colorScheme == .dark, tint: store.tint)
        let visible = ready && store.showsDragActions
        let expanded = visible && store.dragActionsExpanded
        let size = ShelfDragActionsView.panelSize(for: actions)
        ZStack {
            ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                let targeted = store.targetedDragAction == action
                let offset = ShelfDragActionsView.actionOffset(index, count: actions.count)
                Image(systemName: action.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(targeted ? palette.accent : palette.ink)
                    .frame(width: ShelfDragActionsView.actionDiameter, height: ShelfDragActionsView.actionDiameter)
                    .background {
                        Circle().fill(palette.activeSurface)
                        Circle().fill(palette.accentSurface).opacity(targeted ? 1 : 0)
                    }
                    .overlay {
                        Circle().strokeBorder(targeted ? palette.accent : palette.edge, lineWidth: targeted ? 1.5 : 1)
                    }
                    .accessibilityLabel(action.title)
                    .scaleEffect(targeted && !reduceMotion ? ShelfDragActionsView.hoverScale : 1)
                    .animation(.smooth(duration: 0.15), value: targeted)
                    .scaleEffect(expanded || reduceMotion ? 1 : 0.6)
                    .offset(x: expanded || reduceMotion ? offset : 0)
                    .opacity(expanded ? 1 : 0)
                    .accessibilityHidden(!expanded)
            }

            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.accent)
                .frame(width: ShelfDragActionsView.triggerDiameter, height: ShelfDragActionsView.triggerDiameter)
                .background {
                    Circle().fill(palette.activeSurface)
                    Circle().fill(palette.accentSurface)
                }
                .overlay { Circle().strokeBorder(palette.accent.opacity(0.55), lineWidth: 1) }
                .accessibilityLabel("展开拖放操作")
                .opacity(visible ? 1 : 0)
        }
        .frame(width: size.width, height: size.height)
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: ShelfDragActionsView.transitionDuration),
            value: visible
        )
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: ShelfDragActionsView.transitionDuration),
            value: expanded
        )
        .accessibilityHidden(!visible)
        .task { ready = true }
    }
}
