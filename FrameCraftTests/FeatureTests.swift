import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FrameCraft

/// Everything about FrameCraft that can be checked without camera hardware.
final class CompositionTests: XCTestCase {
    private func features(_ subjects: [SceneSubject], aspect: CGFloat = 0.75) -> SceneFeatures {
        var f = SceneFeatures()
        f.subjects = subjects
        f.imageAspect = aspect
        return f
    }

    func testScanCropFillsTheViewWithTheChosenFrame() throws {
        // A centered frame a fifth of the view: the lens does it all (like .5× → 2.5×), no digital crop.
        let centered = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        XCTAssertEqual(ViewCrop.lensFactor(for: centered), 5, accuracy: 0.001)
        XCTAssertNil(ViewCrop.crop(centered, afterZoom: 5))

        // Off center: the lens zooms until the far edge reaches the view's edge, the rest is cropped.
        let off = CGRect(x: 0.5, y: 0.3, width: 0.25, height: 0.25)
        let k = ViewCrop.lensFactor(for: off)
        XCTAssertEqual(k, 2, accuracy: 0.001)
        let c = try XCTUnwrap(ViewCrop.crop(off, afterZoom: k))
        XCTAssertEqual(c.width, 0.5, accuracy: 0.001)
        XCTAssertEqual(c.height, 0.5, accuracy: 0.001)
        XCTAssertEqual(c.minX, 0.5, accuracy: 0.001)
        XCTAssertEqual(c.minY, 0.1, accuracy: 0.001)

        // When the lens can't zoom as far, the crop takes over and still lands on the same frame.
        let partial = try XCTUnwrap(ViewCrop.crop(off, afterZoom: 1))
        XCTAssertEqual(partial.minX, off.minX, accuracy: 0.001)
        XCTAssertEqual(partial.minY, off.minY, accuracy: 0.001)
        XCTAssertEqual(partial.width, off.width, accuracy: 0.001)

        // The photo's crop is the same part of the image the cropped viewfinder shows.
        let visible = CGRect(x: 0, y: 0.1, width: 1, height: 0.8)
        let shown = ViewCrop.visible(visible, crop: partial)
        XCTAssertEqual(shown.minX, 0.5, accuracy: 0.001)
        XCTAssertEqual(shown.minY, 0.1 + 0.3 * 0.8, accuracy: 0.001)
        XCTAssertEqual(ViewCrop.inView(shown, visible: visible).width, partial.width, accuracy: 0.001)

        // Screen points and rects map through the crop and back.
        let size = CGSize(width: 300, height: 400)
        let p = ViewCrop.uncropped(CGPoint(x: 150, y: 200), crop: partial, size: size)
        XCTAssertEqual(p.x, (0.5 + 0.125) * 300, accuracy: 0.001)
        let back = ViewCrop.cropped(CGRect(origin: p, size: .zero), crop: partial, size: size)
        XCTAssertEqual(back.minX, 150, accuracy: 0.001)
        XCTAssertEqual(back.minY, 200, accuracy: 0.001)

        // A frame past the view (zoom out) is pulled inside.
        let wide = try XCTUnwrap(ViewCrop.crop(CGRect(x: -0.1, y: 0.2, width: 0.9, height: 0.9), afterZoom: 1))
        XCTAssertEqual(wide.minX, 0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(wide.maxY, 1.0001)
    }

    func testMaxCropSizeFitsTheImage() {
        let square = CompositionEngine.maxCropSize(aspect: 1, imageAspect: 0.75)
        XCTAssertEqual(square.width, 1, accuracy: 0.0001)
        XCTAssertEqual(square.height, 0.75, accuracy: 0.0001, "a square in a 3:4 frame uses the full width")
        let tall = CompositionEngine.maxCropSize(aspect: 9.0 / 16.0, imageAspect: 0.75)
        XCTAssertEqual(tall.height, 1, accuracy: 0.0001)
        XCTAssertEqual(tall.width, 0.75, accuracy: 0.0001)
    }

    func testNoSubjectIsInconclusive() {
        let result = CompositionEngine.analyze(features([]))
        XCTAssertFalse(result.isConclusive)
        XCTAssertNil(result.primary)
        XCTAssertEqual(result.guidance.first?.id, "no-subject")
    }

    func testSuggestionKeepsSubjectAndPutsItOnAThird() throws {
        let subject = SceneSubject(kind: .salient, box: CGRect(x: 0.45, y: 0.45, width: 0.12, height: 0.1), confidence: 0.9)
        let result = CompositionEngine.analyze(features([subject]), aspect: 0.75)
        let best = try XCTUnwrap(result.primary)
        XCTAssertTrue(best.rect.contains(subject.box), "the subject is never cut")
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).insetBy(dx: -0.0001, dy: -0.0001).contains(best.rect))
        let toThird = CompositionEngine.thirds.map { hypot($0.x - best.target.x, $0.y - best.target.y) }.min() ?? 1
        let toCenter = hypot(best.target.x - 0.5, best.target.y - 0.5)
        XCTAssertLessThan(min(toThird, toCenter), 0.08, "the subject lands on a third or the center")
        XCTAssertTrue(result.isConclusive)
    }

    func testResultDependsOnTheScene() throws {
        let left = SceneSubject(kind: .salient, box: CGRect(x: 0.15, y: 0.4, width: 0.12, height: 0.1), confidence: 0.9)
        let right = SceneSubject(kind: .salient, box: CGRect(x: 0.72, y: 0.4, width: 0.12, height: 0.1), confidence: 0.9)
        let a = try XCTUnwrap(CompositionEngine.analyze(features([left])).primary)
        let b = try XCTUnwrap(CompositionEngine.analyze(features([right])).primary)
        XCTAssertNotEqual(a.rect, b.rect, "different scenes get different frames")
    }

    func testAlternativePlacesTheSubjectElsewhere() throws {
        let subject = SceneSubject(kind: .salient, box: CGRect(x: 0.45, y: 0.45, width: 0.08, height: 0.07), confidence: 0.9)
        let result = CompositionEngine.analyze(features([subject]))
        let best = try XCTUnwrap(result.primary)
        if let alternative = result.alternative {
            XCTAssertTrue(abs(alternative.target.x - best.target.x) > 0.1 || abs(alternative.target.y - best.target.y) > 0.1)
        }
    }

    func testFacesWinOverSalientObjects() {
        let face = SceneSubject(kind: .face, box: CGRect(x: 0.6, y: 0.2, width: 0.1, height: 0.08), confidence: 0.9)
        let thing = SceneSubject(kind: .salient, box: CGRect(x: 0.1, y: 0.6, width: 0.3, height: 0.3), confidence: 1)
        XCTAssertEqual(CompositionEngine.primarySubject(features([thing, face]))?.kind, .face)
    }

    func testGuidanceSeparatesMeasurementsFromSuggestions() {
        var f = features([SceneSubject(kind: .person, box: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.5), confidence: 0.9)])
        f.horizonDegrees = 4
        f.highlightClipping = 0.1
        let result = CompositionEngine.analyze(f)
        XCTAssertTrue(result.guidance.contains { $0.id == "level" && $0.kind == .measured })
        XCTAssertTrue(result.guidance.contains { $0.id == "highlights" && $0.kind == .measured })
        XCTAssertTrue(result.guidance.contains { $0.kind == .suggestion }, "taste is labeled as a suggestion")
        XCTAssertFalse(CompositionEngine.analyze(f, isFrontCamera: true).guidance.contains { $0.id == "level" })
    }

    func testAlignmentHintsPointTheRightWay() {
        let frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        // Subject right of the right third: it must move left in the picture, so the phone pans right.
        let right = CompositionEngine.alignment(subject: CGRect(x: 0.78, y: 0.3, width: 0.06, height: 0.06), in: frame)
        XCTAssertFalse(right.isAligned)
        XCTAssertTrue(right.hint.hasPrefix("Pan right"), right.hint)
        let on = CompositionEngine.alignment(subject: CGRect(x: 2.0 / 3 - 0.03, y: 1.0 / 3 - 0.03, width: 0.06, height: 0.06), in: frame)
        XCTAssertTrue(on.isAligned)
        XCTAssertEqual(on.hint, "")
    }

    func testAspectFillMappingRoundTrips() {
        let view = CGSize(width: 400, height: 400) // a 1:1 frame showing a 3:4 image
        let visible = AspectFillMapping.visibleRect(imageAspect: 0.75, viewSize: view)
        XCTAssertEqual(visible.minX, 0, accuracy: 0.0001)
        XCTAssertEqual(visible.width, 1, accuracy: 0.0001)
        XCTAssertEqual(visible.height, 0.75, accuracy: 0.0001)
        XCTAssertEqual(visible.minY, 0.125, accuracy: 0.0001, "a square shows the middle of the 3:4 frame")
        let point = CGPoint(x: 0.3, y: 0.6)
        let back = AspectFillMapping.toImage(AspectFillMapping.toView(point, imageAspect: 0.75, viewSize: view), imageAspect: 0.75, viewSize: view)
        XCTAssertEqual(back.x, point.x, accuracy: 0.0001)
        XCTAssertEqual(back.y, point.y, accuracy: 0.0001)
    }

    func testCaptureAspectsCropTheRightShape() {
        for option in CaptureAspect.allCases {
            let crop = AspectFillMapping.visibleRect(imageAspect: 0.75, viewSize: CGSize(width: option.ratio, height: 1))
            // Pixel aspect of the crop on a 3000 × 4000 photo.
            XCTAssertEqual(crop.width * 3000 / (crop.height * 4000), option.ratio, accuracy: 0.002, "\(option)")
        }
        XCTAssertEqual(CaptureAspect.allCases.map(\.label), ["3:4", "4:5", "9:16", "1:1"])
    }

    @MainActor
    func testCustomFrameKeepsItsAspectInsideTheImage() {
        let frame = LiveCameraModel.constrained(CGRect(x: 0.8, y: 0.8, width: 0.5, height: 0.2), aspect: 1, imageAspect: 0.75)
        XCTAssertEqual(frame.width * 3000 / (frame.height * 4000), 1, accuracy: 0.002)
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).insetBy(dx: -0.0001, dy: -0.0001).contains(frame))
        let free = LiveCameraModel.constrained(CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), aspect: nil, imageAspect: 0.75)
        XCTAssertEqual(free, CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
    }

    func testZoomPresetsFollowTheLenses() {
        XCTAssertEqual(CameraService.zoomPresets(minZoom: 0.5, maxZoom: 25, switchOvers: [1, 5]), [0.5, 1, 2, 5])
        XCTAssertEqual(CameraService.zoomPresets(minZoom: 1, maxZoom: 10, switchOvers: []), [1, 2])
        XCTAssertEqual(CameraService.zoomPresets(minZoom: 1, maxZoom: 1.5, switchOvers: []), [1])
    }

    func testScanFramesAreMerged() throws {
        var a = SceneFeatures(), b = SceneFeatures()
        a.meanLuminance = 0.2
        b.meanLuminance = 0.4
        a.horizonDegrees = 2
        let merged = try XCTUnwrap(FrameRouter.merge([a, b]))
        XCTAssertEqual(merged.meanLuminance, 0.3, accuracy: 0.0001)
        XCTAssertEqual(merged.horizonDegrees, 2)
    }
}

