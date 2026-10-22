import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO

/// The one Core Image pipeline behind the editor preview, the live viewfinder look and full-resolution export,
/// so what you see is what gets saved. Radii scale with the image, so a small preview matches the export.
final class PhotoRenderer: @unchecked Sendable {
    static let shared = PhotoRenderer()

    // CIContext is thread-safe; one instance avoids rebuilding GPU state per render.
    let context = CIContext(options: [.cacheIntermediates: false])
    private let mixerLock = NSLock()
    private var mixerCache: (mixer: ColorMixer, data: Data)?

    func render(_ edit: EditState, to original: CIImage) -> CIImage {
        guard !edit.isIdentity else { return original }
        let input = original
        let e0 = input.extent
        var image = input

        if !edit.calibration.isNeutral { image = calibrate(image, edit.calibration) }
        if edit.exposure != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: edit.exposure]) }
        if edit.temperature != 0 || edit.tint != 0 {
            // A target neutral below the source renders warmer.
            let f = CIFilter.temperatureAndTint()
            f.inputImage = image
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 - edit.temperature * 2500, y: -edit.tint * 120)
            image = f.outputImage ?? image
        }
        if edit.highlights != 0 || edit.shadows != 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = image
            // Highlights: − recovers, + brightens the top end a little.
            f.highlightAmount = Float(1 + min(edit.highlights, 0))
            f.shadowAmount = Float(edit.shadows)
            image = f.outputImage ?? image
            if edit.highlights > 0 {
                image = curve(image, [(0, 0), (0.25, 0.25), (0.5, 0.5), (0.75, 0.75 + 0.08 * edit.highlights), (1, 1)])
            }
        }
        if edit.contrast != 0 {
            // S-curve around the midpoint: steeper midtones, ends stay put.
            let k = 0.07 * edit.contrast
            image = curve(image, [(0, 0), (0.25, 0.25 - k), (0.5, 0.5), (0.75, 0.75 + k), (1, 1)])
        }
        if edit.whites != 0 || edit.blacks != 0 {
            let b = edit.blacks, w = edit.whites
            image = curve(image, [
                b < 0 ? (-0.15 * b, 0.0) : (0.0, 0.12 * b),
                (0.25, 0.25 + (b > 0 ? 0.04 * b : 0)),
                (0.5, 0.5),
                (0.75, 0.75 + (w > 0 ? 0.1 * w : 0)),
                (1, w < 0 ? 1 + 0.2 * w : 1),
            ])
        }
        if edit.saturation != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 + edit.saturation])
        }
        if edit.vibrance != 0 { image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": edit.vibrance]) }
        if !edit.mixer.isNeutral { image = applyMixer(edit.mixer, to: image) }
        if edit.gradeShadowAmount > 0 || edit.gradeHighlightAmount > 0 { image = grade(image, edit) }
        if !edit.curves.isIdentity { image = applyCurves(edit.curves, to: image) }

        var lookGrain = 0.0, lookHalation = 0.0
        if let recipe = edit.look.recipe, edit.lookStrength > 0 {
            let looked = renderLook(recipe, to: image, extent: e0)
            image = edit.lookStrength >= 1 ? looked : image.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: looked, kCIInputTimeKey: edit.lookStrength,
            ])
            lookGrain = recipe.grain * edit.lookStrength
            lookHalation = recipe.halation * edit.lookStrength
        }
        if edit.fade > 0 { image = fadeBlacks(image, amount: edit.fade) }

        image = applyGeometry(edit, to: image.cropped(to: e0))
        let e = image.extent

        if edit.motionBlur > 0 { image = motionBlur(image, amount: edit.motionBlur, degrees: edit.motionAngle, extent: e) }
        if edit.fringe > 0 { image = fringe(image, amount: edit.fringe, extent: e) }
        if edit.glow > 0 { image = glow(image, amount: edit.glow, extent: e) }
        let halationAmount = min(1, edit.halation + lookHalation)
        if halationAmount > 0 { image = halation(image, amount: halationAmount, spread: edit.halationSpread, extent: e) }
        if edit.lightLeak > 0 {
            image = lightLeak(image, amount: edit.lightLeak, size: edit.leakSize, warmth: edit.leakWarmth,
                              at: CGPoint(x: edit.leakX, y: edit.leakY), seed: edit.effectSeed, extent: e)
        }
        if edit.vignette != 0 { image = vignette(image, amount: edit.vignette, extent: e) }
        if edit.dust > 0 || edit.scratches > 0 {
            image = filmDamage(image, dust: edit.dust, scratches: edit.scratches, seed: edit.effectSeed, extent: e)
        }
        let grainAmount = min(1, edit.grain + lookGrain)
        if grainAmount > 0 { image = filmGrain(image, amount: grainAmount, size: edit.grainSize, extent: e) }
        return image.cropped(to: e)
    }

    /// Only the parts of an edit that make sense on live camera frames (the look and its strength).
    static func liveRecipe(from edit: EditState) -> EditState {
        var r = EditState()
        r.look = edit.look
        r.lookStrength = edit.lookStrength
        return r
    }

    // MARK: Look

    func renderLook(_ r: LookRecipe, to image: CIImage, extent: CGRect) -> CIImage {
        var x = image
        if r.exposure != 0 { x = x.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: r.exposure]) }
        if r.temperature != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = x
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 - r.temperature, y: 0)
            x = f.outputImage ?? x
        }
        if let w = r.mono {
            let weights = CIVector(x: w.0, y: w.1, z: w.2, w: 0)
            x = x.applyingFilter("CIColorMatrix", parameters: ["inputRVector": weights, "inputGVector": weights, "inputBVector": weights])
        }
        x = curve(x, r.curve.map { (Double($0.0), Double($0.1)) })
        if r.saturation != 1 { x = x.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: r.saturation]) }
        if r.vibrance != 0 { x = x.applyingFilter("CIVibrance", parameters: ["inputAmount": r.vibrance]) }
        if r.shadows != (0, 0, 0) || r.highlights != (0, 0, 0), let kernel = Self.kernel("lookSplitTone"),
           let toned = kernel.apply(extent: x.extent.isInfinite ? extent : x.extent, arguments: [
               x, CIVector(x: r.shadows.0, y: r.shadows.1, z: r.shadows.2),
               CIVector(x: r.highlights.0, y: r.highlights.1, z: r.highlights.2),
           ]) {
            x = toned
        }
        if r.glow > 0 { x = softGlow(x.cropped(to: extent), radius: extent.width / 260, amount: r.glow) }
        if r.clarity > 0 {
            x = x.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: max(1, extent.width / 90), kCIInputIntensityKey: r.clarity])
        }
        return x
    }

    // MARK: Building blocks

    /// Five-point tone curve on all channels.
    func curve(_ image: CIImage, _ points: [(Double, Double)]) -> CIImage {
        guard points.count == 5 else { return image }
        let f = CIFilter.toneCurve()
        f.inputImage = image
        f.point0 = CGPoint(x: points[0].0, y: points[0].1)
        f.point1 = CGPoint(x: points[1].0, y: points[1].1)
        f.point2 = CGPoint(x: points[2].0, y: points[2].1)
        f.point3 = CGPoint(x: points[3].0, y: points[3].1)
        f.point4 = CGPoint(x: points[4].0, y: points[4].1)
        return f.outputImage ?? image
    }

    /// Highlights-only bloom mixed in with a screen blend (never clips).
    private func softGlow(_ image: CIImage, radius: CGFloat, amount: Double) -> CIImage {
        let extent = image.extent
        let highlights = curve(image, [(0, 0), (0.6, 0), (0.75, 0.15), (0.9, 0.6), (1, 1)])
            .clampedToExtent().applyingGaussianBlur(sigma: Double(max(1, radius))).cropped(to: extent)
        let scaled = highlights.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: amount, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: amount, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: amount, w: 0),
        ])
        return scaled.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: image]).cropped(to: extent)
    }

    /// Fade: lifts the blacks to a neutral gray and softens the top end, for a matte film finish.
    func fadeBlacks(_ image: CIImage, amount: Double) -> CIImage {
        let k = min(max(amount, 0), 1)
        return curve(image, [(0, 0.16 * k), (0.25, 0.25 + 0.08 * k), (0.5, 0.5 + 0.02 * k), (0.75, 0.75 - 0.01 * k), (1, 1 - 0.05 * k)])
    }

    /// Separate tints for shadows and highlights (pure black and white stay neutral, brightness is kept).
    func grade(_ image: CIImage, _ e: EditState) -> CIImage {
        guard let kernel = Self.kernel("colorGrade") else { return image }
        func tint(_ hue: Double, _ amount: Double) -> CIVector {
            let h = hue.truncatingRemainder(dividingBy: 360) / 60
            let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
            let (r, g, b): (Double, Double, Double) = switch Int(h) % 6 {
            case 0: (1, x, 0)
            case 1: (x, 1, 0)
            case 2: (0, 1, x)
            case 3: (0, x, 1)
            case 4: (x, 0, 1)
            default: (1, 0, x)
            }
            let k = 0.12 * min(max(amount, 0), 1)
            return CIVector(x: (r - 0.5) * k, y: (g - 0.5) * k, z: (b - 0.5) * k)
        }
        return kernel.apply(extent: image.extent, arguments: [
            image, tint(e.gradeShadowHue, e.gradeShadowAmount), tint(e.gradeHighlightHue, e.gradeHighlightAmount), Float(0),
        ]) ?? image
    }

    /// Per-color hue, saturation and luminance through a 3D lookup table (rebuilt only when it changes).
    func applyMixer(_ mixer: ColorMixer, to image: CIImage) -> CIImage {
        let data: Data = mixerLock.withLock {
            if mixerCache?.mixer != mixer { mixerCache = (mixer, mixer.cubeData()) }
            return mixerCache?.data ?? Data()
        }
        let f = CIFilter.colorCubeWithColorSpace()
        f.inputImage = image
        f.cubeDimension = Float(ColorMixer.cubeSize)
        f.cubeData = data
        f.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        return f.outputImage ?? image
    }

    func applyCurves(_ curves: ToneCurves, to image: CIImage) -> CIImage {
        let table = curves.lut(count: 256)
        let data = table.withUnsafeBufferPointer { Data(buffer: $0) }
        return image.applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": data,
            "inputCurvesDomain": CIVector(x: 0, y: 1),
            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB) as Any,
        ])
    }

    func calibrate(_ image: CIImage, _ calibration: ColorCalibration) -> CIImage {
        let m = calibration.matrix()
        func row(_ r: Int) -> CIVector { CIVector(x: m[r][0], y: m[r][1], z: m[r][2], w: 0) }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": row(0), "inputGVector": row(1), "inputBVector": row(2),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
    }

    // MARK: Geometry

    /// Quarter turns, straighten (rotated and scaled up so no empty corners show), then the crop.
    func applyGeometry(_ edit: EditState, to image: CIImage) -> CIImage {
        var x = image
        let turns = ((edit.rotation % 4) + 4) % 4
        if turns != 0 {
            x = x.oriented([.up, .right, .down, .left][turns])
            x = x.transformed(by: CGAffineTransform(translationX: -x.extent.minX, y: -x.extent.minY))
        }
        if abs(edit.straighten) > 0.01 {
            let e = x.extent
            let angle = CGFloat(-edit.straighten * .pi / 180)
            let (w, h) = (e.width, e.height)
            // Smallest scale that keeps the rotated photo covering its original frame.
            let scale = (abs(cos(angle)) * w + abs(sin(angle)) * h) / w > (abs(sin(angle)) * w + abs(cos(angle)) * h) / h
                ? (abs(cos(angle)) * w + abs(sin(angle)) * h) / w : (abs(sin(angle)) * w + abs(cos(angle)) * h) / h
            let t = CGAffineTransform(translationX: e.midX, y: e.midY).rotated(by: angle).scaledBy(x: scale, y: scale)
                .translatedBy(x: -e.midX, y: -e.midY)
            x = x.clampedToExtent().transformed(by: t).cropped(to: e)
        }
        guard edit.cropRect != EditState.fullCrop else { return x }
        let e = x.extent
        let r = edit.cropRect
        let target = CGRect(x: e.minX + r.minX * e.width, y: e.minY + (1 - r.maxY) * e.height,
                            width: r.width * e.width, height: r.height * e.height).integral.intersection(e)
        guard !target.isEmpty else { return x }
        return x.cropped(to: target).transformed(by: CGAffineTransform(translationX: -target.minX, y: -target.minY))
    }

    // MARK: Effects

    /// Monochrome film grain added equally to R, G and B in display space, strongest in midtones.
    func filmGrain(_ image: CIImage, amount: Double, size: Double = 0.4, extent: CGRect) -> CIImage {
        guard amount > 0, let random = CIFilter.randomGenerator().outputImage, let kernel = Self.kernel("filmGrain") else { return image }
        // Size 0 = fine (cells of width/1600), 1 = coarse (width/550).
        let cell = max(1, extent.width / CGFloat(1600 - 1050 * min(max(size, 0), 1)))
        func octave(_ scale: CGFloat, offset: CGFloat) -> CIImage {
            random.transformed(by: CGAffineTransform(translationX: offset, y: offset * 0.6))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .applyingGaussianBlur(sigma: Double(0.55 * scale))
                .cropped(to: extent)
        }
        let display = image.applyingFilter("CILinearToSRGBToneCurve")
        let strength = Float(min(amount, 1) * 14 / 255)
        guard let grained = kernel.apply(extent: extent, arguments: [display, octave(cell, offset: 0), octave(cell * 2.2, offset: 517), strength])
        else { return image }
        return grained.applyingFilter("CISRGBToneCurveToLinear").cropped(to: extent)
    }

    /// Red-orange glow around bright lights, as light scatters back through the film base.
    func halation(_ image: CIImage, amount: Double, spread: Double = 0.5, extent: CGRect) -> CIImage {
        guard amount > 0, let sourceKernel = Self.kernel("halationSource"), let addKernel = Self.kernel("halationAdd"),
              let source = sourceKernel.apply(extent: extent, arguments: [image]) else { return image }
        // Spread 0 hugs the lights, 1 glows far around them.
        let wide = source.clampedToExtent().applyingGaussianBlur(sigma: Double(extent.width) / (120 - 90 * min(max(spread, 0), 1)))
            .cropped(to: extent)
        let tight = source.clampedToExtent().applyingGaussianBlur(sigma: Double(extent.width / 300)).cropped(to: extent)
        return addKernel.apply(extent: extent, arguments: [image, wide, tight, Float(0.9 * min(amount, 1))])?.cropped(to: extent) ?? image
    }

    /// Dreamy luminous softness over the sharp photo (Orton style).
    func glow(_ image: CIImage, amount: Double, extent e: CGRect) -> CIImage {
        let k = min(amount, 1)
        let soft = image.clampedToExtent().applyingGaussianBlur(sigma: Double(e.width / 60)).cropped(to: e)
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.35])
        let screened = soft.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: image]).cropped(to: e)
        return image.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: screened, kCIInputTimeKey: 0.6 * k])
            .cropped(to: e)
    }

    /// Light bleeding in like a film camera with a leak: a main glow where you placed it (`at`, 0...1 from the
    /// top-left), sized by `size`, warm orange (+warmth) to cool magenta-blue (-warmth), plus a fainter second
    /// glow whose spot comes from `seed` (Shuffle).
    func lightLeak(_ image: CIImage, amount: Double, size: Double = 0.5, warmth: Double = 0.5, at point: CGPoint = CGPoint(x: 0, y: 0.3),
                   seed: Int = 0, extent e: CGRect) -> CIImage {
        let span = max(e.width, e.height)
        let k = CGFloat(min(amount, 1))
        let w = CGFloat(min(max(warmth, -1), 1))
        func leak(_ x: CGFloat, _ y: CGFloat, strength: CGFloat, radius: CGFloat) -> CIImage {
            let f = CIFilter.radialGradient()
            f.center = CGPoint(x: e.minX + x * e.width, y: e.maxY - y * e.height)
            f.radius0 = 0
            f.radius1 = Float(radius)
            // Warm: orange. Cool: magenta toward blue.
            let r: CGFloat = w >= 0 ? 1 : 0.85 + 0.15 * w
            let g: CGFloat = w >= 0 ? 0.25 + 0.25 * w : 0.15
            let b: CGFloat = w >= 0 ? 0.25 - 0.18 * w : 0.45 - 0.4 * w
            f.color0 = CIColor(red: r * k * strength, green: g * k * strength, blue: b * k * strength)
            f.color1 = CIColor(red: 0, green: 0, blue: 0)
            return (f.outputImage ?? CIImage(color: .black)).cropped(to: e)
        }
        var rng = SplitMix64(seed: UInt64(bitPattern: Int64(seed)) &+ 0x1EAC)
        let radius = span * CGFloat(0.3 + 0.6 * min(max(size, 0), 1))
        let main = leak(CGFloat(point.x), CGFloat(point.y), strength: 1, radius: radius)
        let second = leak(CGFloat(Double.random(in: 0.6...1, using: &rng)), CGFloat(Double.random(in: 0...1, using: &rng)),
                          strength: 0.55, radius: radius * 0.7)
        let lit = main.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: image])
        return second.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: lit]).cropped(to: e)
    }

    /// Lens fringe: red and blue drift apart toward the edges (chromatic aberration), green stays put.
    func fringe(_ image: CIImage, amount: Double, extent e: CGRect) -> CIImage {
        let k = CGFloat(min(amount, 1)) * 0.006
        func scaled(_ s: CGFloat) -> CIImage {
            image.clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: -e.midX, y: -e.midY).concatenating(CGAffineTransform(scaleX: s, y: s))
                    .concatenating(CGAffineTransform(translationX: e.midX, y: e.midY)))
                .cropped(to: e)
        }
        func only(_ img: CIImage, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, alpha: CGFloat) -> CIImage {
            img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
            ])
        }
        let red = only(scaled(1 + k), 1, 0, 0, alpha: 0)
        let green = only(image, 0, 1, 0, alpha: 1)
        let blue = only(scaled(1 - k), 0, 0, 1, alpha: 0)
        return red.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: green])
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: blue]).cropped(to: e)
    }

    /// Directional motion blur across the whole frame (panning / camera-shake look).
    func motionBlur(_ image: CIImage, amount: Double, degrees: Double, extent e: CGRect) -> CIImage {
        let radius = Double(e.width) * 0.03 * min(amount, 1)
        return image.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [
            kCIInputRadiusKey: radius, kCIInputAngleKey: degrees * .pi / 180,
        ]).cropped(to: e)
    }

    /// Darker (+) or lighter (−) corners with a soft radial falloff, in exposure stops so hues stay put.
    func vignette(_ image: CIImage, amount: Double, extent: CGRect) -> CIImage {
        let half = hypot(extent.width, extent.height) / 2
        let mask = CIFilter.radialGradient()
        mask.center = CGPoint(x: extent.midX, y: extent.midY)
        mask.radius0 = Float(half * 0.3)
        mask.radius1 = Float(half * 1.05)
        mask.color0 = CIColor.white
        mask.color1 = CIColor.black
        let edge = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -1.8 * min(max(amount, -1), 1)])
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: edge, kCIInputMaskImageKey: mask.outputImage ?? CIImage.empty(),
        ]).cropped(to: extent)
    }

    // MARK: Kernels

    /// Kernels from Kernels.metal, compiled into the app's default.metallib at build time and cached by name.
    static func kernel(_ name: String) -> CIColorKernel? {
        kernelLock.withLock {
            if let cached = kernelCache[name] { return cached }
            guard let data = metalLibrary,
                  let loaded = try? CIColorKernel(functionName: name, fromMetalLibraryData: data) else { return nil }
            kernelCache[name] = loaded
            return loaded
        }
    }

    private static let metalLibrary: Data? = Bundle(for: PhotoRenderer.self)
        .url(forResource: "default", withExtension: "metallib").flatMap { try? Data(contentsOf: $0) }
    private static let kernelLock = NSLock()
    nonisolated(unsafe) private static var kernelCache: [String: CIColorKernel] = [:]

    // MARK: Encoding

    /// Highest-quality encode in the photo's own color space (Display P3 survives). HEIF is 10-bit when available.
    func encode(_ image: CIImage, as format: ExportFormat, colorSpace: CGColorSpace? = nil) throws -> Data {
        let space = colorSpace ?? image.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        let best = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 1.0]
        let data: Data? = switch format {
        case .jpeg: context.jpegRepresentation(of: image, colorSpace: space, options: best)
        case .heic: (try? context.heif10Representation(of: image, colorSpace: space, options: best))
            ?? context.heifRepresentation(of: image, format: .RGBA8, colorSpace: space, options: best)
        case .png: context.pngRepresentation(of: image, format: .RGBA16, colorSpace: space, options: [:])
        }
        guard let data else { throw ExportError.renderFailed }
        return data
    }
}
