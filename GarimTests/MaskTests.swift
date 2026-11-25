import Photos
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Garim

final class MaskTests: XCTestCase {
    private let ci = CIContext()

    func testDetailTilesCoverSmallFacesAtSeamsAndImageEdges() {
        for size in [CGSize(width: 4032, height: 3024), CGSize(width: 3024, height: 4032),
                     CGSize(width: 4096, height: 512), CGSize(width: 960, height: 720)] {
            let tiles = FaceSearch.tiles(in: size)
            let image = CGRect(origin: .zero, size: size)
            XCTAssertLessThanOrEqual(tiles.count, 16)
            XCTAssertTrue(tiles.allSatisfy { image.contains($0) && $0 == $0.integral })
            // Center a small face on every crop corner, including seams and outer edges.
            for tile in tiles {
                for x in [tile.minX, tile.maxX] {
                    for y in [tile.minY, tile.maxY] {
                        let face = CGRect(x: x - 16, y: y - 16, width: 32, height: 32).intersection(image)
                        XCTAssertTrue(tiles.contains { $0.contains(face) })
                    }
                }
            }
            XCTAssertEqual(tiles.reduce(CGRect.null) { $0.union($1) }, image)
        }
        XCTAssertTrue(FaceSearch.tiles(in: CGSize(width: 160, height: 240)).isEmpty)
    }

    func testTileFaceMapsToTheSamePortraitPixelsForPreviewAndExport() {
        let size = CGSize(width: 1024, height: 2048)
        let tile = CGRect(x: 320, y: 1280, width: 512, height: 512)
        let local = CGRect(x: 0.125, y: 0.625, width: 0.0625, height: 0.125)
        let box = FaceSearch.imageBox(local, in: tile, imageSize: size)
        XCTAssertEqual(box, CGRect(x: 384.0 / 1024, y: 576.0 / 2048,
                                   width: 32.0 / 1024, height: 64.0 / 2048))
        let mask = MaskRegion.face(box)
        let preview = mask.displayRect(in: CGSize(width: 256, height: 512))
        XCTAssertEqual(preview.midX, 100, accuracy: 0.001)
        XCTAssertEqual(preview.midY, 360, accuracy: 0.001)
        XCTAssertTrue(mask.coreImageRect(in: CGRect(origin: .zero, size: size))
            .contains(CGRect(x: 384, y: 576, width: 32, height: 64)))
    }

