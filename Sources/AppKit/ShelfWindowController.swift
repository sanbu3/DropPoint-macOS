import AppKit
import SwiftUI

final class ShelfPanel: NSPanel {
    var onUserInteraction: (() -> Void)?
    var onPrecisionScroll: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .rightMouseDown, .keyDown, .scrollWheel:
            onUserInteraction?()
        default:
            break
        }
        if event.type == .scrollWheel, onPrecisionScroll?(event) == true {
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
final class ShelfWindowController: NSWindowController, NSWindowDelegate {
    private enum OutDisposition {
        case hide
        case close
    }

    let store: ShelfStore
    let isPending: Bool
    var onClosed: ((ShelfWindowController) -> Void)?
    var onWillDismiss: ((ShelfWindowController) -> Void)?
    var isPreviewActive: (() -> Bool)?
    var onSnapRequested: ((ShelfWindowController) -> Void)?
    var onInteraction: ((ShelfWindowController) -> Void)?

    private var compactOrigin: NSPoint?
    private var snapWorkItem: DispatchWorkItem?
    private var closeKeyMonitor: Any?
    private var isAnimatingOut = false
    private var isProgrammaticallyMoving = false
    private var programmaticMoveGeneration = 0
    private var isTrackingPullDown = false
    private var pullDownDistance: CGFloat = 0
    private var didTriggerPullDownDismiss = false

    private var dragGhostView: NSImageView?
    private var dragGhostMonitor: Any?
    private var dragGhostStart: NSPoint = .zero
    private let dragGhostRect = NSRect(x: 53, y: 48, width: 92, height: 94)
    private var trackingArea: NSTrackingArea?

    init(store: ShelfStore, isPending: Bool, alwaysOnTop: Bool) {
        self.store = store
        self.isPending = isPending

        let size = ShelfGeometry.compactSize
        let panel = ShelfPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.level = isPending || alwaysOnTop ? .floating : .normal
        panel.title = "DropPoint"

        let hostingView = ShelfDropHostingView(store: store)
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hostingView

        super.init(window: panel)
        panel.delegate = self
        panel.onUserInteraction = { [weak self] in
            guard let self else { return }
            self.onInteraction?(self)
        }
        panel.onPrecisionScroll = { [weak self] event in
            self?.handlePrecisionScroll(event) ?? false
        }
        closeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let eventWindow = event.window,
                  eventWindow === self.window,
                  Self.isCommandW(event) else { return event }
            self.closeAnimated()
            return nil
        }

        let trackingArea = NSTrackingArea(
            rect: hostingView.bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        hostingView.addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    required init?(coder: NSCoder) { nil }

    var panel: NSPanel? { window as? NSPanel }

    override func mouseEntered(with event: NSEvent) {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func show(at origin: NSPoint, activating: Bool) {
        window?.setFrameOrigin(origin)
        showWindowAnimated(activating: activating || store.focusShelfOnShow)
    }

    func showExistingAnimated(activating: Bool) {
        showWindowAnimated(activating: activating || store.focusShelfOnShow)
    }

    func orderOutAnimated() {
        onWillDismiss?(self)
        animateOut(.hide)
    }

    func closeAnimated() {
        onWillDismiss?(self)
        animateOut(.close)
    }

    func setAlwaysOnTop(_ enabled: Bool) {
        panel?.level = isPending || enabled ? .floating : .normal
    }

    func move(to origin: NSPoint, duration: TimeInterval) {
        guard let window, origin != window.frame.origin else { return }
        snapWorkItem?.cancel()
        programmaticMoveGeneration += 1
        let generation = programmaticMoveGeneration
        isProgrammaticallyMoving = true
        let targetFrame = NSRect(origin: origin, size: window.frame.size)

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            window.setFrame(targetFrame, display: true)
            isProgrammaticallyMoving = false
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.programmaticMoveGeneration == generation else { return }
                self.isProgrammaticallyMoving = false
            }
        }
    }

    func setExpanded(_ expanded: Bool) {
        guard let window else { return }
        let targetSize = expanded
            ? ShelfGeometry.expandedSize(itemCount: store.items.count)
            : ShelfGeometry.compactSize
        if expanded, compactOrigin == nil { compactOrigin = window.frame.origin }

        let screen = window.screen ?? NSScreen.screens.first
        let preferredOrigin: NSPoint
        if expanded, let screen {
            preferredOrigin = ShelfGeometry.resizedOrigin(
                frame: window.frame,
                targetSize: targetSize,
                in: screen.visibleFrame
            )
        } else {
            preferredOrigin = compactOrigin ?? window.frame.origin
        }
        let origin = screen.map {
            ShelfGeometry.clamp(preferredOrigin, size: targetSize, to: $0.visibleFrame)
        } ?? preferredOrigin

        let targetFrame = NSRect(origin: origin, size: targetSize)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            window.setFrame(targetFrame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(targetFrame, display: true)
            }
        }
        if !expanded { compactOrigin = nil }
        updateTrackingArea()
    }

    func updateExpandedSize(for itemCount: Int) {
        guard store.isExpanded, let window, let screen = window.screen else { return }
        let targetSize = ShelfGeometry.expandedSize(itemCount: itemCount)
        guard window.frame.size != targetSize else { return }
        let origin = ShelfGeometry.resizedOrigin(
            frame: window.frame,
            targetSize: targetSize,
            in: screen.visibleFrame
        )
        let targetFrame = NSRect(origin: origin, size: targetSize)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            window.setFrame(targetFrame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(targetFrame, display: true)
            }
        }
        updateTrackingArea()
    }

    private func updateTrackingArea() {
        guard let contentView = window?.contentView, let old = trackingArea else { return }
        contentView.removeTrackingArea(old)
        let new = NSTrackingArea(
            rect: contentView.bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        contentView.addTrackingArea(new)
        trackingArea = new
    }

    func windowDidBecomeKey(_ notification: Notification) { store.isFocused = true }

    func windowDidResignKey(_ notification: Notification) {
        store.isFocused = false
        if store.autoCollapseExpanded, store.isExpanded,
           isPreviewActive?() != true {
            store.toggleExpanded()
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard !isPending, !isAnimatingOut, !isProgrammaticallyMoving else { return }
        snapWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onSnapRequested?(self)
        }
        snapWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: item)
    }

    func windowWillClose(_ notification: Notification) {
        snapWorkItem?.cancel()
        onWillDismiss?(self)
        if let closeKeyMonitor { NSEvent.removeMonitor(closeKeyMonitor) }
        closeKeyMonitor = nil
        endDragGhost()
        onClosed?(self)
    }

    private func showWindowAnimated(activating: Bool) {
        guard let window else { return }
        isAnimatingOut = false
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let contentLayer = prepareContentLayer()

        if reduceMotion {
            window.alphaValue = 1
            contentLayer?.transform = CATransform3DIdentity
            if activating { window.makeKeyAndOrderFront(nil) }
            else { window.orderFrontRegardless() }
            return
        }

        window.alphaValue = 0
        contentLayer?.removeAllAnimations()
        contentLayer?.transform = CATransform3DIdentity
        if activating { window.makeKeyAndOrderFront(nil) }
        else { window.orderFrontRegardless() }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
        if let contentLayer {
            let animation = CAKeyframeAnimation(keyPath: "transform")
            animation.values = [
                CATransform3DMakeScale(0.94, 0.94, 1),
                CATransform3DMakeScale(1.012, 1.012, 1),
                CATransform3DIdentity
            ]
            animation.keyTimes = [0, 0.72, 1]
            animation.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeOut)
            ]
            animation.duration = 0.2
            animation.isRemovedOnCompletion = true
            contentLayer.add(animation, forKey: "dropPointAppear")
        }
    }

    private func animateOut(_ disposition: OutDisposition) {
        guard let window, !isAnimatingOut else { return }
        guard window.isVisible else {
            finishOut(disposition, restoring: window.frame.origin)
            return
        }
        isAnimatingOut = true
        let originalOrigin = window.frame.origin
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            window.orderOut(nil)
            finishOut(disposition, restoring: originalOrigin)
            return
        }

        let screenFrame = (window.screen ?? NSScreen.screens.first)?.frame ?? window.frame
        let exitOrigin = nearestEdgeExitOrigin(for: window.frame, in: screenFrame)
        let distance = hypot(exitOrigin.x - originalOrigin.x, exitOrigin.y - originalOrigin.y)
        let duration = min(0.42, 0.22 + TimeInterval(distance / 3_500))

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().setFrameOrigin(exitOrigin)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, let window = self.window else { return }
                window.orderOut(nil)
                self.finishOut(disposition, restoring: originalOrigin)
            }
        }
    }

    private func finishOut(_ disposition: OutDisposition, restoring originalOrigin: NSPoint) {
        switch disposition {
        case .hide:
            window?.setFrameOrigin(originalOrigin)
            window?.alphaValue = 1
            isAnimatingOut = false
        case .close:
            isAnimatingOut = false
            close()
        }
    }

    private func nearestEdgeExitOrigin(for frame: NSRect, in screenFrame: NSRect) -> NSPoint {
        let edgeDistances: [(distance: CGFloat, origin: NSPoint)] = [
            (
                abs(frame.minX - screenFrame.minX),
                NSPoint(x: screenFrame.minX - frame.width - 8, y: frame.origin.y)
            ),
            (
                abs(screenFrame.maxX - frame.maxX),
                NSPoint(x: screenFrame.maxX + 8, y: frame.origin.y)
            ),
            (
                abs(frame.minY - screenFrame.minY),
                NSPoint(x: frame.origin.x, y: screenFrame.minY - frame.height - 8)
            ),
            (
                abs(screenFrame.maxY - frame.maxY),
                NSPoint(x: frame.origin.x, y: screenFrame.maxY + 8)
            ),
        ]
        return edgeDistances.min(by: { $0.distance < $1.distance })?.origin ?? frame.origin
    }

    private static func isCommandW(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers == .command else { return false }
        return event.keyCode == 13 || event.charactersIgnoringModifiers?.lowercased() == "w"
    }

    private func handlePrecisionScroll(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas,
              event.momentumPhase.isEmpty,
              !store.items.isEmpty,
              !store.isPullClearing else {
            return false
        }

        let downwardDelta = event.isDirectionInvertedFromDevice
            ? event.scrollingDeltaY
            : -event.scrollingDeltaY
        let upwardDelta = max(0, -downwardDelta)
        let phase = event.phase

        if phase.contains(.began) || phase.contains(.mayBegin) {
            resetPullDownGesture()
            guard downwardDelta > 0 else { return false }
            isTrackingPullDown = true
            store.isDismissGestureActive = true
        } else if !isTrackingPullDown {
            guard phase.contains(.changed), downwardDelta > 0 else { return false }
            isTrackingPullDown = true
            store.isDismissGestureActive = true
        }

        if phase.contains(.cancelled) || phase.contains(.ended) {
            let wasTracking = isTrackingPullDown
            resetPullDownGesture(preservingCompletedVisuals: didTriggerPullDownDismiss)
            return wasTracking
        }

        guard isTrackingPullDown else { return false }
        pullDownDistance = max(0, pullDownDistance + max(0, downwardDelta) - upwardDelta * 1.35)
        store.dismissGestureProgress = min(pullDownDistance / 108, 1)

        if store.dismissGestureProgress >= 1, !didTriggerPullDownDismiss {
            didTriggerPullDownDismiss = true
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            store.clearFromPullGesture()
        }
        return true
    }

    private func resetPullDownGesture(preservingCompletedVisuals: Bool = false) {
        isTrackingPullDown = false
        pullDownDistance = 0
        didTriggerPullDownDismiss = false
        store.isDismissGestureActive = false
        if !preservingCompletedVisuals, !store.isPullClearing {
            store.dismissGestureProgress = 0
        }
    }

    private func prepareContentLayer() -> CALayer? {
        guard let contentView = window?.contentView else { return nil }
        contentView.wantsLayer = true
        guard let layer = contentView.layer else { return nil }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        CATransaction.commit()
        return layer
    }

    func beginDragGhost() {
        guard let window, let contentView = window.contentView else { return }
        endDragGhost()

        let rect = dragGhostRect
        guard let image = makeDragGhostImage(size: rect.size) else { return }
        let imageView = NSImageView(frame: rect)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.opacity = 0.85
        contentView.addSubview(imageView)
        dragGhostView = imageView

        dragGhostStart = NSEvent.mouseLocation
        dragGhostMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, event.type == .leftMouseDragged else { return }
            let current = NSEvent.mouseLocation
            let dx = current.x - self.dragGhostStart.x
            let dy = current.y - self.dragGhostStart.y
            self.dragGhostView?.frame.origin = NSPoint(
                x: rect.origin.x + dx,
                y: rect.origin.y - dy
            )
        }
    }

    private func makeDragGhostImage(size: NSSize) -> NSImage? {
        let items = Array(store.selectedItems.prefix(3))
        guard !items.isEmpty else { return nil }

        return NSImage(size: size, flipped: false) { _ in
            for index in items.indices.reversed() {
                let item = items[index]
                let xOffset: CGFloat = index == 1 ? -8 : (index == 2 ? 8 : 0)
                let yOffset: CGFloat = index == 0 ? 0 : (index == 1 ? 2 : 3)
                let rotation: CGFloat = index == 1 ? -7 : (index == 2 ? 7 : 0)
                let imageRect = NSRect(
                    x: (size.width - 76) / 2 + xOffset,
                    y: (size.height - 76) / 2 + yOffset,
                    width: 76,
                    height: 76
                )

                NSGraphicsContext.saveGraphicsState()
                let transform = NSAffineTransform()
                transform.translateX(by: imageRect.midX, yBy: imageRect.midY)
                transform.rotate(byDegrees: rotation)
                transform.translateX(by: -imageRect.midX, yBy: -imageRect.midY)
                transform.concat()
                item.image.draw(
                    in: imageRect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high]
                )
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
    }

    func endDragGhost() {
        dragGhostView?.removeFromSuperview()
        dragGhostView = nil
        if let monitor = dragGhostMonitor { NSEvent.removeMonitor(monitor) }
        dragGhostMonitor = nil
    }
}