final class ImagingTests: XCTestCase {
    private let processor = PhotoRenderer.shared

    func testKernelsAreInTheApp() {
        for name in ["filmGrain", "halationSource", "halationAdd", "lookSplitTone", "colorGrade"] {
            XCTAssertNotNil(PhotoRenderer.kernel(name), "\(name) missing: that effect would silently do nothing")
        }
    }

    func testNoEditIsExactlyTheOriginal() {
        let input = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        XCTAssertTrue(processor.render(EditState(), to: input) === input)
    }

    func testIdentityCurveIsALine() {
        let samples = ToneCurves.sample(ToneCurves.xs, count: 11)
        for (i, v) in samples.enumerated() { XCTAssertEqual(v, Double(i) / 10, accuracy: 0.0001) }
        XCTAssertTrue(ToneCurves().isIdentity)
    }

    func testCurveHasNoOvershoot() {
        let samples = ToneCurves.sample([0, 0.05, 0.9, 0.95, 1], count: 200)
        for (a, b) in zip(samples, samples.dropFirst()) { XCTAssertGreaterThanOrEqual(b, a - 1e-9, "monotone points stay monotone") }
        XCTAssertTrue(samples.allSatisfy { (0...1).contains($0) })
    }

    func testCurvesChangeThePicture() throws {
        let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        var state = EditState()
        state.curves.red = [0, 0.4, 0.75, 0.9, 1]
        let pixel = try XCTUnwrap(rgb(processor.render(state, to: gray)))
        XCTAssertGreaterThan(pixel.r, pixel.b + 20, "lifting the red curve warms a gray")
    }

