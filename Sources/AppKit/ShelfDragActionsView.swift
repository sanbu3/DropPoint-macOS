import AppKit
import SwiftUI

/// A separate native drop destination keeps the buttons outside the clipped shelf.
@MainActor
final class ShelfDragActionsView: NSView {
    static let diameter: CGFloat = 44
    static let spacing: CGFloat = 10
    static let actions: [ShelfAction] = [.archive, .compressImages, .resizeImages]
    static let panelSize = NSSize(
        width: diameter * CGFloat(actions.count) + spacing * CGFloat(actions.count - 1),
        height: diameter
    )

    private weak var store: ShelfStore?
    private let renderingView: ShelfRenderingView

    init(store: ShelfStore) {
        self.store = store
        renderingView = ShelfRenderingView(rootView: AnyView(DragActionCircles(store: store)))
        super.init(frame: NSRect(origin: .zero, size: Self.panelSize))
        renderingView.frame = bounds
        renderingView.sizingOptions = []
        renderingView.wantsLayer = true
        renderingView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(renderingView)
        registerForDraggedTypes(FileDropImporter.readableTypes)
        for (index, action) in Self.actions.enumerated() {
            addToolTip(Self.targetRect(index), owner: action.title as NSString, userData: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // The hosting view renders only. AppKit owns the drop targets on all macOS versions.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let store, !store.isClosed, !store.isDraggingOut,
              FileDropImporter.canImport(from: sender.draggingPasteboard) else { return [] }
        store.updateDropTargeted(true)
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
        guard let store, !store.isDraggingOut,
              let action = action(at: convert(sender.draggingLocation, from: nil)) else { return false }
        return ShelfDropCoordinator.accept(sender.draggingPasteboard, into: store, action: action)
    }

    private static func targetRect(_ index: Int) -> NSRect {
        NSRect(x: CGFloat(index) * (diameter + spacing), y: 0, width: diameter, height: diameter)
    }

    func action(at point: NSPoint) -> ShelfAction? {
        for (index, action) in Self.actions.enumerated() {
            let rect = Self.targetRect(index)
            if hypot(point.x - rect.midX, point.y - rect.midY) <= Self.diameter / 2 { return action }
        }
        return nil
    }
}

private struct DragActionCircles: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let store: ShelfStore
    @State private var appeared = false

    var body: some View {
        let palette = ShelfPalette(dark: colorScheme == .dark, tint: store.tint)
        HStack(spacing: ShelfDragActionsView.spacing) {
            ForEach(ShelfDragActionsView.actions) { action in
                let targeted = store.targetedDragAction == action
                Image(systemName: action.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(targeted ? palette.accent : palette.ink)
                    .frame(width: ShelfDragActionsView.diameter, height: ShelfDragActionsView.diameter)
                    .background(palette.activeSurface, in: Circle())
                    .overlay {
                        Circle().strokeBorder(targeted ? palette.accent : palette.edge, lineWidth: targeted ? 2 : 1)
                    }
                    .accessibilityLabel(action.title)
                    .scaleEffect(reduceMotion || appeared ? 1 : 0.5)
                    .opacity(appeared || reduceMotion ? 1 : 0)
            }
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) { appeared = true }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: store.targetedDragAction)
    }
}
