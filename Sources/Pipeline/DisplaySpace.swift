import CoreImage

extension CIImage {
    /// Runs `transform` on the sRGB-gamma-encoded version of the image and
    /// converts the result back to the linear working space.
    ///
    /// Core Image's built-in curve filters interpolate whatever values they
    /// are handed — which, in the working space, are linear. A curve the user
    /// drew against a display-referred UI must interpolate display values, so
    /// display-referred built-ins get sandwiched in these two conversions.
    /// (PV2's own Metal kernels do this encode/decode internally instead.)
    func inDisplaySpace(_ transform: (CIImage) -> CIImage) -> CIImage {
        let encoded = applyingFilter("CILinearToSRGBToneCurve")
        return transform(encoded).applyingFilter("CISRGBToneCurveToLinear")
    }
}