    func testOldOrBrokenEditsStillLoad() throws {
        let state = try JSONDecoder().decode(EditState.self, from: Data(#"{"exposure":0.5}"#.utf8))
        XCTAssertEqual(state.exposure, 0.5)
        XCTAssertTrue(state.curves.isIdentity)
        XCTAssertTrue(state.calibration.isNeutral)
        let bad = try JSONDecoder().decode(EditState.self, from: Data(#"{"curves":{"red":[2,0]},"dust":9,"exposure":"x","look":"gone"}"#.utf8))
        XCTAssertTrue(bad.curves.isIdentity, "malformed curves fall back to identity")
        XCTAssertEqual(bad.dust, 1, "out-of-range values are clamped")
        XCTAssertEqual(bad.exposure, 0)
        XCTAssertEqual(bad.look, .none, "an unknown look loads as no look")
        XCTAssertEqual(try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(bad)), bad, "round trip")
    }

    func testNeutralCalibrationIsIdentity() {
        let m = ColorCalibration().matrix()
        for r in 0..<3 { for c in 0..<3 { XCTAssertEqual(m[r][c], r == c ? 1 : 0, accuracy: 1e-9) } }
        var c = ColorCalibration()
        c.redSaturation = -1
        let red = c.matrix().map { $0[0] }
        XCTAssertLessThan(red[0] - max(red[1], red[2]), 1 - 0.0001, "less saturated red primary")
    }

    func testDustAndScratchesMarkTheImageTheSameWayEveryTime() throws {
        let gray = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 600, height: 400))
        let a = processor.filmDamage(gray, dust: 1, scratches: 1, extent: gray.extent)
        let b = processor.filmDamage(gray, dust: 1, scratches: 1, extent: gray.extent)
        XCTAssertEqual(a.extent, gray.extent)
        let pa = try XCTUnwrap(bytes(a)), pb = try XCTUnwrap(bytes(b))
        XCTAssertEqual(pa, pb, "same photo, same marks")
        XCTAssertTrue(processor.filmDamage(gray, dust: 0, scratches: 0, extent: gray.extent) === gray)
    }

    func testLooksAreDistinctAndChangeThePhoto() throws {
        let base = CIImage(color: CIColor(red: 0.55, green: 0.45, blue: 0.35)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        var seen: [[UInt8]] = []
        for look in FilmLook.allCases where look != .none {
            XCTAssertNotNil(look.recipe, "\(look)")
            var edit = EditState()
            edit.look = look
            let pixels = try XCTUnwrap(bytes(processor.render(edit, to: base).cropped(to: CGRect(x: 4, y: 4, width: 1, height: 1))))
            XCTAssertFalse(seen.contains(pixels), "\(look) looks like another look")
            seen.append(pixels)
        }
        XCTAssertNotNil(FilmLook.silverTone.recipe?.mono, "Silver Tone is monochrome")
        XCTAssertGreaterThan(FilmLook.push1600.recipe?.grain ?? 0, 0.4, "Push 1600 brings coarse grain")
        XCTAssertEqual(Set(FilmLook.allCases.map(\.label)).count, FilmLook.allCases.count, "names are unique")
    }

    func testLookStrengthBlendsTowardTheOriginal() throws {
        let base = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        var full = EditState(), half = EditState(), zero = EditState()
        full.look = .ember200
        half.look = .ember200
        zero.look = .ember200
        half.lookStrength = 0.5
        zero.lookStrength = 0
        let a = try XCTUnwrap(rgb(processor.render(full, to: base)))
        let b = try XCTUnwrap(rgb(processor.render(half, to: base)))
        let c = try XCTUnwrap(rgb(processor.render(zero, to: base)))
        XCTAssertGreaterThan(a.r - a.b, b.r - b.b, "half strength is less warm than full")
        XCTAssertLessThanOrEqual(abs(c.r - c.b), 2, "zero strength leaves gray neutral")
    }

    func testEverySliderChangesTheRender() throws {
        let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
        let gradient = try XCTUnwrap(CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 64, y: 64),
            "inputColor0": CIColor(red: 0.05, green: 0.05, blue: 0.08), "inputColor1": CIColor(red: 0.98, green: 0.95, blue: 0.9),
        ])?.outputImage).cropped(to: extent)
        let original = try XCTUnwrap(bytes(gradient))
        for p in EditParameter.allCases {
            var edit = EditState()
            edit[p] = p.range.upperBound
            let out = try XCTUnwrap(bytes(processor.render(edit, to: gradient)), "\(p)")
            XCTAssertNotEqual(out, original, "\(p) at full strength changes nothing")
        }
    }

    func testGeometryCropsAndRotates() {
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        var edit = EditState()
        edit.rotation = 1
        XCTAssertEqual(processor.applyGeometry(edit, to: image).extent.size, CGSize(width: 300, height: 400))
        edit.cropRect = CGRect(x: 0, y: 0.25, width: 1, height: 0.5)
        XCTAssertEqual(processor.applyGeometry(edit, to: image).extent.size, CGSize(width: 300, height: 200))
        let square = CropMath.centered(ratio: 1, imageSize: CGSize(width: 4000, height: 3000))
        XCTAssertEqual(square.width, 0.75, accuracy: 0.0001)
        XCTAssertEqual(square.minX, 0.125, accuracy: 0.0001)
    }

    private func rgb(_ image: CIImage) -> (r: Int, g: Int, b: Int)? {
        guard let data = bytes(image.cropped(to: CGRect(x: 4, y: 4, width: 1, height: 1))) else { return nil }
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    private func bytes(_ image: CIImage) -> [UInt8]? {
        let e = image.extent
        guard let cg = processor.context.createCGImage(image, from: e) else { return nil }
        var out = [UInt8](repeating: 0, count: Int(e.width) * Int(e.height) * 4)
        let drawn = out.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: Int(e.width), height: Int(e.height), bitsPerComponent: 8,
                                      bytesPerRow: Int(e.width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: e.width, height: e.height))
            return true
        }
        return drawn ? out : nil
    }
}

