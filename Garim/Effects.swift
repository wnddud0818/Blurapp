import CoreImage
import Foundation

/// What a selection means for a photo.
enum MaskMode: String, CaseIterable, Identifiable {
    /// Covers the chosen faces and drawn areas.
    case cover = "골라서 가리기"
    /// Keeps the chosen people, objects and drawn areas, and covers everything else.
    case keep = "골라서 남기기"

    var id: Self { self }

    var summary: String {
        switch self {
        case .cover: return "찾은 얼굴과 직접 그린 영역을 가려요."
        case .keep: return "고른 사람·물체만 남기고 나머지를 모두 가려요."
        }
    }
}

enum MaskEffect: String, CaseIterable, Identifiable {
    case pixel = "모자이크"
    case hexagon = "육각 모자이크"
    case crystal = "크리스털"
    case blur = "블러"
    case solid = "검정 가림"

    var id: Self { self }

    /// A solid cover hides everything at once, so strength does not apply to it.
    var usesStrength: Bool { self != .solid }

    /// Applies the effect inside `image.extent`. `unit` is the size of one cell in pixels and
    /// `minimum` the smallest blur radius, both already scaled to the image's resolution.
    func apply(to image: CIImage, unit: CGFloat, minimum: CGFloat = 2) -> CIImage {
        let extent = image.extent
        let center = CIVector(x: extent.midX, y: extent.midY)
        // Clamping repeats edge pixels so cells and blur near the border don't fade to transparent.
        let edges = image.clampedToExtent()
        let output: CIImage
        switch self {
        case .pixel:
            output = edges.applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: unit,
                kCIInputCenterKey: center
            ])
        case .hexagon:
            output = edges.applyingFilter("CIHexagonalPixellate", parameters: [
                kCIInputScaleKey: unit,
                kCIInputCenterKey: center
            ])
        case .crystal:
            output = edges.applyingFilter("CICrystallize", parameters: [
                kCIInputRadiusKey: unit,
                kCIInputCenterKey: center
            ])
        case .blur:
            output = edges.applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: max(minimum, unit * 0.6)
            ])
        case .solid:
            output = CIImage(color: CIColor(red: 0.06, green: 0.06, blue: 0.06))
        }
        return output.cropped(to: extent)
    }
}

enum MosaicStrength: String, CaseIterable, Identifiable {
    case fine = "약하게", regular = "보통", strong = "강하게"

    var id: Self { self }

    /// Cells across the shorter side of each covered area.
    var cells: CGFloat {
        switch self {
        case .fine: return 12
        case .regular: return 7
        case .strong: return 4
        }
    }

    /// Cells across the shorter side of the whole photo when everything but the kept subjects is covered.
    var backgroundCells: CGFloat {
        switch self {
        case .fine: return 64
        case .regular: return 40
        case .strong: return 22
        }
    }
}

/// How every photo in the batch is covered.
struct MaskStyle: Equatable {
    var mode: MaskMode = .cover
    var effect: MaskEffect = .pixel
    var strength: MosaicStrength = .regular
}
