import AppKit

enum ShelfGeometry {
    static let compactSize = NSSize(width: 198, height: 207)
    static let expandedSize = NSSize(width: 432, height: 390)
    static let cascadeOffset: CGFloat = 24
    static let snapDistance: CGFloat = 44
    static let shelfSpacing: CGFloat = 12
    static let dockingInset: CGFloat = 10

    static func dockingArea(in visibleFrame: NSRect) -> NSRect {
        visibleFrame.insetBy(dx: dockingInset, dy: dockingInset)
    }

    static func expandedSize(itemCount: Int) -> NSSize {
        let width: CGFloat = itemCount <= 2 ? 336 : expandedSize.width
        let rows = max(1, Int(ceil(Double(itemCount) / 3.0)))
        switch rows {
        case 1: return NSSize(width: width, height: 224)
        case 2: return NSSize(width: width, height: 344)
        default: return NSSize(width: width, height: expandedSize.height)
        }
    }

    static func origin(
        for position: ShelfPosition,
        in workArea: NSRect,
        cursor: NSPoint,
        size: NSSize = compactSize
    ) -> NSPoint {
        let left = workArea.minX
        let right = workArea.maxX - size.width
        let bottom = workArea.minY
        let top = workArea.maxY - size.height

        switch position {
        case .topLeft: return NSPoint(x: left, y: top)
        case .topRight: return NSPoint(x: right, y: top)
        case .bottomLeft: return NSPoint(x: left, y: bottom)
        case .bottomRight: return NSPoint(x: right, y: bottom)
        case .center:
            return NSPoint(
                x: workArea.midX - size.width / 2,
                y: workArea.midY - size.height / 2
            )
        case .cursor:
            let above = cursor.y + 36
            let below = cursor.y - 36 - size.height
            let y = above + size.height <= workArea.maxY ? above : below
            return clamp(
                NSPoint(x: cursor.x - size.width / 2, y: y),
                size: size,
                to: workArea
            )
        }
    }

    static func quickShelfOrigin(statusFrame: NSRect, in workArea: NSRect) -> NSPoint {
        clamp(
            NSPoint(
                x: statusFrame.midX - compactSize.width / 2,
                y: statusFrame.minY - compactSize.height - 6
            ),
            size: compactSize,
            to: workArea.insetBy(dx: 8, dy: 8)
        )
    }

    static func clamp(_ point: NSPoint, size: NSSize, to area: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(point.x, area.minX), max(area.minX, area.maxX - size.width)),
            y: min(max(point.y, area.minY), max(area.minY, area.maxY - size.height))
        )
    }

    static func resizedOrigin(
        frame: NSRect,
        targetSize: NSSize,
        in area: NSRect
    ) -> NSPoint {
        let raw = NSPoint(
            x: frame.midX - targetSize.width / 2,
            y: frame.midY - targetSize.height / 2
        )
        return clamp(raw, size: targetSize, to: area)
    }
    static func snappedOrigin(frame: NSRect, in workArea: NSRect) -> NSPoint {
        var result = frame.origin
        let right = workArea.maxX - frame.width
        let top = workArea.maxY - frame.height
        if abs(result.x - workArea.minX) <= snapDistance { result.x = workArea.minX }
        else if abs(result.x - right) <= snapDistance { result.x = right }
        if abs(result.y - workArea.minY) <= snapDistance { result.y = workArea.minY }
        else if abs(result.y - top) <= snapDistance { result.y = top }
        return result
    }

    static func nonOverlappingOrigin(
        preferred: NSPoint,
        size: NSSize = compactSize,
        in workArea: NSRect,
        occupiedFrames: [NSRect]
    ) -> NSPoint {
        let clampedPreferred = clamp(preferred, size: size, to: workArea)
        let stepX = size.width + shelfSpacing
        let stepY = size.height + shelfSpacing
        var candidates = [clampedPreferred]

        var y = workArea.minY
        while y <= workArea.maxY - size.height + 0.5 {
            var x = workArea.minX
            while x <= workArea.maxX - size.width + 0.5 {
                candidates.append(NSPoint(x: x, y: y))
                x += stepX
            }
            y += stepY
        }

        candidates.sort {
            squaredDistance($0, clampedPreferred) < squaredDistance($1, clampedPreferred)
        }
        return candidates.first { candidate in
            let frame = NSRect(origin: candidate, size: size)
            return !occupiedFrames.contains { frame.intersects($0) }
        } ?? clampedPreferred
    }

    private static func squaredDistance(_ first: NSPoint, _ second: NSPoint) -> CGFloat {
        let dx = first.x - second.x
        let dy = first.y - second.y
        return dx * dx + dy * dy
    }
}

enum ShelfIdlePolicy {
    static func shouldSchedule(delay: TimeInterval) -> Bool { delay > 0 }
}

enum ShelfActivationPolicy {
    static func allowsShakeSpawn(hasOpenShelf: Bool) -> Bool {
        true
    }
}