final class ProjectAndExportTests: XCTestCase {
    private var store: ProjectStore!

    override func setUp() {
        store = ProjectStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("projects-\(UUID().uuidString)"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: store.directory)
    }

    /// A small JPEG with real EXIF capture facts.
    private func photoData(exif: [CFString: Any]? = nil, tiff: [CFString: Any]? = nil) throws -> Data {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 120, height: 90, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 90))
        let image = try XCTUnwrap(ctx.makeImage())
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        var props: [CFString: Any] = [:]
        if let exif { props[kCGImagePropertyExifDictionary] = exif }
        if let tiff { props[kCGImagePropertyTIFFDictionary] = tiff }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    func testProjectKeepsOriginalAndEdit() throws {
        let original = try photoData()
        var edit = EditState()
        edit.look = .deepPrint
        edit.cropRect = CGRect(x: 0, y: 0.1, width: 1, height: 0.8)
        var project = try store.create(original: original, typeIdentifier: UTType.jpeg.identifier, source: .camera, edit: edit)
        XCTAssertEqual(try Data(contentsOf: store.originalURL(project)), original, "the original is stored byte for byte")

        project.edit.exposure = 0.7
        project.finish = FinishSettings(frame: .paper, dateStamp: true)
        try store.save(project)
        let loaded = try XCTUnwrap(store.load(project.id))
        XCTAssertEqual(loaded.edit.exposure, 0.7)
        XCTAssertEqual(loaded.edit.look, .deepPrint)
        XCTAssertEqual(loaded.finish.frame, .paper)
        XCTAssertEqual(try Data(contentsOf: store.originalURL(loaded)), original, "saving an edit never touches the original")

        let copy = try store.duplicate(loaded)
        XCTAssertNotEqual(copy.id, loaded.id)
        XCTAssertEqual(store.list().count, 2)
        store.delete(loaded.id)
        XCTAssertEqual(store.list().map(\.id), [copy.id], "deleting one edit keeps the other")
    }

    func testMissingOriginalIsReportedNotHidden() throws {
        let project = try store.create(original: try photoData(), typeIdentifier: UTType.jpeg.identifier, source: .imported, edit: EditState())
        try FileManager.default.removeItem(at: store.originalURL(project))
        XCTAssertEqual(store.list().count, 1)
        XCTAssertFalse(store.hasOriginal(project))
        XCTAssertThrowsError(try store.duplicate(project))
    }

    func testMetadataIsReadNotInvented() throws {
        let data = try photoData(exif: [kCGImagePropertyExifISOSpeedRatings: [200], kCGImagePropertyExifExposureTime: 0.004,
                                        kCGImagePropertyExifFNumber: 1.8, kCGImagePropertyExifDateTimeOriginal: "2026:10:22 14:05:00"],
                                 tiff: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 16 Pro"])
        let m = CaptureMetadata(data: data)
        XCTAssertEqual(m.iso, 200)
        XCTAssertEqual(m.cameraLine, "iPhone 16 Pro")
        XCTAssertTrue(m.settingsLine.contains("1/250s"), m.settingsLine)
        XCTAssertTrue(m.settingsLine.contains("ƒ/1.8"), m.settingsLine)
        XCTAssertEqual(m.stampText, "'26 10 22")

        let bare = CaptureMetadata(data: try photoData())
        XCTAssertNil(bare.date)
        XCTAssertNil(bare.stampText, "no date, no stamp")
        XCTAssertNil(bare.iso)
        XCTAssertFalse(bare.settingsLine.contains("ISO"))
    }

    func testFramesGrowTheCanvasAndKeepThePhoto() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        let photo = try XCTUnwrap(ctx.makeImage())
        for style in FrameStyle.allCases where style != .none {
            let out = try XCTUnwrap(FinishingRenderer.render(photo, settings: FinishSettings(frame: style), metadata: CaptureMetadata()), "\(style)")
            let inset = FinishingRenderer.insets(for: style, size: CGSize(width: 300, height: 200))
            XCTAssertEqual(out.width, Int(300 + inset.left + inset.right), "\(style)")
            XCTAssertEqual(out.height, Int(200 + inset.top + inset.bottom), "\(style)")
        }
        let none = FinishingRenderer.finish(CIImage(cgImage: photo), settings: FinishSettings(), metadata: CaptureMetadata())
        XCTAssertEqual(none.extent.size, CGSize(width: 300, height: 200), "no finish, no change")
    }

    func testExportKeepsCaptureMetadataAndCanDropLocation() throws {
        let original = try photoData(exif: [kCGImagePropertyExifISOSpeedRatings: [320], kCGImagePropertyExifDateTimeOriginal: "2026:10:22 09:00:00"])
        var withGPS = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil)), 0, nil) as? [String: Any])
        withGPS[kCGImagePropertyGPSDictionary as String] = [kCGImagePropertyGPSLatitude as String: 48.85, kCGImagePropertyGPSLatitudeRef as String: "N"]
        XCTAssertNotNil(ExportService.carriedMetadata(withGPS, removeLocation: false)[kCGImagePropertyGPSDictionary as String])
        XCTAssertNil(ExportService.carriedMetadata(withGPS, removeLocation: true)[kCGImagePropertyGPSDictionary as String])

        var edit = EditState()
        edit.exposure = 0.3
        let exported = try ExportService().render(original: original, edit: edit, options: ExportOptions())
        let m = CaptureMetadata(data: exported)
        XCTAssertEqual(m.iso, 320, "the exported copy keeps the capture settings")
        XCTAssertNotNil(m.date, "and the capture date")
    }

    func testExportAddsTheFrameAndWritesEveryFormat() throws {
        let original = try photoData()
        var options = ExportOptions()
        options.finish = FinishSettings(frame: .white)
        let exported = try ExportService().render(original: original, edit: EditState(), options: options)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(exported as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertGreaterThan(props[kCGImagePropertyPixelWidth] as? Int ?? 0, 120, "the white frame widens the exported copy")
        for format in ExportFormat.allCases {
            XCTAssertFalse(try ExportService().render(original: original, edit: EditState(), options: ExportOptions(format: format)).isEmpty, "\(format)")
        }
    }
}

