import AVFoundation
import CoreImage
import Vision

enum VideoMaskMode: String, CaseIterable, Identifiable {
    case faces = "다른 얼굴 가리기"
    case person = "인물만 남기기"

    var id: Self { self }
}

enum VideoError: LocalizedError {
    case unreadable, export, permission

    var errorDescription: String? {
        switch self {
        case .unreadable: return "이 동영상을 읽을 수 없어요."
        case .export: return "결과 영상을 만들지 못했어요. 여유 공간을 확인하고 다시 시도해 주세요."
        case .permission: return "설정에서 사진 추가 권한을 허용해 주세요."
        }
    }
}

/// Owns a unique temporary copy for as long as the editor, renderer or save operation needs it.
final class MovieFile: Sendable {
    let url: URL
    init(extension suffix: String) {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(suffix)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

struct MovieSource {
    let file: MovieFile
    let asset: AVURLAsset
    let range: CMTimeRange

    init(file: MovieFile) async throws {
        self.file = file
        let asset = AVURLAsset(url: file.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoError.unreadable
        }
        let range = try await track.load(.timeRange)
        guard range.start.seconds.isFinite, range.duration.seconds.isFinite,
              range.duration.seconds > 0 else { throw VideoError.unreadable }
        self.asset = asset
        self.range = range
    }

    func generator(maxSide: CGFloat) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return generator
    }

    func frame(at seconds: Double, mode: VideoMaskMode) async throws -> VideoSelectionFrame {
        let time = CMTime(seconds: seconds, preferredTimescale: 60000)
        let frame = try await generator(maxSide: 960).image(at: time)
        let subjects = try VideoSubjects(in: CIImage(cgImage: frame.image), mode: mode)
        return VideoSelectionFrame(image: frame.image, time: frame.actualTime.seconds, boxes: subjects.boxes)
    }
}

struct VideoSelectionFrame {
    let image: CGImage
    let time: Double
    /// Normalized coordinates with the Vision (bottom-left) origin.
    let boxes: [CGRect]
}

private struct VideoSubjects {
    let boxes: [CGRect]
    let instances: VNInstanceMaskObservation?
    let labels: [Int]
    let handler: VNImageRequestHandler

    init(in image: CIImage, mode: VideoMaskMode) throws {
        let origin = image.extent.origin
        let scale = min(1, 1280 / max(image.extent.width, image.extent.height))
        let analysis = image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let handler = VNImageRequestHandler(ciImage: analysis, options: [:])
        self.handler = handler
        switch mode {
        case .faces:
            let request = VNDetectFaceRectanglesRequest()
            try handler.perform([request])
            boxes = (request.results ?? []).map(\.boundingBox).sorted { $0.midX < $1.midX }
            instances = nil
            labels = []
        case .person:
            let request = VNGeneratePersonInstanceMaskRequest()
            let faces = VNDetectFaceRectanglesRequest()
            try handler.perform([request, faces])
            instances = request.results?.first
            if let instances {
                guard let map = SubjectMap(instanceMask: instances.instanceMask,
                                           instances: instances.allInstances, faces: []) else {
                    throw VideoError.unreadable
                }
                // In a crowd Vision can assign several people to the same silhouette.
                let faceLabels = (faces.results ?? []).compactMap { face in
                    map.subject(at: CGPoint(x: face.boundingBox.midX, y: 1 - face.boundingBox.midY),
                                tolerance: 0)?.id
                }
                let people = map.subjects.filter { subject in
                    faceLabels.filter { $0 == subject.id }.count < 2
                }
                boxes = people.map { subject in
                    let box = subject.box
                    return CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
                }
                labels = people.map(\.id)
            } else {
                boxes = []
                labels = []
            }
        }
    }

