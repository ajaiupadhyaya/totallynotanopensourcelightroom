import CoreImage
import CoreImage.CIFilterBuiltins

/// Highlights the parts of an image that are in critical focus.
///
/// Judging focus by eye means zooming to 100% and panning around — which is
/// slow, and on a scanned negative or a long lens it is easy to be wrong. Focus
/// peaking answers the question directly: run a high-pass over the luminance,
/// threshold it, and tint what survives. Sharp edges carry high spatial
/// frequency; soft ones don't.
///
/// This is a fixed convolution, not a detector — it has no idea what a face or
/// an eye is, and it will happily peak on sensor noise or film grain in a flat
/// area. Raising ``threshold`` is the cure for that.
enum FocusPeaking {
    /// Overlays a peaking tint on the image.
    ///
    /// - Parameters:
    ///   - threshold: Edge strength that counts as "in focus", `0...1`. Higher
    ///     is stricter and rejects more grain.
    ///   - tint: Overlay color. Green by default — it sits far from most scene
    ///     content, so it reads clearly without being mistaken for the photo.
    static func overlay(
        on image: CIImage,
        threshold: Double = 0.12,
        tint: CIColor = CIColor(red: 0.2, green: 1.0, blue: 0.3)
    ) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, extent.width >= 3, extent.height >= 3 else { return image }

        // Work on luminance only: a color edge with no luminance step isn't
        // what "sharp" means to the eye, and including chroma makes the
        // overlay fire on flat color boundaries.
        let mono = CIFilter.colorControls()
        mono.inputImage = image
        mono.saturation = 0
        guard let gray = mono.outputImage else { return image }

        // Edge detection via the difference between the image and a slight
        // blur — a high-pass. CIEdges is an alternative but is more sensitive
        // to noise at the scales that matter here.
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = gray.clampedToExtent()
        blur.radius = 1.2
        guard let blurred = blur.outputImage?.cropped(to: extent) else { return image }

        let difference = CIFilter.differenceBlendMode()
        difference.inputImage = gray
        difference.backgroundImage = blurred
        guard let edges = difference.outputImage else { return image }

        // Subtract the threshold, then amplify hard so the overlay reads as
        // binary rather than a vague glow.
        //
        // This has to be an affine gain anchored at zero, not `CIColorControls`
        // contrast: that pivots around 0.5, so an edge signal of ~0.3 gets
        // pushed *below* zero and the mask comes out empty. Edge strength lives
        // near the bottom of the range, so the transform has to be built for
        // that end.
        let gain = 6.0
        let amplified = CIFilter.colorMatrix()
        amplified.inputImage = edges
        amplified.rVector = CIVector(x: gain, y: 0, z: 0, w: 0)
        amplified.gVector = CIVector(x: 0, y: gain, z: 0, w: 0)
        amplified.bVector = CIVector(x: 0, y: 0, z: gain, w: 0)
        amplified.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let offset = -threshold * gain
        amplified.biasVector = CIVector(x: offset, y: offset, z: offset, w: 0)
        guard let boosted = amplified.outputImage else { return image }

        let mask = CIFilter.colorClamp()
        mask.inputImage = boosted
        mask.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        mask.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        guard let clamped = mask.outputImage else { return image }

        // CIBlendWithMask reads the mask's *alpha*, and everything produced
        // above is fully opaque — so the mask has to be converted from
        // brightness to alpha first. Passing the opaque mask straight in tints
        // the entire frame rather than just the edges.
        let alphaMask = CIFilter.maskToAlpha()
        alphaMask.inputImage = clamped
        guard let mask = alphaMask.outputImage else { return image }

        // Tint the mask and lay it over the photo.
        let solid = CIImage(color: tint).cropped(to: extent)
        let tinted = CIFilter.blendWithMask()
        tinted.inputImage = solid
        tinted.backgroundImage = image
        tinted.maskImage = mask
        return tinted.outputImage?.cropped(to: extent) ?? image
    }
}