@MainActor
final class EditSessionTests: XCTestCase {
    private func session() -> EditSession {
        let project = PhotoProject(source: .imported, originalFile: "original.jpg", typeIdentifier: nil, edit: EditState())
        return EditSession(project: project, original: Data(), store: nil)
    }

    func testUndoRedo() {
        let s = session()
        var first = EditState()
        first.exposure = 1
        s.replace(with: first)
        var second = s.edit
        second.look = .goldenSplit
        s.replace(with: second)
        XCTAssertTrue(s.canUndo)
        s.undo()
        XCTAssertEqual(s.edit.look, .none)
        XCTAssertEqual(s.edit.exposure, 1)
        XCTAssertTrue(s.canRedo)
        s.redo()
        XCTAssertEqual(s.edit.look, .goldenSplit)
        s.undo()
        s.undo()
        XCTAssertTrue(s.edit.isIdentity)
        XCTAssertFalse(s.canUndo)
    }

    func testOneDragIsOneUndoStep() {
        let s = session()
        for v in stride(from: 0.1, through: 1.0, by: 0.1) { s.update { $0.contrast = v } }
        XCTAssertEqual(s.edit.contrast, 1, accuracy: 0.0001)
        s.undo()
        XCTAssertEqual(s.edit.contrast, 0, "the whole drag undoes at once")
    }

