import AppKit
import CoreImage
import MetalKit
import QuartzCore
import SwiftUI

/// Metal-backed canvas that renders a `CIImage` graph directly — no CGImage round-trip.
struct MetalCanvasView: NSViewRepresentable {
    let image: CIImage?
    let context: CIContext

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.colorPixelFormat = .rgba16Float
        view.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
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
        nsView.setNeedsDisplay(nsView.bounds)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var image: CIImage?
        private var ciContext: CIContext?
        private weak var view: MTKView?

        func configure(view: MTKView, ciContext: CIContext) {
            self.view = view
            self.ciContext = ciContext
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let image, let ciContext,
                  let drawable = view.currentDrawable,
                  let commandBuffer = view.device?.makeCommandQueue()?.makeCommandBuffer()
            else { return }

            let destination = CIRenderDestination(
                width: Int(view.drawableSize.width),
                height: Int(view.drawableSize.height),
                pixelFormat: view.colorPixelFormat,
                commandBuffer: commandBuffer,
                mtlTextureProvider: { drawable.texture }
            )
            destination.colorSpace = view.colorspace
            destination.isFlipped = false

            let scaleX = view.drawableSize.width / image.extent.width
            let scaleY = view.drawableSize.height / image.extent.height
            let scale = min(scaleX, scaleY)
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let x = (view.drawableSize.width - scaled.extent.width) / 2
            let y = (view.drawableSize.height - scaled.extent.height) / 2
            let placed = scaled.transformed(by: CGAffineTransform(translationX: x, y: y))

            do {
                try ciContext.startTask(toRender: placed, to: destination)
                commandBuffer.present(drawable)
                commandBuffer.commit()
            } catch {
                commandBuffer.commit()
            }
        }
    }
}
