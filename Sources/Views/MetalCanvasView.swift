import AppKit
import CoreImage
import MetalKit
import QuartzCore
import SwiftUI

/// Metal-backed canvas that renders a `CIImage` graph straight to the screen —
/// no `CGImage` round-trip on the way.
///
/// ## The view is the viewport, not the photograph
///
/// The drawable is always the size of the visible canvas area, and the
/// photograph is *placed into* it by a transform. The obvious alternative — let
/// the view be as large as the zoomed image and put it in a scroll view — asks
/// Metal for a drawable as large as the photograph: at 100 % on a 60-megapixel
/// frame that is a multi-gigabyte texture for a picture of which the screen can
/// show maybe two per cent. Keeping the drawable the size of the window makes
/// the cost of zooming flat, and Core Image only pulls the source pixels the
/// visible region actually needs.
struct MetalCanvasView: NSViewRepresentable {
    let image: CIImage?
    let context: CIContext

    /// Where the photograph should land, in this view's own coordinates
    /// (points, origin top-left) — the same rect the overlays are positioned
    /// with, so handles and pixels can never disagree.
    let imageRect: CGRect

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.colorPixelFormat = .rgba16Float
        view.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.layer?.isOpaque = false
        if let layer = view.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
        }
        view.preferredFramesPerSecond = 120
        view.delegate = context.coordinator
        context.coordinator.configure(view: view, ciContext: self.context)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.image = image
        context.coordinator.imageRect = imageRect
        nsView.setNeedsDisplay(nsView.bounds)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MTKViewDelegate {
        var image: CIImage?
        var imageRect: CGRect = .zero
        private var ciContext: CIContext?
        private weak var view: MTKView?

        /// Created once and reused. A command queue is an expensive, long-lived
        /// object; building one per frame allocates a fresh queue on every
        /// slider tick and starves the GPU scheduler.
        private var commandQueue: MTLCommandQueue?

        func configure(view: MTKView, ciContext: CIContext) {
            self.view = view
            self.ciContext = ciContext
            self.commandQueue = view.device?.makeCommandQueue()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let image, let ciContext,
                  !image.extent.isInfinite, image.extent.width > 0, image.extent.height > 0,
                  view.drawableSize.width > 0, view.drawableSize.height > 0,
                  view.bounds.width > 0, view.bounds.height > 0,
                  let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue?.makeCommandBuffer()
            else { return }

            let destination = CIRenderDestination(
                width: Int(view.drawableSize.width),
                height: Int(view.drawableSize.height),
                pixelFormat: view.colorPixelFormat,
                commandBuffer: commandBuffer,
                mtlTextureProvider: { drawable.texture }
            )
            destination.colorSpace = view.colorspace
            // Core Image works bottom-left-up; the drawable is top-left-down.
            // Without this the photograph renders upside down.
            destination.isFlipped = true

            // Points → drawable pixels. Asking the view for the ratio rather
            // than the screen's backing scale keeps this correct while a window
            // is being dragged between displays of different densities.
            let pixelsPerPoint = view.drawableSize.width / view.bounds.width
            let target = imageRect.isEmpty
                ? CGRect(origin: .zero, size: view.drawableSize)
                : imageRect.applying(CGAffineTransform(scaleX: pixelsPerPoint, y: pixelsPerPoint))

            let placed = image.transformed(by: Self.placement(
                of: image.extent, into: target, drawableHeight: view.drawableSize.height
            ))

            do {
                // Only rasterize what the canvas can actually show. At high
                // zoom this is what keeps a full-resolution graph affordable:
                // Core Image resolves the region of interest backwards through
                // the chain and touches nothing else.
                let visible = placed.cropped(
                    to: CGRect(origin: .zero, size: view.drawableSize)
                )
                try ciContext.startTask(toRender: visible, to: destination)
                commandBuffer.present(drawable)
                commandBuffer.commit()
            } catch {
                commandBuffer.commit()
            }
        }

        /// The transform placing an image of `extent` into `target`.
        ///
        /// `target` is in drawable pixels with a **top-left** origin, matching
        /// the layout coordinates the rest of the canvas uses; the result is in
        /// Core Image's bottom-left space, which is the one conversion in the
        /// whole canvas and happens here, once.
        ///
        /// Normalizing the extent's origin first is what makes this correct for
        /// a graph that does not start at zero — a straightened or
        /// perspective-corrected frame. Scaling such an image directly scales
        /// its offset too, sliding the photograph off the canvas.
        static func placement(
            of extent: CGRect, into target: CGRect, drawableHeight: CGFloat
        ) -> CGAffineTransform {
            guard extent.width > 0, extent.height > 0,
                  target.width > 0, target.height > 0 else { return .identity }

            let scale = min(target.width / extent.width, target.height / extent.height)
            let toOrigin = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            let scaled = toOrigin.concatenating(CGAffineTransform(scaleX: scale, y: scale))

            // Centre within the target, then flip the target's y into CI space.
            let drawnWidth = extent.width * scale
            let drawnHeight = extent.height * scale
            let x = target.minX + (target.width - drawnWidth) / 2
            let topY = target.minY + (target.height - drawnHeight) / 2
            let ciY = drawableHeight - topY - drawnHeight

            return scaled.concatenating(CGAffineTransform(translationX: x, y: ciY))
        }
    }
}