    func testResetOnlyTouchesItsGroup() {
        var e = EditState()
        e.exposure = 1
        e.grain = 0.5
        e.look = .silverTone
        let reset = e.resetting(.light)
        XCTAssertEqual(reset.exposure, 0)
        XCTAssertEqual(reset.grain, 0.5)
        XCTAssertEqual(reset.look, .silverTone)
    }
}

final class FramingCoachTests: XCTestCase {
    private let view = ViewContext(visible: CGRect(x: 0, y: 0, width: 1, height: 1), zoom: 1, minZoom: 0.5, maxZoom: 15)

    func testFaceDirectionFromLandmarks() {
        XCTAssertEqual(SceneAnalyzer.facing(nose: CGPoint(x: 0.62, y: 0.5), leftEye: CGPoint(x: 0.35, y: 0.6), rightEye: CGPoint(x: 0.65, y: 0.6)), 1)
        XCTAssertEqual(SceneAnalyzer.facing(nose: CGPoint(x: 0.38, y: 0.5), leftEye: CGPoint(x: 0.35, y: 0.6), rightEye: CGPoint(x: 0.65, y: 0.6)), -1)
        XCTAssertEqual(SceneAnalyzer.facing(nose: CGPoint(x: 0.51, y: 0.5), leftEye: CGPoint(x: 0.35, y: 0.6), rightEye: CGPoint(x: 0.65, y: 0.6)), 0)
    }

    func testLeadSpaceGoesInFrontOfTheFace() throws {
        var f = SceneFeatures()
        f.subjects = [SceneSubject(kind: .face, box: CGRect(x: 0.45, y: 0.3, width: 0.1, height: 0.08), confidence: 0.9, facing: 1)]
        let best = try XCTUnwrap(FramingCoach.plans(f, view: view, aspect: 0.75).first)
        XCTAssertLessThan(best.anchor.x, 0.45, "looking right, so the face goes left with space to the right")
        f.subjects[0].facing = -1
        let other = try XCTUnwrap(FramingCoach.plans(f, view: view, aspect: 0.75).first)
        XCTAssertGreaterThan(other.anchor.x, 0.55)
    }

    func testPersonFramesNeverCutAtAJoint() throws {
        var f = SceneFeatures()
        f.subjects = [SceneSubject(kind: .face, box: CGRect(x: 0.46, y: 0.12, width: 0.08, height: 0.07), confidence: 0.9),
                      SceneSubject(kind: .person, box: CGRect(x: 0.38, y: 0.1, width: 0.24, height: 0.85), confidence: 0.9)]
        f.poses = [PersonPose(joints: [
            .nose: CGPoint(x: 0.5, y: 0.16), .neck: CGPoint(x: 0.5, y: 0.22),
            .leftShoulder: CGPoint(x: 0.44, y: 0.23), .rightShoulder: CGPoint(x: 0.56, y: 0.23),
            .leftElbow: CGPoint(x: 0.42, y: 0.36), .rightElbow: CGPoint(x: 0.58, y: 0.36),
            .leftWrist: CGPoint(x: 0.41, y: 0.47), .rightWrist: CGPoint(x: 0.59, y: 0.47),
            .leftHip: CGPoint(x: 0.46, y: 0.5), .rightHip: CGPoint(x: 0.54, y: 0.5),
            .leftKnee: CGPoint(x: 0.46, y: 0.7), .rightKnee: CGPoint(x: 0.54, y: 0.7),
            .leftAnkle: CGPoint(x: 0.46, y: 0.9), .rightAnkle: CGPoint(x: 0.54, y: 0.9),
        ])]
        let plans = FramingCoach.plans(f, view: view, aspect: 0.75)
        let best = try XCTUnwrap(plans.first)
        XCTAssertNotEqual(best.kind, .subject, "a person with a pose gets a person framing")
        XCTAssertEqual(best.breakdown["joints"] ?? 0, 1, accuracy: 0.0001, "the best frame cuts no joint")
        for joint in [0.36, 0.47, 0.5, 0.7, 0.9] as [CGFloat] {
            XCTAssertGreaterThan(abs(best.rect.maxY - joint), 0.01, "bottom edge isn't on a joint at \(joint)")
        }
        XCTAssertEqual(Set(plans.map(\.kind)), [.headAndShoulders, .waistUp, .kneesUp, .fullBody])
    }

