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

/// How a RAW file is *decoded*, frozen per process version.
///
/// The decode is part of the look, not a detail below it. A PV1 photo was
/// edited against Apple's baseline RAW rendering — gamut mapping on, no EDR
/// boost, and a full-size decode that the app downsampled afterwards — so
/// turning any of those knobs would change a finished edit, which is precisely
/// what the process version exists to prevent. PV2 turns all three around:
/// gamut mapping off so out-of-gamut colour reaches the sensor-domain chain,
/// EDR headroom on so highlights above 1.0 survive it, and previews decoded
/// straight to size through `CIRAWFilter.scaleFactor` (cheaper, and it keeps
/// the filter — not a downsampled snapshot — as the live source).
///
/// Pure and version-only, so the freeze is testable without a camera file.
struct RawDecodePolicy: Equatable {
    /// PV2 only: `CIRAWFilter.isGamutMappingEnabled = false`.
    let disablesGamutMapping: Bool
    /// PV2 only: `CIRAWFilter.extendedDynamicRangeAmount`. `nil` means "leave
    /// Apple's default alone".
    let edrAmount: Double?
    /// PV2 only: decode previews via `scaleFactor`. PV1 decodes full-size and
    /// downsamples the resulting `CIImage`, and so yields a `.rendered`
    /// source — its chain never reaches the filter anyway.
    let usesScaleFactorPreviews: Bool

    /// PV2 only: opt into Apple's RAW 9 decoder — the ML joint
    /// demosaic-and-denoise — WHEN this system and file support it. Strictly
    /// a runtime, per-file capability check at the apply site: setting an
    /// unsupported version yields a nil output image by Apple's own
    /// contract, so the check is correctness, not hygiene. PV1 stays at
    /// Apple's defaults forever (the frozen decode its photos were accepted
    /// under); on systems without RAW 9 the check simply never fires and
    /// nothing changes — the deployment floor stays macOS 14.
    let optsIntoRAW9: Bool

    init(processVersion: Int) {
        let isPV2 = processVersion >= 2
        disablesGamutMapping = isPV2
        edrAmount = isPV2 ? 1.0 : nil
        usesScaleFactorPreviews = isPV2
        optsIntoRAW9 = isPV2
    }
}

/// The stack fields that live in the RAW sensor domain, as a pure value —
/// separable from CIRAWFilter so the mapping is unit-testable without a
/// camera file.
///
/// `tint` is passed straight through to `CIRAWFilter.neutralTint`, whose
/// native units follow the camera-calibration convention (roughly
/// −150…150). A `.rendered` source's `whiteBalanceTint` is the *same*
/// `EditStack` field, but `WhiteBalanceStage` interprets it on
/// `ColorScience`'s own uv-offset scale instead — a different unit system
/// entirely. As-shot adoption (`EditorModel.adoptAsShotWhiteBalanceIfNeeded`)
/// round-trips exactly because it both reads and writes `neutralTint`
/// directly; the two domains' *sliders* are intentionally not
/// cross-calibrated to mean the same physical shift — a raw file's tint
/// slider drives the sensor-domain control natively, the way Lightroom's does.
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
