import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

struct MaskRegion: Identifiable, Equatable {
    let id = UUID()
    /// Fractions of the upright image, with the origin at the top left.
    let box: CGRect
    var covered = true
    var manual = false

    static let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)

    static func face(_ visionBox: CGRect) -> MaskRegion {
        let expanded = visionBox.insetBy(dx: -visionBox.width * 0.16, dy: -visionBox.height * 0.19)
        let upright = CGRect(x: expanded.minX, y: 1 - expanded.maxY,
                             width: expanded.width, height: expanded.height)
        return MaskRegion(box: upright.intersection(bounds))
    }

    static func drawn(from start: CGPoint, to end: CGPoint, in size: CGSize) -> MaskRegion? {
        guard size.width > 0, size.height > 0 else { return nil }
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        let clipped = rect.intersection(CGRect(origin: .zero, size: size))
        guard !clipped.isNull, clipped.width >= 6, clipped.height >= 6 else { return nil }
        return MaskRegion(box: CGRect(x: clipped.minX / size.width, y: clipped.minY / size.height,
                                      width: clipped.width / size.width, height: clipped.height / size.height),
                          manual: true)
    }

    func displayRect(in size: CGSize) -> CGRect {
        box.applying(CGAffineTransform(scaleX: size.width, y: size.height))
    }

    func coreImageRect(in extent: CGRect) -> CGRect {
        CGRect(x: extent.minX + box.minX * extent.width,
               y: extent.minY + (1 - box.maxY) * extent.height,
               width: box.width * extent.width, height: box.height * extent.height)
            .integral.intersection(extent)
    }
}

enum MosaicStrength: String, CaseIterable, Identifiable {
    case fine = "약하게", regular = "보통", strong = "강하게"
    var id: Self { self }
    var cells: CGFloat {
        switch self {
        case .fine: return 12
        case .regular: return 7
        case .strong: return 4
        }
    }
}

struct PhotoDocument {
    let original: Data
    let previewSource: CGImage
    let regions: [MaskRegion]
    let detectionFailed: Bool
}

enum PhotoError: LocalizedError {
    case unreadable, render, permission
    var errorDescription: String? {
        switch self {
        case .unreadable: return "사진을 열 수 없어요. 기기에 내려받은 다른 사진을 선택해 주세요."
        case .render: return "사진을 처리하지 못했어요. 다시 시도해 주세요."
        case .permission: return "설정에서 가림의 사진 추가 권한을 허용한 뒤 다시 저장해 주세요."
        }
    }
}

actor PhotoEngine {
    private let context = CIContext(options: [.cacheIntermediates: false])
    static let exportLimit = 4096

    func open(_ data: Data) throws -> PhotoDocument {
        let image = try decode(data, longestEdge: 1920)
        let request = VNDetectFaceRectanglesRequest()
        let boxes: [CGRect]
        var failed = false
        do {
            try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
            boxes = (request.results ?? []).map(\.boundingBox)
        } catch {
            boxes = []
            failed = true
        }
        try Task.checkCancellation()
        let regions = boxes.map(MaskRegion.face)
            .filter { !$0.box.isEmpty }
            .sorted { $0.box.minX < $1.box.minX }
        return PhotoDocument(original: data, previewSource: image, regions: regions, detectionFailed: failed)
    }

    func preview(_ document: PhotoDocument, regions: [MaskRegion], strength: MosaicStrength) throws -> CGImage {
        try composite(document.previewSource, regions: regions, strength: strength)
    }

    func jpeg(_ document: PhotoDocument, regions: [MaskRegion], strength: MosaicStrength) throws -> Data {
        let input = try decode(document.original, longestEdge: Self.exportLimit)
        let output = try composite(input, regions: regions, strength: strength)
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw PhotoError.render }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.94]
        // A new pixel-only image prevents transfer of source EXIF, GPS or an original thumbnail.
        CGImageDestinationAddImage(destination, output, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PhotoError.render }
        return bytes as Data
    }

    private func decode(_ data: Data, longestEdge: Int) throws -> CGImage {
        let readOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, readOptions as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { throw PhotoError.unreadable }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? longestEdge
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? longestEdge
        let maxPixels = min(longestEdge, max(width, height))
        guard maxPixels > 0 else { throw PhotoError.unreadable }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
        else { throw PhotoError.unreadable }
        return image
    }

    private func composite(_ source: CGImage, regions: [MaskRegion], strength: MosaicStrength) throws -> CGImage {
        let raster = CIImage(cgImage: source)
        let background = CIImage(color: .white).cropped(to: raster.extent)
        let base = raster.composited(over: background)
        var result = base
        let activeRegions = regions.filter(\.covered)
        for region in activeRegions {
            try Task.checkCancellation()
            let rect = region.coreImageRect(in: base.extent)
            guard !rect.isEmpty else { continue }
            let scale = max(2, min(rect.width, rect.height) / strength.cells)
            let tile = base.cropped(to: rect).clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: scale,
                    kCIInputCenterKey: CIVector(x: rect.midX, y: rect.midY)
                ])
                .cropped(to: rect)
            result = tile.composited(over: result)
        }
        try Task.checkCancellation()
        if activeRegions.isEmpty { return source }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let output = context.createCGImage(result, from: base.extent, format: .RGBA8, colorSpace: colorSpace)
        else { throw PhotoError.render }
        return output
    }
}
