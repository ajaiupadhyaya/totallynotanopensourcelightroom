import CoreImage
import CoreImage.CIFilterBuiltins

/// Folds a list of ``MaskComponent`` into one grayscale selection.
///
/// White is fully selected, black is untouched. Everything here stays lazy
/// `CIImage` graph-building — nothing rasterises, so the same graph serves a
/// small preview proxy and a full-resolution export.
///
/// Callers convert the result to alpha before `CIBlendWithMask`, which reads
/// alpha rather than luminance.
enum MaskCompositor {
    /// The composed selection, or nil when no component contributes.
    ///
    /// `source` is the image the generated components measure. Spatial
    /// components ignore it.
    static func composedMask(
        _ components: [MaskComponent], source: CIImage, extent: CGRect
    ) -> CIImage? {
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return nil }

        var result: CIImage?
        for component in components where component.isContributing {
            guard let piece = componentMask(component, source: source, extent: extent) else {
                continue
            }
            guard let current = result else {
                // The first contributing component seeds the selection whatever
                // its mode says. Intersecting or subtracting against nothing
                // would select nothing forever, which reads as a broken mask.
                result = piece
                continue
            }
            result = combine(current, piece, using: component.combine, extent: extent)
        }
        return result
    }

    // MARK: Set algebra

    private static func combine(
        _ base: CIImage, _ piece: CIImage,
        using mode: MaskComponent.Combine, extent: CGRect
    ) -> CIImage {
        switch mode {
        case .add:
            return composite(CIFilter.maximumCompositing(),
                             piece, over: base, extent: extent) ?? base
        case .intersect:
            return composite(CIFilter.multiplyCompositing(),
                             piece, over: base, extent: extent) ?? base
        case .subtract:
            // Multiply by the inverse rather than CISubtractBlendMode, so
            // partial coverage thins out smoothly instead of clipping to zero.
            return composite(CIFilter.multiplyCompositing(),
                             inverted(piece, extent: extent),
                             over: base, extent: extent) ?? base
        }
    }

    private static func composite(
        _ filter: CICompositeOperation,
        _ input: CIImage, over background: CIImage, extent: CGRect
    ) -> CIImage? {
        filter.inputImage = input
        filter.backgroundImage = background
        return filter.outputImage?.cropped(to: extent)
    }

    private static func inverted(_ image: CIImage, extent: CGRect) -> CIImage {
        let invert = CIFilter.colorInvert()
        invert.inputImage = image
        return invert.outputImage?.cropped(to: extent) ?? image
    }

    // MARK: One component

    private static func componentMask(
        _ component: MaskComponent, source: CIImage, extent: CGRect
    ) -> CIImage? {
        let raw: CIImage?
        switch component.shape {
        case .linear:
            raw = linearGradient(component, extent: extent)
        case .radial:
            raw = radialGradient(component, extent: extent)
        case .brush:
            raw = brushMask(component, extent: extent)
        case .luminance:
            raw = RangeMaskBuilder.luminanceMask(component, source: source, extent: extent)
        case .colorRange:
            raw = RangeMaskBuilder.colorRangeMask(component, source: source, extent: extent)
        }
        guard var mask = raw?.cropped(to: extent) else { return nil }

        mask = refined(mask, component.refine, extent: extent)
        if component.isInverted { mask = inverted(mask, extent: extent) }
        return mask
    }

    // MARK: Refinement

    /// Blur first, then grow/shrink, so the morphology works on a softened
    /// edge and produces a smooth spread rather than a stair-stepped one.
    private static func refined(
        _ mask: CIImage, _ refine: MaskRefinement, extent: CGRect
    ) -> CIImage {
        guard !refine.isNeutral else { return mask }
        let short = min(extent.width, extent.height)
        var result = mask

        if refine.blur > 0 {
            let blur = CIFilter.gaussianBlur()
            // Clamp first: blurring a cropped image pulls transparent black in
            // from beyond the edge and eats away at the selection's border.
            blur.inputImage = result.clampedToExtent()
            blur.radius = Float(max(refine.blur * 0.10 * short, 1))
            result = blur.outputImage?.cropped(to: extent) ?? result
        }

        if refine.shift != 0 {
            let radius = Float(max(abs(refine.shift) * 0.05 * short, 1))
            if refine.shift > 0 {
                let grow = CIFilter.morphologyMaximum()
                grow.inputImage = result.clampedToExtent()
                grow.radius = radius
                result = grow.outputImage?.cropped(to: extent) ?? result
            } else {
                let shrink = CIFilter.morphologyMinimum()
                shrink.inputImage = result.clampedToExtent()
                shrink.radius = radius
                result = shrink.outputImage?.cropped(to: extent) ?? result
            }
        }
        return result
    }

    // MARK: Spatial generators

    private static func linearGradient(
        _ component: MaskComponent, extent: CGRect
    ) -> CIImage? {
        let filter = CIFilter.smoothLinearGradient()
        filter.point0 = pixelPoint(component.startPoint, in: extent)
        filter.point1 = pixelPoint(component.endPoint, in: extent)
        filter.color0 = .white
        filter.color1 = .black
        return filter.outputImage
    }

    /// A circular gradient scaled anisotropically into the requested ellipse.
    private static func radialGradient(
        _ component: MaskComponent, extent: CGRect
    ) -> CIImage? {
        let radiusX = max(component.radiusX * extent.width, 1)
        let radiusY = max(component.radiusY * extent.height, 1)
        let reference = max(radiusX, radiusY)

        let feather = min(max(component.feather, 0), 1)
        // Keep at least half a pixel between the radii — CIRadialGradient with
        // radius0 == radius1 degenerates into a soft cone, not a hard edge.
        let inner = max(min(reference * (1 - feather), reference - 0.5), 0)

        let filter = CIFilter.radialGradient()
        filter.center = .zero
        filter.radius0 = Float(inner)
        filter.radius1 = Float(reference)
        filter.color0 = .white
        filter.color1 = .black
        guard let circle = filter.outputImage else { return nil }

        let center = pixelPoint(component.center, in: extent)
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .scaledBy(x: radiusX / reference, y: radiusY / reference)
        return circle.transformed(by: transform)
    }

    /// The maximum of soft radial dabs along each stroke. Points are
    /// interpolated so a fast pointer drag cannot leave holes.
    private static func brushMask(
        _ component: MaskComponent, extent: CGRect
    ) -> CIImage? {
        var result = CIImage(color: .black).cropped(to: extent)
        for stroke in component.brushStrokes where !stroke.points.isEmpty {
            let radius = max(stroke.radius * min(extent.width, extent.height), 1)
            let feather = min(max(stroke.feather, 0), 1)
            let inner = max(min(radius * (1 - feather), radius - 0.5), 0)
            let flow = CGFloat(min(max(stroke.flow, 0.02), 1))

            for point in interpolatedPoints(stroke.points,
                                            unitStep: max(stroke.radius * 0.45, 0.002)) {
                let dab = CIFilter.radialGradient()
                dab.center = pixelPoint(point, in: extent)
                dab.radius0 = Float(inner)
                dab.radius1 = Float(radius)
                dab.color0 = CIColor(red: flow, green: flow, blue: flow, alpha: 1)
                dab.color1 = .black
                guard let image = dab.outputImage?.cropped(to: extent) else { continue }
                result = composite(CIFilter.maximumCompositing(),
                                   image, over: result, extent: extent) ?? result
            }
        }
        return result
    }

    private static func interpolatedPoints(
        _ points: [CGPoint], unitStep: Double
    ) -> [CGPoint] {
        guard var previous = points.first else { return [] }
        var output = [previous]
        for point in points.dropFirst() {
            let distance = hypot(point.x - previous.x, point.y - previous.y)
            let segments = max(Int(ceil(distance / unitStep)), 1)
            for index in 1...segments {
                let t = CGFloat(index) / CGFloat(segments)
                output.append(CGPoint(
                    x: previous.x + (point.x - previous.x) * t,
                    y: previous.y + (point.y - previous.y) * t
                ))
            }
            previous = point
        }
        return output
    }

    static func pixelPoint(_ unit: CGPoint, in extent: CGRect) -> CGPoint {
        CGPoint(
            x: extent.origin.x + unit.x * extent.width,
            y: extent.origin.y + unit.y * extent.height
        )
    }
}

