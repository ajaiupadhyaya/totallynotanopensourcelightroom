import CoreImage

/// Where the pixels came from — and therefore which domain edits can reach.
///
/// A `.raw` source keeps its `CIRAWFilter` alive so white balance, exposure,
/// and the baseline boost apply to *sensor data* before demosaic rendering,
/// the way a raw editor is supposed to work. A `.rendered` source (JPEG,
/// HEIC, TIFF, PNG) is already display-referred; its scene-domain edits run
/// on linearized pixels instead.
enum SourceImage {
    case raw(CIRAWFilter)
    case rendered(CIImage)

    /// The image at the filter's current settings (raw) or the image itself.
    var image: CIImage {
        switch self {
        case .raw(let filter): return filter.outputImage ?? CIImage.empty()
        case .rendered(let image): return image
        }
    }

    var extent: CGRect { image.extent }
}

/// The stack fields that live in the RAW sensor domain, as a pure value —
/// separable from CIRAWFilter so the mapping is unit-testable without a
/// camera file.
struct RawDevelopSettings: Equatable {
    let temperature: Double
    let tint: Double
    let exposure: Double
    let boost: Double

    init(stack: EditStack) {
        temperature = stack.whiteBalanceTemp
        tint = stack.whiteBalanceTint
        exposure = stack.exposure
        boost = stack.rawBoost / 100
    }

    func configure(_ filter: CIRAWFilter) {
        filter.neutralTemperature = Float(temperature)
        filter.neutralTint = Float(tint)
        filter.exposure = Float(exposure)
        filter.boostAmount = Float(boost)
    }
}
