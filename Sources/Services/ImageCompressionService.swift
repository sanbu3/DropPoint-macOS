import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImageCompressionResult: Sendable {
    let data: Data
    let originalByteCount: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let didMeetTarget: Bool
}

enum ImageCompressionError: LocalizedError {
    case invalidTarget
    case unreadableImage
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidTarget: "目标大小必须至少为 10 KB。"
        case .unreadableImage: "无法读取图片内容。"
        case .encodingFailed: "无法生成压缩后的 JPEG。"
        }
    }
}

enum ImageCompressionService {
    private static let minimumTargetBytes = 10 * 1_024
    private static let minimumQuality: CGFloat = 0.05
    private static let maximumQuality: CGFloat = 0.95

    static func compressFile(
        at sourceURL: URL,
        to destinationURL: URL,
        targetBytes: Int
    ) throws -> ImageCompressionResult {
        guard targetBytes >= minimumTargetBytes else {
            throw ImageCompressionError.invalidTarget
        }
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw ImageCompressionError.unreadableImage
        }

        let originalByteCount = (try? sourceURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize) ?? 0
        let result = try compress(
            source: source,
            originalPixelSize: CGSize(width: width, height: height),
            originalByteCount: originalByteCount,
            targetBytes: targetBytes
        )
        try result.data.write(to: destinationURL, options: .atomic)
        return result
    }

    static func compress(
        image: CGImage,
        originalByteCount: Int = 0,
        targetBytes: Int
    ) throws -> ImageCompressionResult {
        guard targetBytes >= minimumTargetBytes else {
            throw ImageCompressionError.invalidTarget
        }
        guard let sourceData = jpegData(for: image, quality: maximumQuality),
              let source = CGImageSourceCreateWithData(sourceData as CFData, nil) else {
            throw ImageCompressionError.encodingFailed
        }
        return try compress(
            source: source,
            originalPixelSize: CGSize(width: image.width, height: image.height),
            originalByteCount: originalByteCount,
            targetBytes: targetBytes
        )
    }

    private static func compress(
        source: CGImageSource,
        originalPixelSize: CGSize,
        originalByteCount: Int,
        targetBytes: Int
    ) throws -> ImageCompressionResult {
        var maxPixelSize = max(Int(originalPixelSize.width), Int(originalPixelSize.height))
        var smallestCandidate: (data: Data, image: CGImage)?

        for _ in 0..<10 {
            guard let decoded = thumbnail(from: source, maxPixelSize: maxPixelSize),
                  let image = jpegReadyImage(decoded),
                  let minimumData = jpegData(for: image, quality: minimumQuality) else {
                throw ImageCompressionError.encodingFailed
            }

            if smallestCandidate.map({ minimumData.count < $0.data.count }) ?? true {
                smallestCandidate = (minimumData, image)
            }

            if minimumData.count <= targetBytes {
                let data = bestJPEGData(for: image, targetBytes: targetBytes) ?? minimumData
                return ImageCompressionResult(
                    data: data,
                    originalByteCount: originalByteCount,
                    pixelWidth: image.width,
                    pixelHeight: image.height,
                    didMeetTarget: data.count <= targetBytes
                )
            }

            guard maxPixelSize > 64 else { break }
            let ratio = sqrt(Double(targetBytes) / Double(minimumData.count)) * 0.9
            let scale = min(0.85, max(0.2, ratio))
            let nextSize = max(64, Int(Double(maxPixelSize) * scale))
            maxPixelSize = nextSize < maxPixelSize ? nextSize : maxPixelSize - 1
        }

        guard let smallestCandidate else { throw ImageCompressionError.encodingFailed }
        return ImageCompressionResult(
            data: smallestCandidate.data,
            originalByteCount: originalByteCount,
            pixelWidth: smallestCandidate.image.width,
            pixelHeight: smallestCandidate.image.height,
            didMeetTarget: smallestCandidate.data.count <= targetBytes
        )
    }

    private static func thumbnail(
        from source: CGImageSource,
        maxPixelSize: Int
    ) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func jpegReadyImage(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private static func bestJPEGData(
        for image: CGImage,
        targetBytes: Int
    ) -> Data? {
        guard let maximumData = jpegData(for: image, quality: maximumQuality) else {
            return nil
        }
        if maximumData.count <= targetBytes { return maximumData }

        var lower = minimumQuality
        var upper = maximumQuality
        var best = jpegData(for: image, quality: minimumQuality)
        for _ in 0..<10 {
            let quality = (lower + upper) / 2
            guard let data = jpegData(for: image, quality: quality) else { break }
            if data.count <= targetBytes {
                best = data
                lower = quality
            } else {
                upper = quality
            }
        }
        return best
    }

    private static func jpegData(for image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: 1,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
