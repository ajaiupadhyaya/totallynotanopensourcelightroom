import CoreImage
import CoreImage.CIFilterBuiltins

/// White balance for rendered (non-RAW) sources: a Bradford adaptation
/// matrix applied to linear working-space values via CIColorMatrix. RAW
/// sources never reach this stage — their WB happens in the sensor domain
/// (see RawDevelopSettings (SourceImage.swift)).
enum WhiteBalanceStage {
    static func apply(_ image: CIImage, temperature: Double, tint: Double) -> CIImage {
        guard temperature != 6500 || tint != 0 else { return image }
        let m = ColorScience.whiteBalanceMatrix(temperature: temperature, tint: tint)
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.rVector = CIVector(x: m[0], y: m[1], z: m[2], w: 0)
        filter.gVector = CIVector(x: m[3], y: m[4], z: m[5], w: 0)
        filter.bVector = CIVector(x: m[6], y: m[7], z: m[8], w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return filter.outputImage ?? image
    }
}
