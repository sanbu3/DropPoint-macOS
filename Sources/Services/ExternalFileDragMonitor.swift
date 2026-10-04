import AppKit

struct ExternalDragActivationState {
    private(set) var didActivate = false
    private var shakeSamples: [(x: CGFloat, date: Date)] = []

    mutating func reset() {
        didActivate = false
        shakeSamples.removeAll()
    }

    mutating func activateForModifier(_ isPressed: Bool) -> Bool {
        guard isPressed, !didActivate else { return false }
        didActivate = true
        return true
    }

    mutating func activateForShake(
        x: CGFloat,
        date: Date,
        sensitivity: ShakeSensitivity
    ) -> Bool {
        guard !didActivate else { return false }
        shakeSamples.append((x, date))
        shakeSamples.removeAll {
            date.timeIntervalSince($0.date) > sensitivity.samplingWindow
        }
        guard shakeSamples.count >= 3, let first = shakeSamples.first else { return false }

        var reversals = 0
        var direction = 0
        var extreme = first.x
        for sample in shakeSamples.dropFirst() {
            let delta = sample.x - extreme
            if direction == 0 {
                guard abs(delta) >= sensitivity.minimumExcursion else { continue }
                direction = delta > 0 ? 1 : -1
                extreme = sample.x
            } else if direction > 0 {
                if sample.x > extreme {
                    extreme = sample.x
                } else if extreme - sample.x >= sensitivity.minimumExcursion {
                    direction = -1
                    extreme = sample.x
                    reversals += 1
                }
            } else if sample.x < extreme {
                extreme = sample.x
            } else if sample.x - extreme >= sensitivity.minimumExcursion {
                direction = 1
                extreme = sample.x
                reversals += 1
            }
        }
        guard reversals >= sensitivity.requiredReversals else { return false }
        didActivate = true
        return true
    }
}

@MainActor
final class ExternalFileDragMonitor {
    var shouldIgnore: (() -> Bool)?
    var onFileDragEnd: (() -> Void)?
    var onModifierActivation: (() -> Void)?
    var onShake: (() -> Void)?
    var shakeActivationEnabled = true
    var modifierActivationEnabled = true
    var activationModifier: ActivationModifier = .shift
    var sensitivity: ShakeSensitivity = .medium

    private let dragPasteboard: NSPasteboard
    private var globalMonitor: Any?
    private var idleTimer: Timer?
    private var idleChangeCount = 0
    private var sessionBaseline = 0
    private(set) var activeFileDrag = false
    private var mouseDownLocation: NSPoint = .zero
    private var activationState = ExternalDragActivationState()

    init(dragPasteboard: NSPasteboard = NSPasteboard(name: .drag)) {
        self.dragPasteboard = dragPasteboard
        idleChangeCount = dragPasteboard.changeCount
    }

    func start() {
        guard globalMonitor == nil else { return }
        idleChangeCount = dragPasteboard.changeCount
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.samplePasteboard(
                    mouseButtonPressed: NSEvent.pressedMouseButtons & 1 != 0,
                    mouseLocation: NSEvent.mouseLocation
                )
            }
        }
        timer.tolerance = 0.04
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = nil
        idleTimer?.invalidate()
        idleTimer = nil
        finishDrag()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            beginPotentialDrag(at: NSEvent.mouseLocation)
        case .leftMouseDragged:
            if !activeFileDrag { detectFileDragStart(at: NSEvent.mouseLocation) }
            if activeFileDrag {
                detectModifierActivation(in: event)
                detectShake(at: NSEvent.mouseLocation)
            }
        case .leftMouseUp:
            finishDrag()
            idleChangeCount = dragPasteboard.changeCount
        default:
            break
        }
    }

    func beginPotentialDrag(at location: NSPoint) {
        if activeFileDrag { finishDrag() }
        sessionBaseline = idleChangeCount
        mouseDownLocation = location
        activationState.reset()
    }

    private func detectFileDragStart(at current: NSPoint) {
        let dx = abs(current.x - mouseDownLocation.x)
        let dy = abs(current.y - mouseDownLocation.y)
        guard dx > 3 || dy > 3,
              shouldIgnore?() != true,
              dragPasteboard.changeCount != sessionBaseline,
              FileDropImporter.canImport(from: dragPasteboard) else { return }
        activeFileDrag = true
    }

    private func finishDrag() {
        guard activeFileDrag else { return }
        activeFileDrag = false
        activationState.reset()
        onFileDragEnd?()
    }

    func samplePasteboard(mouseButtonPressed: Bool, mouseLocation: NSPoint) {
        if mouseButtonPressed {
            if !activeFileDrag {
                detectFileDragStart(at: mouseLocation)
            }
            if activeFileDrag {
                detectModifierActivation(using: NSEvent.modifierFlags)
                detectShake(at: mouseLocation)
            }
            return
        }
        if activeFileDrag { finishDrag() }
        idleChangeCount = dragPasteboard.changeCount
    }

    private func detectShake(at point: NSPoint) {
        guard shakeActivationEnabled else { return }
        if activationState.activateForShake(
            x: point.x,
            date: Date(),
            sensitivity: sensitivity
        ) {
            onShake?()
        }
    }

    private func detectModifierActivation(in event: NSEvent) {
        detectModifierActivation(using: event.modifierFlags.union(NSEvent.modifierFlags))
    }

    private func detectModifierActivation(using modifierFlags: NSEvent.ModifierFlags) {
        guard modifierActivationEnabled else { return }
        let pressed = modifierFlags.contains(activationModifier.eventFlag)
        if activationState.activateForModifier(pressed) {
            onModifierActivation?()
        }
    }
}
