import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

struct MaskRegion: Identifiable, Equatable {
    let id = UUID()
    /// Fractions of the upright image, with the origin at the top left.
    let box: CGRect
    /// Covered in cover mode, kept in keep mode.
    var active = true
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

/// One photo of the batch. The full editing preview is decoded only while the photo is shown.
struct PhotoPage: Identifiable {
    let id = UUID()
    let original: Data
    let thumbnail: CGImage
    /// Pixel size of the upright editing preview.
    let size: CGSize
    /// Detected faces and drawn areas to cover.
    var regions: [MaskRegion]
    let faceDetectionFailed: Bool
    /// Drawn areas to keep when everything else is covered.
    var keepAreas: [MaskRegion] = []
    var analysis: SubjectAnalysis = .notRun
    /// Labels of the subjects to keep.
    var kept: Set<Int> = []
    var saved = false

    func plan(_ style: MaskStyle) -> MaskPlan {
        MaskPlan(style: style, regions: regions, keepAreas: keepAreas, subjects: analysis.result, kept: kept)
    }
}

/// Everything needed to render one photo.
struct MaskPlan {
    var style: MaskStyle
    var regions: [MaskRegion] = []
    var keepAreas: [MaskRegion] = []
    var subjects: SubjectMap? = nil
    var kept: Set<Int> = []

    /// Whether the output differs from the input.
    var changesPhoto: Bool {
        switch style.mode {
        case .cover: return regions.contains(where: \.active)
        case .keep: return true
        }
    }
}

struct OpenedPhoto {
    let page: PhotoPage
    /// The editing preview, so the first photo doesn't need decoding twice.
    let source: CGImage
}

struct RenderedPreview {
    let image: CGImage
    let overlay: CGImage?
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
    static let previewLimit = 1920
    static let exportLimit = 4096
    static let thumbnailLimit = 240

    func open(_ data: Data) throws -> OpenedPhoto {
        let image = try decode(data, longestEdge: Self.previewLimit)
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
        let page = PhotoPage(original: data,
                             thumbnail: downscale(image, longestEdge: Self.thumbnailLimit) ?? image,
                             size: CGSize(width: image.width, height: image.height),
                             regions: regions, faceDetectionFailed: failed)
        return OpenedPhoto(page: page, source: image)
    }

    func previewSource(_ data: Data) throws -> CGImage {
        try decode(data, longestEdge: Self.previewLimit)
    }

    /// Separates people, animals and objects from the background. `faces` mark which subjects are people.
    func subjects(in image: CGImage, faces: [CGRect]) -> SubjectAnalysis {
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
        } catch {
            // The Simulator and some older devices can't run the segmentation model.
            return .failed
        }
        guard let observation = request.results?.first else {
            return .ready(SubjectMap(width: 1, height: 1, labels: [0]))
        }
        guard let map = SubjectMap(instanceMask: observation.instanceMask,
                                   instances: observation.allInstances, faces: faces)
        else { return .failed }
        return .ready(map)
    }

    func render(_ source: CGImage, plan: MaskPlan) throws -> RenderedPreview {
        let image = try composite(source, plan: plan)
        let overlay = plan.style.mode == .keep ? plan.subjects?.overlay(keeping: plan.kept) : nil
        return RenderedPreview(image: image, overlay: overlay)
    }

    func jpeg(_ data: Data, plan: MaskPlan) throws -> Data {
        let input = try decode(data, longestEdge: Self.exportLimit)
        let output = try composite(input, plan: plan)
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

    private func downscale(_ image: CGImage, longestEdge: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > longestEdge else { return image }
        let scale = CGFloat(longestEdge) / CGFloat(longest)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: space,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        canvas.interpolationQuality = .high
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return canvas.makeImage()
    }

    private func composite(_ source: CGImage, plan: MaskPlan) throws -> CGImage {
        guard plan.changesPhoto else { return source }
        let raster = CIImage(cgImage: source)
        let extent = raster.extent
        let base = raster.composited(over: CIImage(color: .white).cropped(to: extent))
        let result: CIImage
        switch plan.style.mode {
        case .cover: result = try cover(base, plan: plan)
        case .keep: result = try keep(base, plan: plan)
        }
        try Task.checkCancellation()
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let output = context.createCGImage(result, from: extent, format: .RGBA8, colorSpace: colorSpace)
        else { throw PhotoError.render }
        return output
    }

    private func cover(_ base: CIImage, plan: MaskPlan) throws -> CIImage {
        var result = base
        for region in plan.regions where region.active {
            try Task.checkCancellation()
            let rect = region.coreImageRect(in: base.extent)
            guard !rect.isEmpty else { continue }
            let unit = max(2, min(rect.width, rect.height) / plan.style.strength.cells)
            result = plan.style.effect.apply(to: base.cropped(to: rect), unit: unit).composited(over: result)
        }
        return result
    }

    private func keep(_ base: CIImage, plan: MaskPlan) throws -> CIImage {
        let extent = base.extent
        let unit = max(2, min(extent.width, extent.height) / plan.style.strength.backgroundCells)
        let covered = plan.style.effect.apply(to: base, unit: unit)
        try Task.checkCancellation()
        guard let mask = keepMask(plan, extent: extent) else { return covered }
        return base.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: covered,
            kCIInputMaskImageKey: mask
        ])
    }

    /// White where the photo stays: the kept subjects, grown and feathered a little, and the drawn keep areas.
    private func keepMask(_ plan: MaskPlan, extent: CGRect) -> CIImage? {
        var mask: CIImage?
        if let map = plan.subjects, let small = map.mask(keeping: plan.kept) {
            let radius = max(1, min(extent.width, extent.height) * 0.004)
            // Clamp before scaling so the photo's border rows don't pick up transparent samples.
            // The map stretches over the whole photo; x and y scale independently.
            mask = CIImage(cgImage: small, options: [.colorSpace: NSNull()])
                .clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(map.width),
                                                   y: extent.height / CGFloat(map.height)))
                .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
                .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius])
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: extent)
        }
        let areas = plan.keepAreas.filter(\.active)
            .map { $0.coreImageRect(in: extent) }
            .filter { !$0.isEmpty }
        guard !areas.isEmpty else { return mask }
        var combined = mask ?? CIImage(color: .black).cropped(to: extent)
        for rect in areas {
            combined = CIImage(color: .white).cropped(to: rect).composited(over: combined)
        }
        return combined
    }
}
