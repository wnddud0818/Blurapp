import CoreGraphics
import CoreVideo
import Foundation

/// A person, animal or object that Vision separated from the background.
struct Subject: Identifiable, Equatable {
    /// The subject's label in the map.
    let id: Int
    /// Fractions of the upright image, with the origin at the top left.
    let box: CGRect
    /// Mean position of the subject's pixels, as fractions with the origin at the top left.
    let center: CGPoint
    /// Share of the photo the subject covers.
    let area: Double
    /// A detected face lies on the subject.
    var person = false
}

enum SubjectAnalysis {
    case notRun
    case ready(SubjectMap)
    case failed

    var result: SubjectMap? {
        if case .ready(let map) = self { return map }
        return nil
    }

    var hasRun: Bool {
        if case .notRun = self { return false }
        return true
    }
}

/// Foreground instances as a small label map. Row 0 is the top of the upright photo,
/// 0 is background and any other value is the label of one subject.
struct SubjectMap {
    /// Longest side of the stored map. Larger Vision masks are sampled down to this.
    static let maxSide = 1024
    /// Smaller specks are treated as background so the list only shows meaningful subjects.
    static let minimumArea = 0.002

    let width: Int
    let height: Int
    let labels: [UInt8]
    /// Ordered from left to right.
    let subjects: [Subject]

    init(width: Int, height: Int, labels: [UInt8], faces: [CGRect] = []) {
        let valid = width > 0 && height > 0 && labels.count == width * height
        let w = valid ? width : 1
        let h = valid ? height : 1
        let l = valid ? labels : [0]
        self.width = w
        self.height = h
        self.labels = l
        self.subjects = Self.findSubjects(width: w, height: h, labels: l, faces: faces)
    }

