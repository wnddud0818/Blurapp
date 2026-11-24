import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Garim

final class MaskTests: XCTestCase {
    func testTopFaceRemainsAtTopAcrossCoordinateSystems() {
        let region = MaskRegion.face(CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.2))
        XCTAssertEqual(region.box.minY, 0, accuracy: 0.0001)
        XCTAssertLessThan(region.box.maxY, 0.25)
        let rect = region.coreImageRect(in: CGRect(x: 0, y: 0, width: 800, height: 1200))
        XCTAssertEqual(rect.maxY, 1200)
        XCTAssertGreaterThan(rect.minY, 900)
    }

    func testManualDragIsClippedAndDirectionIndependent() throws {
        let size = CGSize(width: 200, height: 100)
        let a = CGPoint(x: 180, y: 60), b = CGPoint(x: -20, y: 10)
        let forward = try XCTUnwrap(MaskRegion.drawn(from: a, to: b, in: size))
        let reverse = try XCTUnwrap(MaskRegion.drawn(from: b, to: a, in: size))
        XCTAssertEqual(forward.box, reverse.box)
        XCTAssertEqual(forward.box, CGRect(x: 0, y: 0.1, width: 0.9, height: 0.5))
        XCTAssertTrue(forward.manual && forward.covered)
        XCTAssertNil(MaskRegion.drawn(from: a, to: a, in: size))
    }

    func testPortraitExportAndSelectiveMasking() async throws {
        let width = 96, height = 64
        let gray = CGColorSpaceCreateDeviceGray()
        // An alternating stripe pattern exposes both wrong-axis and whole-image masking.
        let bytes = Data((0..<(width * height)).map { UInt8(($0 % width) % 2 == 0 ? 20 : 240) })
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let source = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width, space: gray, bitmapInfo: [], provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        let input = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(input, UTType.tiff.identifier as CFString, 1, nil))
        let props: [CFString: Any] = [kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.5, kCGImagePropertyGPSLatitudeRef: "N"]]
        CGImageDestinationAddImage(dest, source, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let engine = PhotoEngine()
        let doc = try await engine.open(input as Data)
        XCTAssertEqual(doc.previewSource.width, height)
        XCTAssertEqual(doc.previewSource.height, width)
        let top = MaskRegion(box: CGRect(x: 0, y: 0, width: 1, height: 0.5))
        var bottom = MaskRegion(box: CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
        bottom.covered = false
        let masked = try await engine.preview(doc, regions: [top, bottom], strength: .strong)
        let original = CIImage(cgImage: doc.previewSource)
        let rendered = CIImage(cgImage: masked)
        let ci = CIContext()
        func sample(_ image: CIImage, at y: CGFloat) -> [UInt8] {
            var result = [UInt8](repeating: 0, count: 8 * 4)
            result.withUnsafeMutableBytes { buffer in
                ci.render(image, toBitmap: buffer.baseAddress!, rowBytes: 4,
                          bounds: CGRect(x: 20, y: y, width: 1, height: 8),
                          format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            }
            return stride(from: 0, to: result.count, by: 4).map { result[$0] }
        }
        func variation(_ pixels: [UInt8]) -> Int {
            zip(pixels, pixels.dropFirst()).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        }
        XCTAssertLessThan(variation(sample(rendered, at: 72)), variation(sample(original, at: 72)) / 2)
        XCTAssertEqual(sample(rendered, at: 12), sample(original, at: 12))
        let jpeg = try await engine.jpeg(doc, regions: [top, bottom], strength: .strong)
        let exported = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(exported, 0, nil) as? [CFString: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, height)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, width)
    }
}
