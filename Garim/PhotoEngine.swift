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
    /// The photo was shown in keep mode, so its kept subjects were seen before saving.
    var keepReviewed = false

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
    /// Output pixels per editing-preview pixel. Pixel floors scale with it so a saved photo is
    /// covered exactly like its preview.
    var resolution: CGFloat = 1

    /// Smallest cell or blur radius, in output pixels.
    var minimumUnit: CGFloat { 2 * resolution }

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

enum FaceSearch {
    /// Pixel rectangles in the upright image, measured from the top left.
    static func tiles(in size: CGSize) -> [CGRect] {
        let longest = max(size.width, size.height)
        let edge = min(1280, max(256, (longest * 0.6).rounded(.up)))
        guard longest > edge else { return [] }

        func origins(along length: CGFloat) -> [CGFloat] {
            guard length > edge else { return [0] }
            let span = length - edge
            // Space the crops evenly, with at least 20% overlap across each seam.
            let steps = Int((span / (edge * 0.8)).rounded(.up))
            return (0...steps).map { (span * CGFloat($0) / CGFloat(steps)).rounded() }
        }

        let columns = origins(along: size.width)
        return origins(along: size.height).flatMap { y in
            columns.map { x in
                CGRect(x: x, y: y, width: min(edge, size.width), height: min(edge, size.height))
            }
        }
    }

    /// Keep the result in Vision's bottom-left coordinate system until MaskRegion.face adds padding.
    static func imageBox(_ box: CGRect, in tile: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(x: (tile.minX + box.minX * tile.width) / imageSize.width,
               y: (imageSize.height - tile.maxY + box.minY * tile.height) / imageSize.height,
               width: box.width * tile.width / imageSize.width,
               height: box.height * tile.height / imageSize.height)
    }

    static func combinedBoxes(wholeImage: [CGRect], tiles: [CGRect]) -> [CGRect] {
        var kept = wholeImage
        func area(_ box: CGRect) -> CGFloat { box.width * box.height }
        // Prefer a full face over a smaller observation cut by a tile boundary.
        for box in tiles.sorted(by: { area($0) > area($1) }) where !box.isEmpty {
            let duplicate = kept.contains { other in
                let overlap = box.intersection(other)
                guard !overlap.isEmpty else { return false }
                let intersection = area(overlap)
                return intersection >= 0.45 * (area(box) + area(other) - intersection)
            }
            if !duplicate { kept.append(box) }
        }
        return kept
    }
}

enum PhotoError: LocalizedError {
    case unreadable, render, permission
    var errorDescription: String? {
        switch self {
        case .unreadable: return "사진을 열 수 없어요. 기기에 내려받은 다른 사진을 선택해 주세요."
        case .render: return "사진을 처리하지 못했어요. 다시 시도해 주세요."
        case .permission: return "설정에서 모자이크의 사진 추가 권한을 허용한 뒤 다시 저장해 주세요."
        }
    }
}

actor PhotoEngine {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private static let faceSearchLimit = 4096
    static let previewLimit = 1920
    static let exportLimit = 4096
    static let thumbnailLimit = 240

    func open(_ data: Data) throws -> OpenedPhoto {
        let image = try decode(data, longestEdge: Self.previewLimit)
        try Task.checkCancellation()
        let wholeImageBoxes = try? detectFaces(in: image)
        try Task.checkCancellation()
        let detail: CGImage
        if max(image.width, image.height) == Self.previewLimit {
            detail = (try? decode(data, longestEdge: Self.faceSearchLimit)) ?? image
        } else {
            detail = image
        }

        let size = CGSize(width: detail.width, height: detail.height)
        var tileBoxes: [CGRect] = []
        var failed = wholeImageBoxes == nil
        for tile in FaceSearch.tiles(in: size) {
            try Task.checkCancellation()
            guard let crop = detail.cropping(to: tile), let boxes = try? detectFaces(in: crop) else {
                failed = true
                continue
            }
            tileBoxes.append(contentsOf: boxes.map { FaceSearch.imageBox($0, in: tile, imageSize: size) })
        }

        try Task.checkCancellation()
        let regions = FaceSearch.combinedBoxes(wholeImage: wholeImageBoxes ?? [], tiles: tileBoxes)
            .map(MaskRegion.face)
            .filter { !$0.box.isEmpty }
            .sorted { $0.box.minX < $1.box.minX }
        let page = PhotoPage(original: data,
                             thumbnail: downscale(image, longestEdge: Self.thumbnailLimit) ?? image,
                             size: CGSize(width: image.width, height: image.height),
                             regions: regions, faceDetectionFailed: failed)
        return OpenedPhoto(page: page, source: image)
    }

    private func detectFaces(in image: CGImage) throws -> [CGRect] {
        try autoreleasepool {
            let request = VNDetectFaceRectanglesRequest()
            try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
            return (request.results ?? []).map(\.boundingBox)
        }
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
        let longest = CGFloat(max(input.width, input.height))
        var plan = plan
        plan.resolution = longest / min(CGFloat(Self.previewLimit), longest)
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
            let unit = max(plan.minimumUnit, min(rect.width, rect.height) / plan.style.strength.cells)
            result = plan.style.effect.apply(to: base.cropped(to: rect), unit: unit, minimum: plan.minimumUnit)
                .composited(over: result)
        }
        return result
    }

    private func keep(_ base: CIImage, plan: MaskPlan) throws -> CIImage {
        let extent = base.extent
        let unit = max(plan.minimumUnit, min(extent.width, extent.height) / plan.style.strength.backgroundCells)
        let covered = plan.style.effect.apply(to: base, unit: unit, minimum: plan.minimumUnit)
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
