import AppKit
import SwiftUI

final class ShelfPanel: NSPanel {
    var onUserInteraction: (() -> Void)?
    var onPrecisionScroll: ((NSEvent) -> Bool)?
    var onGestureEvent: ((NSEvent) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        onGestureEvent?(event)
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

private final class ShelfHintPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ShelfWindowController: NSWindowController, NSWindowDelegate {
    private enum OutDisposition {
        case hide
        case close
    }

    let store: ShelfStore
    var onClosed: ((ShelfWindowController) -> Void)?
    var onWillDismiss: ((ShelfWindowController) -> Void)?
    var isPreviewActive: (() -> Bool)?
    var onSnapRequested: ((ShelfWindowController) -> Void)?
    var onImmediateSnapRequested: ((ShelfWindowController) -> Void)?
    var onInteraction: ((ShelfWindowController) -> Void)?
    var onHoverChanged: ((ShelfWindowController, Bool) -> Void)?

    private var compactOrigin: NSPoint?
    private var snapWorkItem: DispatchWorkItem?
    private var closeKeyMonitor: Any?
    private var isAnimatingOut = false
    private var visibilityGeneration = 0
    private var isProgrammaticallyMoving = false
    private var programmaticMoveGeneration = 0
    private var isTrackingPullDown = false
    private var pullDownDistance: CGFloat = 0
    private var didTriggerPullDownDismiss = false
    private var optionGesture = OptionHoldClearGesture()
    private var optionHoldTimer: Timer?
    private(set) var optionClearHintPanel: NSPanel?

    init(store: ShelfStore, alwaysOnTop: Bool) {
        self.store = store

        let size = ShelfGeometry.compactSize
        let panel = ShelfPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.level = alwaysOnTop ? .floating : .normal
        panel.title = "DropPoint"

        let hostingView = ShelfDropHostingView(store: store)
        hostingView.focusRingType = .none
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView

        super.init(window: panel)
        panel.delegate = self
        panel.onUserInteraction = { [weak self] in
            guard let self else { return }
            self.onInteraction?(self)
        }
        panel.onGestureEvent = { [weak self] event in
            self?.updateKeyboardNavigation(for: event)
            self?.handleOptionGestureEvent(event)
        }
        store.onOptionClearPresentationChanged = { [weak self] in
            self?.updateOptionClearHint()
        }
        panel.onPrecisionScroll = { [weak self] event in
            self?.handlePrecisionScroll(event) ?? false
        }
        hostingView.onTwoFingerTap = { [weak self] in
            guard let self else { return }
            self.onInteraction?(self)
            self.onImmediateSnapRequested?(self)
        }
        hostingView.onHoverChanged = { [weak self] isInside in
            guard let self else { return }
            self.store.isHovered = isInside
            self.onHoverChanged?(self, isInside)
        }
        closeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let eventWindow = event.window,
                  eventWindow === self.window,
                  Self.isCommandW(event) else { return event }
            self.closeAnimated()
            return nil
        }

    }

    required init?(coder: NSCoder) { nil }

    var panel: NSPanel? { window as? NSPanel }

    func show(at origin: NSPoint, activating: Bool) {
        window?.setFrameOrigin(origin)
        showWindowAnimated(activating: activating || store.focusShelfOnShow)
    }

    func showExistingAnimated(activating: Bool) {
        showWindowAnimated(activating: activating || store.focusShelfOnShow)
    }

    func orderOutAnimated() {
        cancelOptionHold()
        resetPullDownGesture()
        onWillDismiss?(self)
        animateOut(.hide)
    }

    func closeAnimated() {
        cancelOptionHold()
        resetPullDownGesture()
        onWillDismiss?(self)
        animateOut(.close)
    }

    func setAlwaysOnTop(_ enabled: Bool) {
        panel?.level = enabled ? .floating : .normal
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
    }

    func windowDidBecomeKey(_ notification: Notification) {
        store.isKeyboardNavigating = false
        store.isFocused = true
    }

    func windowDidResignKey(_ notification: Notification) {
        cancelOptionHold()
        resetPullDownGesture()
        store.isFocused = false
        store.isKeyboardNavigating = false
        if store.autoCollapseExpanded, store.isExpanded,
           isPreviewActive?() != true {
            store.toggleExpanded()
        }
    }

    func windowDidMove(_ notification: Notification) {
        updateOptionClearHint()
        guard !isAnimatingOut, !isProgrammaticallyMoving else { return }
        snapWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onSnapRequested?(self)
        }
        snapWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: item)
    }

    func windowDidResize(_ notification: Notification) {
        updateOptionClearHint()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        updateOptionClearHint()
    }

    func windowWillClose(_ notification: Notification) {
        cancelOptionHold()
        store.onOptionClearPresentationChanged = nil
        store.cancelPendingWork()
        snapWorkItem?.cancel()
        onWillDismiss?(self)
        if let closeKeyMonitor { NSEvent.removeMonitor(closeKeyMonitor) }
        closeKeyMonitor = nil
        onClosed?(self)
    }

    private func showWindowAnimated(activating: Bool) {
        guard let window else { return }
        visibilityGeneration += 1
        isAnimatingOut = false
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let contentLayer = prepareContentLayer()

        if reduceMotion {
            contentLayer?.removeAllAnimations()
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

        if let contentLayer {
            contentViewLayoutBeforePresentation()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.2
            let group = CAAnimationGroup()
            group.animations = [fade]
            if window.backingScaleFactor > 1 {
                let scale = CABasicAnimation(keyPath: "transform.scale")
                scale.fromValue = 0.98
                scale.toValue = 1
                scale.duration = 0.2
                group.animations?.append(scale)
            }
            group.duration = 0.2
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.61, 0.36, 1)
            contentLayer.add(group, forKey: "dropPointAppear")
        }
        window.alphaValue = 1
    }

    private func contentViewLayoutBeforePresentation() {
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.contentView?.displayIfNeeded()
    }

    private func animateOut(_ disposition: OutDisposition) {
        guard let window, !isAnimatingOut else { return }
        guard window.isVisible else {
            finishOut(disposition, restoring: window.frame.origin)
            return
        }
        isAnimatingOut = true
        store.isHovered = false
        visibilityGeneration += 1
        let generation = visibilityGeneration
        let originalOrigin = window.frame.origin
        let contentLayer = prepareContentLayer()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            contentLayer?.removeAllAnimations()
            contentLayer?.transform = CATransform3DIdentity
            window.orderOut(nil)
            finishOut(disposition, restoring: originalOrigin)
            return
        }

        contentLayer?.removeAllAnimations()
        contentLayer?.transform = CATransform3DIdentity
        if let contentLayer, window.backingScaleFactor > 1 {
            let animation = CAKeyframeAnimation(keyPath: "transform.scale")
            animation.values = [1, 0.99, 0.96]
            animation.keyTimes = [0, 0.38, 1]
            animation.timingFunctions = [
                CAMediaTimingFunction(name: .easeIn),
                CAMediaTimingFunction(controlPoints: 0.48, 0, 0.9, 0.42)
            ]
            animation.duration = 0.16
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            contentLayer.add(animation, forKey: "dropPointDisappear")
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.visibilityGeneration == generation,
                      let window = self.window else { return }
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

    private static func isCommandW(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers == .command else { return false }
        return event.keyCode == 13 || event.charactersIgnoringModifiers?.lowercased() == "w"
    }

    func updateKeyboardNavigation(for event: NSEvent) {
        switch event.type {
        case .keyDown where event.keyCode == 48:
            // Shift-Tab is the global shelf activation shortcut, not a request
            // to highlight the first control in a newly activated shelf.
            if event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                store.isKeyboardNavigating = true
            }
        case .leftMouseDown, .rightMouseDown:
            store.isKeyboardNavigating = false
        default:
            break
        }
    }

    private func updateOptionClearHint() {
        guard store.isOptionClearActive, let window, window.isVisible,
              let screen = window.screen ?? NSScreen.screens.first else {
            if let hint = optionClearHintPanel {
                window?.removeChildWindow(hint)
                hint.orderOut(nil)
                optionClearHintPanel = nil
            }
            return
        }
        let frame = ShelfGeometry.optionClearHintFrame(for: window.frame, in: screen.visibleFrame)
        let above = frame.minY >= window.frame.maxY
        let hint: NSPanel
        if let existing = optionClearHintPanel {
            hint = existing
        } else {
            hint = ShelfHintPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            hint.backgroundColor = .clear
            hint.isOpaque = false
            hint.hasShadow = false
            hint.ignoresMouseEvents = true
            hint.hidesOnDeactivate = false
            hint.isReleasedWhenClosed = false
            hint.animationBehavior = .none
            hint.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let hosting = NSHostingView(rootView: OptionClearHintView(attachedAbove: above))
            hosting.sizingOptions = []
            hosting.focusRingType = .none
            hint.contentView = hosting
            optionClearHintPanel = hint
            window.addChildWindow(hint, ordered: .above)
        }
        hint.appearance = window.effectiveAppearance
        if let hosting = hint.contentView as? NSHostingView<OptionClearHintView> {
            hosting.rootView = OptionClearHintView(attachedAbove: above)
        }
        hint.setFrame(frame, display: true)
        hint.orderFront(nil)
    }

    private func handleOptionGestureEvent(_ event: NSEvent) {
        guard window?.isKeyWindow == true, store.isFocused else {
            cancelOptionHold()
            return
        }
        switch event.type {
        case .flagsChanged:
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard event.keyCode == 58 || event.keyCode == 61,
                  modifiers.isEmpty || modifiers == .option,
                  !store.items.isEmpty, !store.isDraggingOut, !store.isDropTargeted,
                  !store.isClearing, !store.isPullClearing else {
                cancelOptionHold()
                return
            }
            let holding = optionGesture.update(
                optionPressed: modifiers == .option,
                timestamp: event.timestamp,
                doubleClickInterval: NSEvent.doubleClickInterval
            )
            guard holding else {
                optionHoldTimer?.invalidate()
                optionHoldTimer = nil
                store.isOptionClearActive = false
                store.optionClearProgress = 0
                return
            }
            onInteraction?(self)
            guard optionHoldTimer == nil else { return }
            resetPullDownGesture()
            store.isOptionClearActive = true
            store.optionClearProgress = 0
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.advanceOptionHold() }
            }
            timer.tolerance = 0.005
            RunLoop.main.add(timer, forMode: .common)
            optionHoldTimer = timer
        case .keyDown, .leftMouseDown, .rightMouseDown, .leftMouseDragged, .scrollWheel:
            cancelOptionHold()
        default:
            break
        }
    }

    private func advanceOptionHold() {
        guard window?.isVisible == true, window?.isKeyWindow == true,
              store.isFocused, !store.items.isEmpty, !store.isDraggingOut,
              !store.isDropTargeted, !store.isClearing, !store.isPullClearing,
              NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]) == .option else {
            cancelOptionHold()
            return
        }
        let progress = optionGesture.progress(at: ProcessInfo.processInfo.systemUptime)
        store.optionClearProgress = progress
        if progress >= 1 {
            cancelOptionHold()
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            store.clearKeepingEmptyShelf()
        }
    }

    private func cancelOptionHold() {
        optionHoldTimer?.invalidate()
        optionHoldTimer = nil
        optionGesture.reset()
        store.isOptionClearActive = false
        store.optionClearProgress = 0
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
        layer.allowsEdgeAntialiasing = true
        layer.minificationFilter = .trilinear
        layer.magnificationFilter = .trilinear
        CATransaction.commit()
        return layer
    }

}