    /// Reads the instance mask of `VNInstanceMaskObservation`: one UInt8 label per pixel at the model's
    /// own resolution (not necessarily the photo's aspect ratio), stretched over the whole photo.
    init?(instanceMask buffer: CVPixelBuffer, instances: IndexSet, faces: [CGRect]) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let sourceWidth = CVPixelBufferGetWidth(buffer)
        let sourceHeight = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        // Vision documents an 8-bit label map; refuse anything wider than one byte per pixel.
        let oneByte = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8
            || rowBytes < sourceWidth * 2
        guard oneByte, sourceWidth > 0, sourceHeight > 0, rowBytes >= sourceWidth,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let longest = Double(max(sourceWidth, sourceHeight))
        let step = max(1, Int((longest / Double(Self.maxSide)).rounded(.up)))
        let width = (sourceWidth + step - 1) / step
        let height = (sourceHeight + step - 1) / step
        var allowed = [Bool](repeating: false, count: 256)
        for instance in instances where instance > 0 && instance < 256 {
            allowed[instance] = true
        }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var labels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = pixels + y * step * rowBytes
            for x in 0..<width {
                let label = row[x * step]
                if allowed[Int(label)] { labels[y * width + x] = label }
            }
        }
        self.init(width: width, height: height, labels: labels, faces: faces)
    }

    /// The person if one was found, otherwise the largest subject.
    var defaultKept: Set<Int> {
        let people = subjects.filter(\.person)
        let candidates = people.isEmpty ? subjects : people
        guard let main = candidates.max(by: { $0.area < $1.area }) else { return [] }
        return [main.id]
    }

    /// The subject under a point given as fractions with the origin at the top left.
    /// A tap that lands just outside a subject still finds it.
    func subject(at point: CGPoint, tolerance: CGFloat = 0.03) -> Subject? {
        let exact = Self.label(in: labels, width: width, height: height, at: point)
        if let hit = subjects.first(where: { $0.id == exact }) { return hit }
        let steps = 4
        var votes: [Int: Int] = [:]
        for i in -steps...steps {
            for j in -steps...steps {
                let probe = CGPoint(x: point.x + tolerance * CGFloat(i) / CGFloat(steps),
                                    y: point.y + tolerance * CGFloat(j) / CGFloat(steps))
                let label = Self.label(in: labels, width: width, height: height, at: probe)
                if label != 0 { votes[label, default: 0] += 1 }
            }
        }
        let ranked = votes.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        for (label, _) in ranked {
            if let hit = subjects.first(where: { $0.id == label }) { return hit }
        }
        return nil
    }

    /// A grayscale mask at the map's size, white on the kept subjects. Nil when nothing would be kept.
    func mask(keeping kept: Set<Int>) -> CGImage? {
        var lookup = [UInt8](repeating: 0, count: 256)
        for subject in subjects where kept.contains(subject.id) {
            lookup[subject.id] = 255
        }
        let bytes = labels.map { lookup[Int($0)] }
        guard bytes.contains(255) else { return nil }
        return Self.image(bytes, width: width, height: height, components: 1)
    }

    /// A translucent tint for the editor: lime on kept subjects, white on the others.
    func overlay(keeping kept: Set<Int>) -> CGImage? {
        guard !subjects.isEmpty else { return nil }
        // Premultiplied RGBA: lime at 50% and white at 25%.
        var red = [UInt8](repeating: 0, count: 256)
        var green = [UInt8](repeating: 0, count: 256)
        var blue = [UInt8](repeating: 0, count: 256)
        var alpha = [UInt8](repeating: 0, count: 256)
        for subject in subjects {
            let on = kept.contains(subject.id)
            red[subject.id] = on ? 105 : 64
            green[subject.id] = on ? 121 : 64
            blue[subject.id] = on ? 57 : 64
            alpha[subject.id] = on ? 128 : 64
        }
        var rgba = [UInt8](repeating: 0, count: labels.count * 4)
        for (index, label) in labels.enumerated() where label != 0 {
            let l = Int(label)
            rgba[index * 4] = red[l]
            rgba[index * 4 + 1] = green[l]
            rgba[index * 4 + 2] = blue[l]
            rgba[index * 4 + 3] = alpha[l]
        }
        return Self.image(rgba, width: width, height: height, components: 4)
    }

    // MARK: - Helpers

    private static func label(in labels: [UInt8], width: Int, height: Int, at point: CGPoint) -> Int {
        // The comparisons also reject NaN.
        guard point.x >= 0, point.y >= 0, point.x <= 1, point.y <= 1 else { return 0 }
        let x = min(width - 1, Int(point.x * CGFloat(width)))
        let y = min(height - 1, Int(point.y * CGFloat(height)))
        return Int(labels[y * width + x])
    }

    private static func findSubjects(width: Int, height: Int, labels: [UInt8], faces: [CGRect]) -> [Subject] {
        var count = [Int](repeating: 0, count: 256)
        var minX = [Int](repeating: Int.max, count: 256)
        var minY = [Int](repeating: Int.max, count: 256)
        var maxX = [Int](repeating: -1, count: 256)
        var maxY = [Int](repeating: -1, count: 256)
        var sumX = [Double](repeating: 0, count: 256)
        var sumY = [Double](repeating: 0, count: 256)
        labels.withUnsafeBufferPointer { pixels in
            for y in 0..<height {
                for x in 0..<width {
                    let label = Int(pixels[y * width + x])
                    guard label != 0 else { continue }
                    count[label] += 1
                    if x < minX[label] { minX[label] = x }
                    if x > maxX[label] { maxX[label] = x }
                    if y < minY[label] { minY[label] = y }
                    if y > maxY[label] { maxY[label] = y }
                    sumX[label] += Double(x)
                    sumY[label] += Double(y)
                }
            }
        }
        let total = Double(width * height)
        let w = Double(width)
        let h = Double(height)
        var subjects: [Subject] = []
        for label in 1..<256 where count[label] > 0 {
            let area = Double(count[label]) / total
            guard area >= minimumArea else { continue }
            let pixels = Double(count[label])
            let box = CGRect(x: Double(minX[label]) / w, y: Double(minY[label]) / h,
                             width: Double(maxX[label] - minX[label] + 1) / w,
                             height: Double(maxY[label] - minY[label] + 1) / h)
            let center = CGPoint(x: (sumX[label] / pixels + 0.5) / w, y: (sumY[label] / pixels + 0.5) / h)
            subjects.append(Subject(id: label, box: box, center: center, area: area))
        }
        for face in faces {
            let label = Self.label(in: labels, width: width, height: height, at: CGPoint(x: face.midX, y: face.midY))
            if let index = subjects.firstIndex(where: { $0.id == label }) {
                subjects[index].person = true
            }
        }
        return subjects.sorted { $0.box.minX < $1.box.minX }
    }

    private static func image(_ bytes: [UInt8], width: Int, height: Int, components: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        let gray = components == 1
        let space = gray ? CGColorSpaceCreateDeviceGray()
            : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
        let alpha: CGImageAlphaInfo = gray ? .none : .premultipliedLast
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * components,
                       bytesPerRow: width * components, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