    func silhouette(at index: Int, extent: CGRect) throws -> CIImage {
        guard let instances else { throw VideoError.export }
        let buffer = try instances.generateScaledMaskForImage(forInstances: IndexSet(integer: labels[index]),
                                                               from: handler)
        let mask = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
        return mask.transformed(by: CGAffineTransform(scaleX: extent.width / mask.extent.width,
                                                      y: extent.height / mask.extent.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }
}

struct VideoTrackPoint {
    let time: Double
    let box: CGRect
}

struct VideoPersonTrack {
    let points: [VideoTrackPoint] // chronological, ending on loss of tracking in either direction

    func target(at time: Double) -> CGRect? {
        guard let first = points.first, let last = points.last,
              time >= first.time - 0.001, time <= last.time + 0.001 else { return nil }
        var low = 0
        var high = points.count - 1
        while low < high {
            let mid = (low + high) / 2
            if points[mid].time < time { low = mid + 1 } else { high = mid }
        }
        let b = points[low]
        guard low > 0 else { return b.box }
        let a = points[low - 1]
        let t = CGFloat(min(1, max(0, (time - a.time) / (b.time - a.time))))
        return CGRect(x: a.box.minX + (b.box.minX - a.box.minX) * t,
                      y: a.box.minY + (b.box.minY - a.box.minY) * t,
                      width: a.box.width + (b.box.width - a.box.width) * t,
                      height: a.box.height + (b.box.height - a.box.height) * t)
    }

    /// Reject weak or ambiguous overlaps, including when two people cross.
    static func match(_ target: CGRect?, among boxes: [CGRect]) -> Int? {
        guard let target else { return nil }
        let ranked = boxes.enumerated().map { index, box -> (Int, CGFloat) in
            let overlap = target.intersection(box)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            let union = target.width * target.height + box.width * box.height - area
            return (index, area / max(union, 0.000001))
        }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first, best.1 >= 0.40,
              best.1 - (ranked.dropFirst().first?.1 ?? 0) >= 0.18 else { return nil }
        return best.0
    }

    static func follow(_ source: MovieSource, frame: VideoSelectionFrame, box: CGRect,
                       progress: (Double) async -> Void) async throws -> Self {
        let generator = source.generator(maxSide: 960)
        let seed = VideoTrackPoint(time: frame.time, box: box)
        var points = [seed]
        let start = source.range.start.seconds
        let end = source.range.end.seconds
        var processed = 0.0
        // Each direction starts with the exact image on which the user picked the target.
        for direction in [-1.0, 1.0] {
            let sequence = VNSequenceRequestHandler()
            let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: box))
            request.trackingLevel = .accurate
            try Task.checkCancellation()
            try sequence.perform([request], on: frame.image)
            var previous = seed
            var steps = 0
            while let observed = request.results?.first as? VNDetectedObjectObservation,
                  observed.confidence >= 0.65 {
                try Task.checkCancellation()
                let limit = direction < 0 ? start : max(frame.time, end - 0.0001)
                if abs(previous.time - limit) < 0.0001 { break }
                let next = direction < 0 ? max(limit, previous.time - 0.1) : min(limit, previous.time + 0.1)
                let image = try await generator.image(at: CMTime(seconds: next, preferredTimescale: 60000)).image
                request.inputObservation = observed
                try autoreleasepool { try sequence.perform([request], on: image) }
                guard let result = request.results?.first as? VNDetectedObjectObservation,
                      result.confidence >= 0.65,
                      Self.match(previous.box, among: [result.boundingBox]) != nil else { break }
                let point = VideoTrackPoint(time: next, box: result.boundingBox)
                points.append(point)
                processed += abs(next - previous.time)
                previous = point
                steps += 1
                if steps.isMultiple(of: 10) { await progress(min(1, processed / source.range.duration.seconds)) }
            }
        }
        return Self(points: points.sorted { $0.time < $1.time })
    }
}

struct RenderedMovie {
    let file: MovieFile
    /// Relative to the start of the clip, present if the track ended early in either direction.
    let partialTrack: ClosedRange<Double>?
}

enum VideoRenderer {
    static func render(_ source: MovieSource, frame: VideoSelectionFrame, box: CGRect, mode: VideoMaskMode,
                       progress: @escaping (Double) async -> Void) async throws -> RenderedMovie {
        let track = try await VideoPersonTrack.follow(source, frame: frame, box: box) { await progress($0 * 0.3) }
        try Task.checkCancellation()
        let context = CIContext(options: [.cacheIntermediates: false])
        let composition = AVVideoComposition(asset: source.asset, applyingCIFiltersWithHandler: { request in
            do {
                let result = try composite(request.sourceImage, mode: mode,
                                           target: track.target(at: request.compositionTime.seconds))
                request.finish(with: result, context: context)
            } catch {
                request.finish(with: error)
            }
        })
        let file = MovieFile(extension: "mov")
        guard let export = AVAssetExportSession(asset: source.asset, presetName: AVAssetExportPresetHighestQuality)
        else { throw VideoError.export }
        export.videoComposition = composition
        export.outputURL = file.url
        export.outputFileType = .mov
        let monitor = Task {
            while !Task.isCancelled {
                await progress(0.3 + Double(export.progress) * 0.7)
                try await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        defer { monitor.cancel() }
        await withTaskCancellationHandler {
            await export.export()
        } onCancel: { export.cancelExport() }
        try Task.checkCancellation()
        guard export.status == .completed else { throw export.error ?? VideoError.export }
        let start = source.range.start.seconds
        let duration = source.range.duration.seconds
        let from = max(0, (track.points.first?.time ?? frame.time) - start)
        let to = max(from, (track.points.last?.time ?? frame.time) - start)
        let partial = from > 0.01 || to < duration - 0.01
        return RenderedMovie(file: file, partialTrack: partial ? from...to : nil)
    }

    private static func composite(_ image: CIImage, mode: VideoMaskMode, target: CGRect?) throws -> CIImage {
        switch mode {
        case .faces:
            let faces = try VideoSubjects(in: image, mode: mode).boxes
            return coverOtherFaces(in: image, faces: faces, target: target)
        case .person:
            if let target {
                let people = try VideoSubjects(in: image, mode: mode)
                if let keep = VideoPersonTrack.match(target, among: people.boxes) {
                    let mask = try people.silhouette(at: keep, extent: image.extent)
                    return keepPerson(in: image, mask: mask)
                }
            }
            return keepPerson(in: image, mask: nil)
        }
    }

    static func coverOtherFaces(in image: CIImage, faces: [CGRect], target: CGRect?) -> CIImage {
        let keep = VideoPersonTrack.match(target, among: faces)
        var result = image
        for (index, face) in faces.enumerated() where index != keep {
            let rect = MaskRegion.face(face).coreImageRect(in: image.extent)
            guard !rect.isEmpty else { continue }
            let unit = max(3, min(rect.width, rect.height) / MosaicStrength.regular.cells)
            let pixels = MaskEffect.pixel.apply(to: image.cropped(to: rect), unit: unit)
            result = pixels.composited(over: result)
        }
        return result
    }

    static func keepPerson(in image: CIImage, mask: CIImage?) -> CIImage {
        let extent = image.extent
        let unit = max(3, min(extent.width, extent.height) / MosaicStrength.regular.backgroundCells)
        let background = MaskEffect.pixel.apply(to: image, unit: unit)
        guard let mask else { return background }
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: mask
        ])
    }
}
