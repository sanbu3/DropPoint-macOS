import AppKit
import SwiftUI

/// The renderer and native drop targets share fixed centers throughout the animation.
@MainActor
final class ShelfDragActionsView: NSView {
    static let diameter: CGFloat = 44
    static let spacing: CGFloat = 8
    static let margin: CGFloat = 4
    static let hoverScale: CGFloat = 1.12
    static let transitionDuration = 0.28

    static func panelSize(for actions: [ShelfAction]) -> NSSize {
        NSSize(
            width: diameter * CGFloat(actions.count) + spacing * CGFloat(max(0, actions.count - 1)) + 2 * margin,
            height: diameter + 2 * margin
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
        for (index, action) in actions.enumerated() {
            addToolTip(Self.targetRect(index), owner: action.title as NSString, userData: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard store?.showsDragActions == true else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let store, store.showsDragActions, !store.isClosed,
              store.updateExternalDrop(sender), actions == store.dragActions else { return [] }
        let action = action(at: convert(sender.draggingLocation, from: nil))
        store.targetedDragAction = action
        return action == nil ? [] : .copy
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
              actions == store.dragActions,
              let action = action(at: convert(sender.draggingLocation, from: nil)) else { return false }
        return ShelfDropCoordinator.accept(sender.draggingPasteboard, into: store, action: action)
    }

    private static func targetRect(_ index: Int) -> NSRect {
        NSRect(x: margin + CGFloat(index) * (diameter + spacing), y: margin, width: diameter, height: diameter)
    }

    func action(at point: NSPoint) -> ShelfAction? {
        for (index, action) in actions.enumerated() {
            let rect = Self.targetRect(index)
            let isTargeted = store?.targetedDragAction == action && store?.reduceMotion == false
            let radius = Self.diameter / 2 * (isTargeted ? Self.hoverScale : 1)
            if hypot(point.x - rect.midX, point.y - rect.midY) <= radius { return action }
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
        HStack(spacing: ShelfDragActionsView.spacing) {
            ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                let targeted = store.targetedDragAction == action
                let fromCenter = CGFloat(index) - CGFloat(actions.count - 1) / 2
                Image(systemName: action.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(targeted ? palette.accent : palette.ink)
                    .frame(width: ShelfDragActionsView.diameter, height: ShelfDragActionsView.diameter)
                    .background {
                        Circle().fill(palette.activeSurface)
                        Circle().fill(palette.accentSurface).opacity(targeted ? 1 : 0)
                    }
                    .overlay {
                        Circle().strokeBorder(targeted ? palette.accent : palette.edge, lineWidth: targeted ? 2 : 1)
                    }
                    .accessibilityLabel(action.title)
                    .scaleEffect(targeted && !reduceMotion ? ShelfDragActionsView.hoverScale : 1)
                    .animation(.smooth(duration: 0.15), value: targeted)
                    .scaleEffect(visible || reduceMotion ? 1 : 0.72)
                    .offset(x: visible || reduceMotion ? 0 : -fromCenter * 16)
                    .opacity(visible ? 1 : 0)
            }
        }
        .padding(ShelfDragActionsView.margin)
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: ShelfDragActionsView.transitionDuration),
            value: visible
        )
        .accessibilityHidden(!visible)
        .task { ready = true }
    }
}