    func testHorizonIsFoundFromTheBrightnessStep() throws {
        let rows = (0..<48).map { $0 < 19 ? 0.8 : 0.3 }
        let texture = (0..<48).map { $0 < 19 ? 0.01 : 0.08 }
        let horizon = try XCTUnwrap(SceneAnalyzer.horizon(rows: rows, texture: texture, visionFound: false))
        XCTAssertEqual(horizon.y, 19.0 / 48, accuracy: 0.03)
        XCTAssertTrue(horizon.skyIsPlain)
        XCTAssertNil(SceneAnalyzer.horizon(rows: Array(repeating: 0.5, count: 48), texture: Array(repeating: 0.02, count: 48), visionFound: true))
    }

    func testLandscapePutsTheHorizonOnAThird() throws {
        var f = SceneFeatures()
        f.horizon = HorizonLine(y: 0.5, skyIsPlain: true)
        let best = try XCTUnwrap(FramingCoach.plans(f, view: view, aspect: 0.75).first)
        XCTAssertEqual(best.kind, .landscape)
        XCTAssertEqual(try XCTUnwrap(best.horizonTarget), 1.0 / 3, accuracy: 0.001, "plain sky: horizon high, more foreground")
        let advice = FramingCoach.advice(for: best, view: view, horizonNow: 0.5)
        XCTAssertTrue(advice.hints.contains("Tilt down"), "the horizon has to move up in the picture: \(advice.hints)")
        XCTAssertFalse(advice.isAligned)
    }

    func testAdviceDirectionsZoomAndStepBack() {
        // Subject at the far left, plan wants it on the left third at the same size.
        var plan = FramingPlan(kind: .subject, rect: CGRect(x: 0, y: 0, width: 1, height: 1), anchor: CGPoint(x: 1.0 / 3, y: 1.0 / 3),
                               anchorNow: CGPoint(x: 0.1, y: 1.0 / 3), horizonTarget: nil, score: 1, breakdown: [:])
        var advice = FramingCoach.advice(for: plan, view: view, horizonNow: nil)
        XCTAssertEqual(advice.hints, ["Pan left"], "the subject must move right in the picture")
        plan.anchorNow = CGPoint(x: 1.0 / 3, y: 1.0 / 3)
        XCTAssertTrue(FramingCoach.advice(for: plan, view: view, horizonNow: nil).isAligned)

        plan.rect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        plan.anchorNow = CGPoint(x: 0.25 + 0.5 / 3, y: 0.25 + 0.5 / 3)
        advice = FramingCoach.advice(for: plan, view: view, horizonNow: nil)
        XCTAssertEqual(advice.zoomTo ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(advice.hints, ["Zoom to 2×"], "already in the right spot for the zoomed frame")

        plan.rect = CGRect(x: -0.5, y: -0.5, width: 2, height: 2)
        let wide = FramingCoach.advice(for: plan, view: ViewContext(visible: view.visible, zoom: 0.5, minZoom: 0.5, maxZoom: 15), horizonNow: nil)
        XCTAssertTrue(wide.stepBack, "can't zoom out past the widest lens")
        XCTAssertNil(wide.zoomTo)
    }

    func testFrontCameraGetsRingInstructions() {
        let plan = FramingPlan(kind: .subject, rect: CGRect(x: 0, y: 0, width: 1, height: 1), anchor: CGPoint(x: 1.0 / 3, y: 1.0 / 3),
                               anchorNow: CGPoint(x: 0.8, y: 0.8), horizonTarget: nil, score: 1, breakdown: [:])
        var front = view
        front.isFront = true
        XCTAssertEqual(FramingCoach.advice(for: plan, view: front, horizonNow: nil).hints, ["Line up with the ring"])
    }

    func testTargetHoldsSteadyUntilSomethingIsClearlyBetter() {
        func plan(_ x: CGFloat, _ score: Double) -> FramingPlan {
            FramingPlan(kind: .subject, rect: CGRect(x: 0, y: 0, width: 1, height: 1), anchor: CGPoint(x: x, y: 1.0 / 3),
                        anchorNow: .zero, horizonTarget: nil, score: score, breakdown: [:])
        }
        let previous = plan(1.0 / 3, 0.8)
        let held = FramingCoach.stabilized(previous: previous, candidates: [plan(2.0 / 3, 0.85), plan(0.34, 0.8)])
        XCTAssertLessThan(held?.anchor.x ?? 1, 0.5, "a slightly better other third doesn't steal the target")
        let switched = FramingCoach.stabilized(previous: previous, candidates: [plan(2.0 / 3, 0.95), plan(0.34, 0.8)])
        XCTAssertGreaterThan(switched?.anchor.x ?? 0, 0.5, "a clearly better one does")
    }
}

final class ScanAndEditTests: XCTestCase {
    func testAutoEditBrightensADarkPhotoAndAddsALook() {
        let dark = (0..<400).map { Double($0 % 40) / 400 + 0.02 } // mostly deep shadows
        let edit = AutoEdit.suggest(luma: dark, base: EditState())
        XCTAssertGreaterThan(edit.exposure, 0.3)
        XCTAssertGreaterThan(edit.shadows, 0)
        XCTAssertEqual(edit.look, .clean, "opens with a look, like the reference")
        XCTAssertGreaterThan(edit.grain, 0)
        var chosen = EditState()
        chosen.look = .silverTone
        XCTAssertEqual(AutoEdit.suggest(luma: dark, base: chosen).look, .silverTone, "a look picked before shooting stays")
        let even = (0..<400).map { 0.25 + Double($0 % 50) / 100 }
        XCTAssertEqual(AutoEdit.suggest(luma: even, base: EditState()).exposure, 0, "a well exposed photo isn't pushed")
    }

