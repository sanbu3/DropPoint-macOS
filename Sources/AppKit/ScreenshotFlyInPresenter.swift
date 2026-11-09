import AppKit
import QuartzCore

/// A short, non-interactive fly-in used after a double-Command screenshot.
/// The panel is transparent, has no AppKit shadow, ignores the mouse and joins
/// all Spaces so the thumbnail can travel from a window to the shelf.
@MainActor
enum ScreenshotFlyInPresenter {
    private final class FlyInPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    static func show(image: CGImage, from source: NSRect, to destination: NSPoint) {
        guard let firstScreen = NSScreen.screens.first else { return }
        let union = NSScreen.screens.reduce(firstScreen.frame) { $0.union($1.frame) }
        let panel = FlyInPanel(
            contentRect: union,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)

        let root = NSView(frame: NSRect(origin: .zero, size: union.size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = root

        let start = source.offsetBy(dx: -union.minX, dy: -union.minY)
        let endSize = NSSize(width: 68, height: 68)
        var end = NSRect(
            x: destination.x - union.minX - endSize.width / 2,
            y: destination.y - union.minY - endSize.height / 2,
            width: endSize.width,
            height: endSize.height
        )
        end.origin.x = min(max(end.origin.x, 8), union.width - endSize.width - 8)
        end.origin.y = min(max(end.origin.y, 8), union.height - endSize.height - 8)

        let layer = CALayer()
        layer.contents = image
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
        layer.cornerRadius = 10
        layer.borderWidth = 1
        layer.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.bounds = CGRect(origin: .zero, size: start.size)
        layer.position = CGPoint(x: start.midX, y: start.midY)
        root.layer?.addSublayer(layer)

        let group = CAAnimationGroup()
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: CGPoint(x: start.midX, y: start.midY))
        position.toValue = NSValue(point: CGPoint(x: end.midX, y: end.midY))
        let bounds = CABasicAnimation(keyPath: "bounds")
        bounds.fromValue = NSValue(rect: CGRect(origin: .zero, size: start.size))
        bounds.toValue = NSValue(rect: CGRect(origin: .zero, size: end.size))
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [1, 1, 0.15]
        opacity.keyTimes = [0, 0.82, 1]
        group.animations = [position, bounds, opacity]
        group.duration = 0.52
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            panel.orderOut(nil)
            panel.close()
        }
        layer.position = CGPoint(x: end.midX, y: end.midY)
        layer.bounds = CGRect(origin: .zero, size: end.size)
        layer.opacity = 0.15
        layer.add(group, forKey: "dropPointScreenshotFlyIn")
        CATransaction.commit()

        panel.orderFrontRegardless()
    }
}