/// Pure timing state, using event timestamps / system uptime rather than wall-clock dates.
struct OptionHoldClearGesture {
    static let holdDuration: TimeInterval = 1.2
    private var isPressed = false
    private var firstPressAt: TimeInterval?
    private var firstReleaseAt: TimeInterval?
    private(set) var holdStartedAt: TimeInterval?

    mutating func update(
        optionPressed: Bool,
        timestamp: TimeInterval,
        doubleClickInterval: TimeInterval
    ) -> Bool {
        guard optionPressed != isPressed else { return holdStartedAt != nil }
        isPressed = optionPressed
        if optionPressed {
            if let released = firstReleaseAt, timestamp >= released,
               timestamp - released <= doubleClickInterval {
                holdStartedAt = timestamp
                firstPressAt = nil
                firstReleaseAt = nil
            } else {
                firstPressAt = timestamp
                firstReleaseAt = nil
                holdStartedAt = nil
            }
        } else if holdStartedAt != nil {
            reset()
        } else {
            if let pressed = firstPressAt, timestamp >= pressed,
               timestamp - pressed <= doubleClickInterval {
                firstReleaseAt = timestamp
            } else {
                firstReleaseAt = nil
            }
            firstPressAt = nil
        }
        return holdStartedAt != nil
    }

    func progress(at timestamp: TimeInterval) -> CGFloat {
        guard let started = holdStartedAt, isPressed else { return 0 }
        return min(max((timestamp - started) / Self.holdDuration, 0), 1)
    }

    mutating func reset() {
        isPressed = false
        firstPressAt = nil
        firstReleaseAt = nil
        holdStartedAt = nil
    }
}