    func testInstructionsFollowTheMeasuredScene() {
        var f = ShotDirector.Facts(subject: "flower", scene: "bedroom", kind: .subject, contrast: 0.3, fill: 0.1,
                                   anchorX: 1.0 / 3, horizonTarget: nil, facing: 0)
        XCTAssertEqual(ShotDirector.instruction(f), "Isolate the flower against the dark background.")
        f.contrast = -0.3
        XCTAssertEqual(ShotDirector.instruction(f), "Silhouette the flower against the light.")
        f.contrast = 0
        XCTAssertEqual(ShotDirector.instruction(f), "Place the flower on the left third.")
        f.kind = .landscape
        f.horizonTarget = 1.0 / 3
        XCTAssertEqual(ShotDirector.instruction(f), "Put the horizon on the upper third.")
        f.kind = .waistUp
        f.facing = 1
        XCTAssertEqual(ShotDirector.instruction(f), "Frame them waist up, with room in front of their face.")
        XCTAssertEqual(ShotDirector.tag(subject: "flower", scene: "bedroom"), "flower · bedroom")
        XCTAssertEqual(ShotDirector.readable("flower_arrangement"), "flower arrangement")
    }

    func testModelWordingIsCleanedOrRejected() {
        XCTAssertEqual(ShotDirector.clean("\"move closer to the vase\"\nextra"), "Move closer to the vase.")
        XCTAssertNil(ShotDirector.clean("ok"))
        XCTAssertNil(ShotDirector.clean(String(repeating: "a", count: 120)))
    }

    func testExposureStops() {
        XCTAssertEqual(ExposureStops.shutterLabel(1), "1\"")
        XCTAssertEqual(ExposureStops.shutterLabel(0.5), "0.5\"")
        XCTAssertEqual(ExposureStops.shutterLabel(1.0 / 250), "1/250")
        XCTAssertEqual(ExposureStops.isos(in: 50...3200).first, 50)
        XCTAssertEqual(ExposureStops.isos(in: 50...3200).last, 3200)
        XCTAssertTrue(ExposureStops.shutters(in: (1.0 / 1000)...1).contains(1.0 / 60))
    }

    func testEffectOptionsChangeTheResult() throws {
        let renderer = PhotoRenderer.shared
        let extent = CGRect(x: 0, y: 0, width: 96, height: 96)
        let gray = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: extent)
        func png(_ e: EditState) throws -> Data {
            let out = renderer.render(e, to: gray)
            let cg = try XCTUnwrap(renderer.context.createCGImage(out, from: extent))
            return try XCTUnwrap(renderer.context.pngRepresentation(of: CIImage(cgImage: cg), format: .RGBA8,
                                                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        }
        var leak = EditState()
        leak.lightLeak = 1
        var moved = leak
        moved.leakX = 1
        moved.leakY = 1
        XCTAssertNotEqual(try png(leak), try png(moved), "placing the leak moves it")
        var cool = leak
        cool.leakWarmth = -1
        XCTAssertNotEqual(try png(leak), try png(cool), "warmth changes its color")
        var dust = EditState()
        dust.dust = 1
        var shuffled = dust
        shuffled.effectSeed = 42
        XCTAssertNotEqual(try png(dust), try png(shuffled), "shuffle picks another pattern")
    }
}