    func testCombiningPassesKeepsNearbyFacesAndRemovesRepeatDetections() {
        let foreground = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.4)
        let distant = CGRect(x: 0.7, y: 0.8, width: 0.03, height: 0.04)
        let neighbor = distant.offsetBy(dx: 0.024, dy: 0)
        let boxes = FaceSearch.combinedBoxes(wholeImage: [foreground], tiles: [
            foreground.offsetBy(dx: 0.01, dy: 0), distant.insetBy(dx: 0.002, dy: 0.002), distant, neighbor
        ])
        XCTAssertEqual(boxes.count, 3)
        for face in [foreground, distant, neighbor] { XCTAssertTrue(boxes.contains(face)) }
    }

    func testCloseUpKeepsOneRegionForANestedTileDetection() {
        let face = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let detail = CGRect(x: 0.27, y: 0.4, width: 0.25, height: 0.3)
        XCTAssertEqual(FaceSearch.combinedBoxes(wholeImage: [face], tiles: [detail]), [face])
        XCTAssertEqual(FaceSearch.combinedBoxes(wholeImage: [], tiles: [detail, face]), [face])
    }

    func testSmallFaceAtTheEdgeOfALargerFaceRemainsSelectable() {
        let face = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let neighbor = CGRect(x: 0.76, y: 0.42, width: 0.12, height: 0.16)
        XCTAssertEqual(FaceSearch.combinedBoxes(wholeImage: [face], tiles: [neighbor]), [face, neighbor])
    }

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
        XCTAssertTrue(forward.manual && forward.active)
        XCTAssertNil(MaskRegion.drawn(from: a, to: a, in: size))
    }

    func testManualRegionKeepsItsExportPixelsAfterDisplayResize() throws {
        let source = CGRect(x: 0, y: 0, width: 3072, height: 4096)
        let region = try XCTUnwrap(MaskRegion.drawn(from: CGPoint(x: 30, y: 40),
                                                    to: CGPoint(x: 150, y: 200),
                                                    in: CGSize(width: 240, height: 320)))
        let exported = region.coreImageRect(in: source)
        XCTAssertEqual(exported, CGRect(x: 384, y: 1536, width: 1536, height: 2048))

        // Fitted portrait image sizes on an outer display, inner display and narrow split window.
        for size in [CGSize(width: 240, height: 320), CGSize(width: 360, height: 480),
                     CGSize(width: 156, height: 208)] {
            let rect = region.displayRect(in: size)
            let roundTrip = try XCTUnwrap(MaskRegion.drawn(from: CGPoint(x: rect.minX, y: rect.minY),
                                                           to: CGPoint(x: rect.maxX, y: rect.maxY), in: size))
            XCTAssertEqual(roundTrip.coreImageRect(in: source), exported)
        }
    }

    func testMovingAnAreaKeepsItsSizeInsideThePhoto() {
        let box = CGRect(x: 0.5, y: 0.25, width: 0.25, height: 0.125)
        XCTAssertEqual(MaskRegion.move(box, by: CGVector(dx: 0.125, dy: 0.25)),
                       CGRect(x: 0.625, y: 0.5, width: 0.25, height: 0.125))
        // The photo edges stop it without squeezing it.
        XCTAssertEqual(MaskRegion.move(box, by: CGVector(dx: 2, dy: 3)), CGRect(x: 0.75, y: 0.875, width: 0.25, height: 0.125))
        XCTAssertEqual(MaskRegion.move(box, by: CGVector(dx: -1, dy: -1)), CGRect(x: 0, y: 0, width: 0.25, height: 0.125))
    }

    func testResizingMovesOneCornerAndKeepsTheOppositeOne() {
        let box = CGRect(x: 0.375, y: 0.375, width: 0.25, height: 0.25)
        let minimum = CGSize(width: 0.0625, height: 0.0625)
        func resize(_ corner: MaskRegion.Corner, _ dx: CGFloat, _ dy: CGFloat) -> CGRect {
            MaskRegion.resize(box, dragging: corner, by: CGVector(dx: dx, dy: dy), minimum: minimum)
        }
        XCTAssertEqual(resize(.topLeft, -0.125, -0.125), CGRect(x: 0.25, y: 0.25, width: 0.375, height: 0.375))
        XCTAssertEqual(resize(.topRight, 0.125, -0.125), CGRect(x: 0.375, y: 0.25, width: 0.375, height: 0.375))
        XCTAssertEqual(resize(.bottomLeft, -0.125, 0.125), CGRect(x: 0.25, y: 0.375, width: 0.375, height: 0.375))
        XCTAssertEqual(resize(.bottomRight, 0.125, 0.125), CGRect(x: 0.375, y: 0.375, width: 0.375, height: 0.375))
        // Dragging past the opposite corner stops at the minimum size.
        XCTAssertEqual(resize(.topLeft, 0.5, 0.5), CGRect(x: 0.5625, y: 0.5625, width: 0.0625, height: 0.0625))
        XCTAssertEqual(resize(.bottomRight, -0.5, -0.5), CGRect(x: 0.375, y: 0.375, width: 0.0625, height: 0.0625))
        // The photo edges stop it.
        XCTAssertEqual(resize(.bottomRight, 1, 1), CGRect(x: 0.375, y: 0.375, width: 0.625, height: 0.625))
        XCTAssertEqual(resize(.topLeft, -1, -1), CGRect(x: 0, y: 0, width: 0.625, height: 0.625))
    }

    func testEditingCanvasGrabsSmallAreasAndKeepsHandlesApart() throws {
        // A 1000 × 500 photo in a 400 × 400 canvas is drawn 400 × 200, centred.
        let layout = RegionLayout(photo: CGSize(width: 1000, height: 500), in: CGSize(width: 400, height: 400))
        XCTAssertEqual(layout.frame, CGRect(x: 0, y: 100, width: 400, height: 200))
        XCTAssertEqual(layout.fraction(CGSize(width: 40, height: -50)), CGVector(dx: 0.1, dy: -0.25))
        XCTAssertEqual(layout.photoPoint(CGPoint(x: 40, y: 150)), CGPoint(x: 40, y: 50))

        let big = MaskRegion(box: CGRect(x: 0.125, y: 0.125, width: 0.5, height: 0.75), manual: true)
        let face = MaskRegion(box: CGRect(x: 0.25, y: 0.375, width: 1.0 / 128, height: 1.0 / 64))
        XCTAssertEqual(layout.rect(big.box), CGRect(x: 50, y: 125, width: 200, height: 150))
        let tiny = layout.rect(face.box)
        XCTAssertEqual(tiny, CGRect(x: 100, y: 175, width: 3.125, height: 3.125))
        let center = CGPoint(x: tiny.midX, y: tiny.midY)
        let areas = [big, face]

        // The smallest area under the finger wins, and a tiny one answers within a finger's width.
        XCTAssertEqual(layout.grab(at: center, areas: areas, selected: nil), .area(face.id))
        XCTAssertEqual(layout.grab(at: CGPoint(x: center.x + 20, y: center.y), areas: areas, selected: nil), .area(face.id))
        XCTAssertEqual(layout.grab(at: CGPoint(x: 200, y: 250), areas: areas, selected: nil), .area(big.id))
        XCTAssertEqual(layout.grab(at: CGPoint(x: 350, y: 150), areas: areas, selected: nil), .empty)

        // A large selected area has its handles on its own corners.
        XCTAssertEqual(layout.handles(for: big.box).map(\.point),
                       [CGPoint(x: 50, y: 125), CGPoint(x: 250, y: 125), CGPoint(x: 50, y: 275), CGPoint(x: 250, y: 275)])
        XCTAssertEqual(layout.grab(at: CGPoint(x: 245, y: 270), areas: areas, selected: big.id), .corner(big.id, .bottomRight))
        XCTAssertEqual(layout.grab(at: CGPoint(x: 150, y: 200), areas: areas, selected: big.id), .area(big.id))

        // A tiny selected area spreads its handles so every corner and the middle stay reachable.
        let handles = layout.handles(for: face.box)
        XCTAssertEqual(handles.map(\.corner), MaskRegion.Corner.allCases)
        for handle in handles {
            XCTAssertEqual(layout.grab(at: handle.point, areas: areas, selected: face.id), .corner(face.id, handle.corner))
            let dx = handle.point.x - center.x, dy = handle.point.y - center.y
            XCTAssertGreaterThan((dx * dx + dy * dy).squareRoot(), RegionLayout.reach / 2)
        }
        XCTAssertEqual(layout.grab(at: center, areas: areas, selected: face.id), .area(face.id))

        // While a corner is dragged the handles keep their touch-down spacing, so the held one follows the finger.
        let grown = MaskRegion.resize(face.box, dragging: .bottomRight, by: layout.fraction(CGSize(width: 20, height: 10)),
                                      minimum: layout.minimum)
        let start = try XCTUnwrap(handles.first { $0.corner == .bottomRight }).point
        let held = try XCTUnwrap(layout.handles(for: grown, outset: layout.handleOutset(for: face.box))
            .first { $0.corner == .bottomRight }).point
        XCTAssertEqual(held.x, start.x + 20, accuracy: 1e-9)
        XCTAssertEqual(held.y, start.y + 10, accuracy: 1e-9)

        // Handles stay on the canvas even for an area in the photo's corner, and each still answers.
        let edge = MaskRegion(box: CGRect(x: 0, y: 0, width: 1.0 / 128, height: 1.0 / 64))
        let inside = layout.bounds.insetBy(dx: RegionLayout.handleMargin, dy: RegionLayout.handleMargin)
        for handle in layout.handles(for: edge.box) {
            XCTAssertTrue((inside.minX...inside.maxX).contains(handle.point.x)
                          && (inside.minY...inside.maxY).contains(handle.point.y))
            XCTAssertEqual(layout.grab(at: handle.point, areas: [edge], selected: edge.id), .corner(edge.id, handle.corner))
        }

        XCTAssertTrue(RegionLayout.isTap(CGSize(width: 3, height: 4)))
        XCTAssertFalse(RegionLayout.isTap(CGSize(width: 6, height: 8)))
    }

    func testPortraitExportAndSelectiveMasking() async throws {
        let width = 96, height = 64
        let engine = PhotoEngine()
        let photo = try await engine.open(try stripedPhoto(width: width, height: height, orientation: 6, gps: true))
        XCTAssertEqual(photo.source.width, height)
        XCTAssertEqual(photo.source.height, width)
        XCTAssertEqual(photo.page.size, CGSize(width: height, height: width))
        XCTAssertLessThanOrEqual(max(photo.page.thumbnail.width, photo.page.thumbnail.height), PhotoEngine.thumbnailLimit)
        let top = MaskRegion(box: CGRect(x: 0, y: 0, width: 1, height: 0.5))
        var bottom = MaskRegion(box: CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
        bottom.active = false
        let plan = MaskPlan(style: MaskStyle(mode: .cover, effect: .pixel, strength: .strong), regions: [top, bottom])
        let masked = try await engine.render(photo.source, plan: plan)
        XCTAssertNil(masked.overlay)
        let original = CIImage(cgImage: photo.source)
        let rendered = CIImage(cgImage: masked.image)
        func sample(_ image: CIImage, at y: CGFloat) -> [UInt8] {
            pixels(image, in: CGRect(x: 20, y: y, width: 1, height: 8))
        }
        XCTAssertLessThan(variation(sample(rendered, at: 72)), variation(sample(original, at: 72)) / 2)
        XCTAssertEqual(sample(rendered, at: 12), sample(original, at: 12))
        let jpeg = try await engine.jpeg(photo.page.original, plan: plan)
        let exported = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(exported, 0, nil) as? [CFString: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, height)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, width)
    }

    func testEveryEffectChangesOnlyTheCoveredArea() async throws {
        let engine = PhotoEngine()
        // 96 × 64 with vertical stripes; the top half (Core Image y 32..<64) is covered.
        let photo = try await engine.open(try stripedPhoto(width: 96, height: 64, orientation: 1))
        let original = CIImage(cgImage: photo.source)
        let top = MaskRegion(box: CGRect(x: 0, y: 0, width: 1, height: 0.5))
        for effect in MaskEffect.allCases {
            for strength in MosaicStrength.allCases {
                let plan = MaskPlan(style: MaskStyle(mode: .cover, effect: effect, strength: strength), regions: [top])
                let rendered = CIImage(cgImage: try await engine.render(photo.source, plan: plan).image)
                let row = CGRect(x: 8, y: 48, width: 80, height: 1)
                XCTAssertGreaterThan(difference(pixels(rendered, in: row), pixels(original, in: row)), 80 * 20,
                                     "\(effect) \(strength) should change the covered area")
                let untouched = CGRect(x: 8, y: 8, width: 80, height: 1)
                XCTAssertEqual(pixels(rendered, in: untouched), pixels(original, in: untouched),
                               "\(effect) \(strength) must not leak outside the covered area")
            }
        }
    }

    func testKeepModeCoversEverythingButTheChosenSubject() async throws {
        let engine = PhotoEngine()
        let photo = try await engine.open(try stripedPhoto(width: 96, height: 64, orientation: 1))
        let original = CIImage(cgImage: photo.source)
        // Subject 1 fills the left half of the photo and subject 2 the right half.
        let mapWidth = 24, mapHeight = 16
        let labels = (0..<(mapWidth * mapHeight)).map { UInt8($0 % mapWidth < mapWidth / 2 ? 1 : 2) }
        let map = SubjectMap(width: mapWidth, height: mapHeight, labels: labels)
        XCTAssertEqual(map.subjects.map(\.id), [1, 2])
        let left = CGRect(x: 4, y: 30, width: 30, height: 1)
        let right = CGRect(x: 62, y: 30, width: 30, height: 1)

        for effect in MaskEffect.allCases {
            let style = MaskStyle(mode: .keep, effect: effect, strength: .strong)
            let keepLeft = try await engine.render(photo.source, plan: MaskPlan(style: style, subjects: map, kept: [1]))
            XCTAssertNotNil(keepLeft.overlay)
            let rendered = CIImage(cgImage: keepLeft.image)
            XCTAssertLessThanOrEqual(largestGap(pixels(rendered, in: left), pixels(original, in: left)), 2,
                                     "\(effect): the kept subject stays as it was")
            XCTAssertGreaterThan(difference(pixels(rendered, in: right), pixels(original, in: right)), 30 * 20,
                                 "\(effect): the other subject is covered")

            // Nothing kept covers the whole photo.
            let none = CIImage(cgImage: try await engine.render(photo.source,
                                                                plan: MaskPlan(style: style, subjects: map)).image)
            XCTAssertGreaterThan(difference(pixels(none, in: left), pixels(original, in: left)), 30 * 20,
                                 "\(effect): with nothing kept the whole photo is covered")
        }
    }

    func testKeepAreaStaysWithoutAnySubjects() async throws {
        let engine = PhotoEngine()
        let photo = try await engine.open(try stripedPhoto(width: 96, height: 64, orientation: 1))
        let original = CIImage(cgImage: photo.source)
        // The bottom half of the upright photo is Core Image y 0..<32.
        let area = MaskRegion(box: CGRect(x: 0, y: 0.5, width: 1, height: 0.5), manual: true)
        let plan = MaskPlan(style: MaskStyle(mode: .keep, effect: .blur, strength: .regular), keepAreas: [area])
        XCTAssertTrue(plan.changesPhoto)
        let rendered = CIImage(cgImage: try await engine.render(photo.source, plan: plan).image)
        let kept = CGRect(x: 8, y: 10, width: 80, height: 1)
        let covered = CGRect(x: 8, y: 54, width: 80, height: 1)
        XCTAssertLessThanOrEqual(largestGap(pixels(rendered, in: kept), pixels(original, in: kept)), 2)
        XCTAssertGreaterThan(difference(pixels(rendered, in: covered), pixels(original, in: covered)), 80 * 20)
    }

    func testCoverModeWithNothingSelectedReturnsTheSource() async throws {
        let engine = PhotoEngine()
        let photo = try await engine.open(try stripedPhoto(width: 96, height: 64, orientation: 1))
        var off = MaskRegion(box: CGRect(x: 0, y: 0, width: 1, height: 1))
        off.active = false
        let plan = MaskPlan(style: MaskStyle(), regions: [off])
        XCTAssertFalse(plan.changesPhoto)
        let rendered = try await engine.render(photo.source, plan: plan).image
        XCTAssertTrue(rendered === photo.source)
    }

    func testSubjectMapFindsBoxesPeopleAndTaps() throws {
        var labels = [UInt8](repeating: 0, count: 100)
        for y in 2..<6 { for x in 1..<4 { labels[y * 10 + x] = 3 } }   // 12 pixels, a person
        for y in 4..<10 { for x in 5..<10 { labels[y * 10 + x] = 7 } } // 30 pixels, an object
        let face = CGRect(x: 0.15, y: 0.25, width: 0.1, height: 0.1)    // centre lands on subject 3
        let map = SubjectMap(width: 10, height: 10, labels: labels, faces: [face])

        XCTAssertEqual(map.subjects.map(\.id), [3, 7])
        let person = map.subjects[0], object = map.subjects[1]
        XCTAssertTrue(person.person)
        XCTAssertFalse(object.person)
        XCTAssertEqual(person.box.minX, 0.1, accuracy: 1e-9)
        XCTAssertEqual(person.box.minY, 0.2, accuracy: 1e-9)
        XCTAssertEqual(person.box.width, 0.3, accuracy: 1e-9)
        XCTAssertEqual(person.box.height, 0.4, accuracy: 1e-9)
        XCTAssertEqual(person.area, 0.12, accuracy: 1e-9)
        XCTAssertEqual(person.center.x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(person.center.y, 0.4, accuracy: 1e-9)

        // A person wins over a larger object.
        XCTAssertEqual(map.defaultKept, [3])
        XCTAssertEqual(SubjectMap(width: 10, height: 10, labels: labels).defaultKept, [7])

        XCTAssertEqual(map.subject(at: CGPoint(x: 0.25, y: 0.45))?.id, 3)
        XCTAssertEqual(map.subject(at: CGPoint(x: 0.42, y: 0.3))?.id, 3, "a near miss still finds the subject")
        XCTAssertNil(map.subject(at: CGPoint(x: 0.05, y: 0.95)))
        XCTAssertNil(map.subject(at: CGPoint(x: CGFloat.nan, y: 0.5)))
    }

    func testSubjectMaskAndOverlayFollowTheKeptLabels() throws {
        let map = SubjectMap(width: 4, height: 1, labels: [0, 1, 2, 1])
        let mask = try XCTUnwrap(map.mask(keeping: [1]))
        XCTAssertEqual(bytes(of: mask), [0, 255, 0, 255])
        XCTAssertNil(map.mask(keeping: []))
        XCTAssertNil(map.mask(keeping: [9]))

        let overlay = try XCTUnwrap(map.overlay(keeping: [2]))
        let tint = bytes(of: overlay)
        XCTAssertEqual(Array(tint[0..<4]), [0, 0, 0, 0], "background stays clear")
        XCTAssertEqual(tint[11], 128, "kept subject is tinted more strongly")
        XCTAssertEqual(tint[7], 64)
    }

    func testSpecksAreNotSubjects() {
        var labels = [UInt8](repeating: 0, count: 2500)
        labels[0] = 9
        for index in 1000..<1100 { labels[index] = 4 }
        let map = SubjectMap(width: 50, height: 50, labels: labels)
        XCTAssertEqual(map.subjects.map(\.id), [4])
        XCTAssertNil(map.subject(at: CGPoint(x: 0.005, y: 0.005)))
        XCTAssertNil(map.mask(keeping: [9]))
    }

    func testInvalidSubjectMapIsEmpty() {
        let map = SubjectMap(width: 3, height: 3, labels: [1, 2])
        XCTAssertTrue(map.subjects.isEmpty)
        XCTAssertTrue(map.defaultKept.isEmpty)
        XCTAssertNil(map.subject(at: CGPoint(x: 0.5, y: 0.5)))
    }

    // MARK: - Helpers

    /// A gray photo with one-pixel vertical stripes that exposes any blur or cell averaging.
    private func stripedPhoto(width: Int, height: Int, orientation: Int, gps: Bool = false) throws -> Data {
        let gray = CGColorSpaceCreateDeviceGray()
        let bytes = Data((0..<(width * height)).map { UInt8(($0 % width) % 2 == 0 ? 20 : 240) })
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let source = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width, space: gray, bitmapInfo: [], provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.tiff.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        if gps {
            let location: [CFString: Any] = [kCGImagePropertyGPSLatitude: 37.5, kCGImagePropertyGPSLatitudeRef: "N"]
            properties[kCGImagePropertyGPSDictionary] = location
        }
        CGImageDestinationAddImage(destination, source, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// Red channel of the pixels in `rect`, in Core Image coordinates (origin at the bottom left).
    private func pixels(_ image: CIImage, in rect: CGRect) -> [UInt8] {
        let count = Int(rect.width) * Int(rect.height)
        var result = [UInt8](repeating: 0, count: count * 4)
        result.withUnsafeMutableBytes { buffer in
            ci.render(image, toBitmap: buffer.baseAddress!, rowBytes: Int(rect.width) * 4,
                      bounds: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        return stride(from: 0, to: result.count, by: 4).map { result[$0] }
    }

    private func bytes(of image: CGImage) -> [UInt8] {
        guard let data = image.dataProvider?.data else { return [] }
        return [UInt8](data as Data)
    }

    private func variation(_ pixels: [UInt8]) -> Int {
        zip(pixels, pixels.dropFirst()).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
    }

    private func difference(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
    }

    private func largestGap(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }
}

@MainActor
final class BatchEditingTests: XCTestCase {
    private func settle(_ editor: Editor) async throws {
        let deadline = Date().addingTimeInterval(12)
        while editor.rendering && Date() < deadline {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertFalse(editor.rendering)
        XCTAssertNotNil(editor.preview)
    }

    func testAppendReplaceFailureAndKeepReview() async throws {
        let editor = Editor()
        let photo = try XCTUnwrap(FieldStudy.data)
        await editor.load([photo, photo], replacing: true) { $0 }
        let ids = editor.pages.map(\.id)
        XCTAssertEqual(ids.count, 2)
        editor.setMode(.keep)
        try await settle(editor)
        XCTAssertEqual(editor.unreviewedCount, 1)
        XCTAssertEqual(editor.unsavedCount, 1)
        editor.select(ids[1])
        try await settle(editor)
        XCTAssertEqual(editor.unsavedCount, 2)
        await editor.load([photo], replacing: false) { $0 }
        XCTAssertEqual(editor.pages.count, 3)
        let third = try XCTUnwrap(editor.currentID)
        await editor.load([Data()], replacing: true) { $0 }
        XCTAssertNotNil(editor.notice)
        XCTAssertEqual(editor.currentID, third)
        XCTAssertEqual(editor.pages.count, 3)
        editor.remove(third)
        XCTAssertEqual(editor.currentID, ids[1])
        editor.remove(ids[0])
        editor.remove(ids[1])
        XCTAssertNil(editor.current)
    }

    func testAreasCanBeDeletedAndReplacedForTheMode() async throws {
        let editor = Editor()
        let photo = try XCTUnwrap(FieldStudy.data)
        await editor.load([photo], replacing: true) { $0 }
        let page = try XCTUnwrap(editor.current)
        let drawn = MaskRegion(box: FieldStudy.plate, manual: true)
        editor.addArea(drawn)
        XCTAssertEqual(editor.editableAreas.last, drawn)

        // The full-screen editor hands back moved, added and deleted areas at once.
        var areas = editor.editableAreas
        areas[areas.count - 1].box = MaskRegion.move(drawn.box, by: CGVector(dx: -0.25, dy: 0))
        areas.append(MaskRegion(box: CGRect(x: 0.5, y: 0.0625, width: 0.125, height: 0.125), manual: true))
        editor.setAreas(areas, page: page.id, mode: .keep)
        XCTAssertNotEqual(editor.editableAreas, areas, "edits made for the other mode are dropped")
        editor.setAreas(areas, page: page.id, mode: .cover)
        XCTAssertEqual(editor.editableAreas, areas)
        XCTAssertEqual(editor.activeCount, areas.count)

        editor.removeArea(drawn.id)
        XCTAssertEqual(editor.editableAreas.count, areas.count - 1)
        XCTAssertFalse(editor.editableAreas.contains { $0.id == drawn.id })
        XCTAssertEqual(editor.current?.faces, page.faces, "keep mode still knows where the faces were")
        try await settle(editor)

        // In keep mode the editor changes the drawn areas to keep, never the areas to cover.
        editor.setMode(.keep)
        XCTAssertTrue(editor.editableAreas.isEmpty)
        let keep = MaskRegion(box: CGRect(x: 0.25, y: 0.25, width: 0.25, height: 0.25), manual: true)
        editor.setAreas([keep], page: page.id, mode: .keep)
        XCTAssertEqual(editor.current?.keepAreas, [keep])
        editor.removeArea(keep.id)
        XCTAssertEqual(editor.current?.keepAreas, [])
        XCTAssertEqual(editor.current?.regions.count, areas.count - 1)
        try await settle(editor)
    }

    func testSavingCopiesAndEditingAfterBatchSave() async throws {
        // The test must never write into a developer's personal photo library.
        #if targetEnvironment(simulator)
        try XCTSkipUnless(PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized,
                          "Grant photos-add to app.garim.mobile in the test simulator.")
        let editor = Editor()
        let photo = try XCTUnwrap(FieldStudy.data)
        await editor.load([photo, photo], replacing: true) { $0 }
        for id in editor.pages.map(\.id) {
            editor.select(id)
            editor.addArea(MaskRegion(box: FieldStudy.plate, manual: true))
        }
        try await settle(editor)
        XCTAssertEqual(editor.unsavedCount, 2)
        await editor.saveCurrent()
        XCTAssertEqual(editor.pages.filter(\.saved).count, 1)
        await editor.saveAll()
        XCTAssertTrue(editor.pages.allSatisfy(\.saved))
        XCTAssertFalse(editor.canSaveAll)
        editor.setEffect(.solid)
        try await settle(editor)
        XCTAssertEqual(editor.unsavedCount, 2)
        #else
        throw XCTSkip("Simulator photo library only.")
        #endif
    }
}
