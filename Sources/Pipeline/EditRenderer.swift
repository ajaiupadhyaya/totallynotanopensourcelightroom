import CoreImage
import CoreImage.CIFilterBuiltins

/// Turns an ``EditStack`` into a rendered image by replaying it as a Core Image
/// filter chain against an untouched source `CIImage`.
///
/// The design keeps the edit math separate from rasterization:
/// - ``render(source:stack:)`` is pure — it assembles the (lazy) filter chain
///   and returns a `CIImage`, doing no pixel work. This is what makes the edit
///   logic straightforward to unit test.
/// - ``renderCGImage(source:stack:)`` rasterizes that chain to a `CGImage` for
///   on-screen display via a shared, GPU-backed `CIContext`.
struct EditRenderer {
    /// Shared context; GPU-backed (Metal) by default. Reused across renders so
    /// we don't pay context-setup cost on every slider tick.
    let context: CIContext

    init(context: CIContext = CIContext()) {
        self.context = context
    }

    /// Builds the edit filter chain. No rasterization happens here — filters
    /// that would leave the image unchanged (value of `0`) are skipped so the
    /// identity edit returns the source untouched.
    func render(source: CIImage, stack: EditStack) -> CIImage {
        var image = source

        if stack.exposure != 0 {
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = image
            exposure.ev = Float(stack.exposure)
            image = exposure.outputImage ?? image
        }

        if stack.contrast != 0 {
            let controls = CIFilter.colorControls()
            controls.inputImage = image
            // Map the -100...100 slider onto Core Image's contrast multiplier,
            // where 1.0 is no change. So -100 -> 0.0, 0 -> 1.0, +100 -> 2.0.
            controls.contrast = Float(1.0 + stack.contrast / 100.0)
            image = controls.outputImage ?? image
        }

        return image
    }

    /// Rasterizes the edited image to a `CGImage` for display.
    ///
    /// - Returns: `nil` if the source has an infinite extent (e.g. a bare
    ///   generator image) or Core Image fails to produce a bitmap.
    func renderCGImage(source: CIImage, stack: EditStack) -> CGImage? {
        let output = render(source: source, stack: stack)
        guard !output.extent.isInfinite else { return nil }
        return context.createCGImage(output, from: output.extent)
    }
}
