import AVFoundation
import CoreImage
import MetalKit
import SwiftUI

/// The live viewfinder: the camera's preview layer, with a Metal view on top that shows the chosen look
/// on the live frames while one is selected.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let look: LiveLookRenderer
    /// The scan's crop (0...1 of the view), blown up to fill the view; nil shows everything.
    var crop: CGRect?
    var onLayer: (AVCaptureVideoPreviewLayer) -> Void

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer } // layerClass guarantees it
        let lookView = MTKView()

        override func layoutSubviews() {
            super.layoutSubviews()
            lookView.frame = bounds
        }
    }

    /// Holds the preview and scales it so the crop fills the frame SwiftUI gives it (a view SwiftUI sizes
    /// itself shouldn't carry a transform).
    final class CropView: UIView {
        let preview = PreviewView()
        var crop: CGRect?

        override func layoutSubviews() {
            super.layoutSubviews()
            preview.transform = .identity
            preview.frame = bounds
            preview.transform = Self.transform(for: crop, size: bounds.size)
        }

        /// Scales about the center so `crop` fills the view.
        static func transform(for crop: CGRect?, size: CGSize) -> CGAffineTransform {
            guard let c = crop, c.width > 0 else { return .identity }
            let s = 1 / c.width
            return CGAffineTransform(translationX: (0.5 - c.midX) * size.width * s, y: (0.5 - c.midY) * size.height * s)
                .scaledBy(x: s, y: s)
        }
    }

    func makeUIView(context: Context) -> CropView {
        let container = CropView()
        container.clipsToBounds = true
        container.backgroundColor = .black
        container.isUserInteractionEnabled = false
        let view = container.preview
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        look.attach(view.lookView)
        view.addSubview(view.lookView)
        container.addSubview(view)
        onLayer(view.previewLayer)
        return container
    }

    func updateUIView(_ container: CropView, context: Context) {
        let view = container.preview
        if view.previewLayer.session !== session { view.previewLayer.session = session }
        if container.crop != crop {
            container.crop = crop
            let next = CropView.transform(for: crop, size: container.bounds.size)
            UIView.animate(withDuration: 0.5, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) { view.transform = next }
        }
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(90),
           connection.videoRotationAngle != 90 {
            connection.videoRotationAngle = 90
        }
    }
}

/// Draws live frames through the photo pipeline's look (and its strength) at screen size.
/// Heavier edits (subject masks, effects) are left for the captured photo, where they render at full quality.
final class LiveLookRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CVPixelBuffer?
    private var recipe = EditState()
    private var active = false
    private let device = MTLCreateSystemDefaultDevice()
    private lazy var commandQueue = device?.makeCommandQueue()
    private lazy var context: CIContext? = device.map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) }
    private weak var view: MTKView?
    private let processor = PhotoRenderer.shared

    var isActive: Bool { lock.withLock { active } }

    @MainActor
    func attach(_ view: MTKView) {
        view.device = device
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.contentScaleFactor = 2 // a little under native: the look stays smooth at 30 fps
        view.colorPixelFormat = .bgra8Unorm
        view.delegate = self
        view.isHidden = !isActive
        view.backgroundColor = .clear
        self.view = view
    }

    @MainActor
    func setRecipe(_ edit: EditState) {
        let r = PhotoRenderer.liveRecipe(from: edit)
        let on = !r.isIdentity && device != nil
        lock.withLock {
            recipe = r
            active = on
        }
        view?.isHidden = !on
    }

    func push(_ buffer: CVPixelBuffer) {
        let shouldDraw = lock.withLock { () -> Bool in
            guard active else { return false }
            let idle = pending == nil
            pending = buffer
            return idle
        }
        guard shouldDraw else { return }
        DispatchQueue.main.async { [weak self] in self?.view?.draw() }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let (buffer, recipe) = lock.withLock { () -> (CVPixelBuffer?, EditState) in
            defer { pending = nil }
            return (pending, self.recipe)
        }
        guard let buffer, let context, let commandQueue, let drawable = view.currentDrawable,
              let commands = commandQueue.makeCommandBuffer() else { return }
        let target = view.drawableSize
        var image = CIImage(cvPixelBuffer: buffer)
        // Aspect-fill, exactly like the preview layer underneath.
        let scale = max(target.width / image.extent.width, target.height / image.extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        image = image.transformed(by: CGAffineTransform(translationX: (target.width - image.extent.width) / 2 - image.extent.minX,
                                                        y: (target.height - image.extent.height) / 2 - image.extent.minY))
        image = processor.render(recipe, to: image.cropped(to: CGRect(origin: .zero, size: target)))
        context.render(image, to: drawable.texture, commandBuffer: commands,
                       bounds: CGRect(origin: .zero, size: target), colorSpace: CGColorSpaceCreateDeviceRGB())
        commands.present(drawable)
        commands.commit()
    }
}