/// Draws a selection on top of the preview so a generated mask can be tuned.
///
/// A luminance band is invisible on the photograph itself — you can only judge
/// it by seeing the selection — so this is required for the feature to be
/// usable, not a convenience. It is a viewing aid and never touches export.
enum MaskOverlay {
    static func tinted(_ image: CIImage, mask: CIImage, extent: CGRect) -> CIImage {
        let red = CIImage(color: CIColor(red: 0.85, green: 0.12, blue: 0.15))
            .cropped(to: extent)

        // Half-strength so the photograph stays readable underneath.
        let damped = CIFilter.colorMatrix()
        damped.inputImage = mask
        damped.rVector = CIVector(x: 0.55, y: 0, z: 0, w: 0)
        damped.gVector = CIVector(x: 0, y: 0.55, z: 0, w: 0)
        damped.bVector = CIVector(x: 0, y: 0, z: 0.55, w: 0)
        damped.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let scaled = damped.outputImage?.cropped(to: extent) else { return image }

        let toAlpha = CIFilter.maskToAlpha()
        toAlpha.inputImage = scaled
        guard let alpha = toAlpha.outputImage else { return image }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = red
        blend.backgroundImage = image
        blend.maskImage = alpha
        return blend.outputImage?.cropped(to: extent) ?? image
    }
}
