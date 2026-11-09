import AppKit
import ImageIO
import QuartzCore

@MainActor
final class ShelfArtworkPlayer: NSView {
    struct Artwork {
        let frames: [CGImage]
        let duration: TimeInterval
        let keyTimes: [NSNumber]
    }

    private static var cache: [String: Artwork] = [:]
    private var configuration: String?
    private let imageLayer = CALayer()

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.contentsScale = 2
        layer?.addSublayer(imageLayer)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    static func artwork(named name: String) -> Artwork? {
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name + " Timeline", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let frames = (0..<CGImageSourceGetCount(source)).compactMap {
            CGImageSourceCreateImageAtIndex(source, $0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        guard !frames.isEmpty else { return nil }
        var elapsed: TimeInterval = 0
        var starts: [Double] = []
        for index in frames.indices {
            starts.append(elapsed)
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
            let png = properties?[kCGImagePropertyPNGDictionary as String] as? [String: Any]
            let delay = png?[kCGImagePropertyAPNGUnclampedDelayTime as String] as? Double
                ?? png?[kCGImagePropertyAPNGDelayTime as String] as? Double ?? (1.0 / 30)
            elapsed += delay
        }
        let artwork = Artwork(frames: frames, duration: elapsed,
                              keyTimes: starts.map { NSNumber(value: $0 / elapsed) })
        cache[name] = artwork
        return artwork
    }

    func configure(name: String, enabled: Bool, once: Bool, idle: Bool) {
        let key = "\(name)-\(enabled)-\(once)-\(idle)"
        guard configuration != key else { return }
        configuration = key
        stop()
        guard let artwork = Self.artwork(named: name) else { return }
        imageLayer.contents = artwork.frames.first
        guard enabled else { return }
        let hold = idle ? Double.random(in: 3...8) : 0
        let total = artwork.duration + hold
        let animation = CAKeyframeAnimation(keyPath: "contents")
        var values = artwork.frames
        var times = artwork.keyTimes.map { NSNumber(value: $0.doubleValue * artwork.duration / total) }
        // Explicit final keyframe also holds the completed drawing during idle.
        values.append(artwork.frames.last!)
        times.append(1)
        animation.values = values
        animation.keyTimes = times
        animation.calculationMode = .discrete
        animation.duration = total
        animation.repeatCount = idle || !once ? .infinity : 1
        imageLayer.contents = once ? artwork.frames.last : artwork.frames.first
        imageLayer.add(animation, forKey: "originalArtwork")
    }

    func stop() { imageLayer.removeAnimation(forKey: "originalArtwork") }
}
