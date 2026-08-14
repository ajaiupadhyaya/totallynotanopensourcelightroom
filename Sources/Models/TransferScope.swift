import Foundation

/// The numbered stages of the develop pipeline, as the develop column prints
/// them. One truth for three jobs: the panel spine's modified dot, the copy
/// dialog's checkboxes, and what a scoped copy actually carries.
///
/// The cases are in pipeline order, and `index` is the two-digit number the
/// panel shows — if a section is renumbered, it is renumbered here.
enum PipelineSection: String, CaseIterable, Identifiable, Hashable {
    case film, frame, optics, retouch
    case whiteBalance, light, presence
    case colorMixer, colorGrade, pointColor, toneCurve
    case masks, detail, effects

    var id: String { rawValue }

    var index: String {
        switch self {
        case .film: "01"
        case .frame: "02"
        case .optics: "03"
        case .retouch: "04"
        case .whiteBalance: "05"
        case .light: "06"
        case .presence: "07"
        case .colorMixer: "08"
        case .colorGrade: "09"
        case .pointColor: "10"
        case .toneCurve: "11"
        case .masks: "12"
        case .detail: "13"
        case .effects: "14"
        }
    }

    /// The panel's own title, verbatim — the dialog and the column must name
    /// the same thing the same way.
    var title: String {
        switch self {
        case .film: "Film"
        case .frame: "Frame"
        case .optics: "Optics"
        case .retouch: "Retouch"
        case .whiteBalance: "White Balance"
        case .light: "Light"
        case .presence: "Presence"
        case .colorMixer: "Color Mixer"
        case .colorGrade: "Color Grade"
        case .pointColor: "Point Color"
        case .toneCurve: "Tone Curve"
        case .masks: "Local Masks"
        case .detail: "Detail"
        case .effects: "Effects"
        }
    }

    /// Whether this section carries a non-neutral edit — the predicate behind
    /// the header dot, moved here from `SliderPanel` so the spine, the copy
    /// dialog and the Modified button can never disagree.
    func isModified(in stack: EditStack) -> Bool {
        switch self {
        case .film:
            stack.filmNegative != FilmNegativeSettings()
        case .frame:
            stack.geometry.cropRect != .unitFrame || stack.geometry.rotation != .none
                || stack.geometry.straightenAngle != 0
                || stack.geometry.flipHorizontal || stack.geometry.flipVertical
        case .optics:
            stack.geometry.distortion != 0 || stack.geometry.perspectiveVertical != 0
                || stack.geometry.perspectiveHorizontal != 0 || !stack.defringe.isNeutral
        case .retouch:
            !stack.retouch.isEmpty
        case .whiteBalance:
            stack.whiteBalanceTemp != 6500 || stack.whiteBalanceTint != 0
        case .light:
            stack.exposure != 0 || stack.contrast != 0 || stack.highlights != 0
                || stack.shadows != 0 || stack.whites != 0 || stack.blacks != 0
                || stack.rawBoost != 100
        case .presence:
            stack.texture != 0 || stack.clarity != 0 || stack.dehaze != 0
                || stack.vibrance != 0 || stack.saturation != 0
        case .colorMixer:
            stack.color.treatment != .color || !stack.color.mixer.isNeutral
        case .colorGrade:
            !stack.color.grading.isNeutral
        case .pointColor:
            !stack.color.pointColors.allSatisfy(\.isNeutral)
        case .toneCurve:
            !stack.toneCurvePoints.isEmpty || !stack.color.channelCurves.isNeutral
                || stack.toneCurveHighlights != 0 || stack.toneCurveLights != 0
                || stack.toneCurveDarks != 0 || stack.toneCurveShadows != 0
        case .masks:
            !stack.localAdjustments.isEmpty
        case .detail:
            stack.sharpenAmount != 0 || stack.sharpenRadius != 1.5
                || stack.luminanceNoiseReduction != 0 || stack.colorNoiseReduction != 0
        case .effects:
            stack.vignetteAmount != 0 || stack.vignetteMidpoint != 50
                || stack.vignetteRoundness != 0 || stack.vignetteFeather != 50
                || stack.vignetteHighlights != 0
                || stack.grainAmount != 0 || stack.grainSize != 25
        }
    }

    /// Copies every field this section's panel binds from `source` onto
    /// `target`. Completeness is the point: a section people ticked has to
    /// arrive whole, or the dialog is lying about what it carries.
    func copied(from source: EditStack, onto target: EditStack) -> EditStack {
        var result = target
        switch self {
        case .film:
            // The stock's character and the print look travel; the scan's own
            // measurements never do. `baseColor`/`isBaseSampled`/`baseOrigin`
            // are measured from THIS negative, `dmax`/`gamma`/`exposure`/
            // `gradePivot` are this scan's solve, and `renderVersion` is
            // engine provenance — copying it would thaw a frozen render.
            result.filmNegative.isEnabled = source.filmNegative.isEnabled
            result.filmNegative.type = source.filmNegative.type
            result.filmNegative.stockID = source.filmNegative.stockID
            result.filmNegative.stockName = source.filmNegative.stockName
            result.filmNegative.channelGains = source.filmNegative.channelGains
            result.filmNegative.exposure = source.filmNegative.exposure
            result.filmNegative.stockContrast = source.filmNegative.stockContrast
            result.filmNegative.stockSaturation = source.filmNegative.stockSaturation
            result.filmNegative.conversionModel = source.filmNegative.conversionModel
            result.filmNegative.print.contrast = source.filmNegative.print.contrast
            result.filmNegative.print.shoulder = source.filmNegative.print.shoulder
            result.filmNegative.print.toe = source.filmNegative.print.toe
            result.filmNegative.print.saturation = source.filmNegative.print.saturation
            result.filmNegative.print.warmth = source.filmNegative.print.warmth
            result.filmNegative.print.tint = source.filmNegative.print.tint
            result.filmNegative.print.toneProfile = source.filmNegative.print.toneProfile
            result.filmNegative.print.punch = source.filmNegative.print.punch
            result.filmNegative.print.fade = source.filmNegative.print.fade
            result.filmNegative.print.glow = source.filmNegative.print.glow
            result.filmNegative.print.toeChroma = source.filmNegative.print.toeChroma
            result.filmNegative.print.castRed = source.filmNegative.print.castRed
            result.filmNegative.print.castGreen = source.filmNegative.print.castGreen
            result.filmNegative.print.castBlue = source.filmNegative.print.castBlue
            result.filmNegative.print.shadowTrim = source.filmNegative.print.shadowTrim
            result.filmNegative.print.midTrim = source.filmNegative.print.midTrim
            result.filmNegative.print.highTrim = source.filmNegative.print.highTrim
        case .frame:
            result.geometry.cropRect = source.geometry.cropRect
            result.geometry.rotation = source.geometry.rotation
            result.geometry.straightenAngle = source.geometry.straightenAngle
            result.geometry.flipHorizontal = source.geometry.flipHorizontal
            result.geometry.flipVertical = source.geometry.flipVertical
        case .optics:
            result.geometry.distortion = source.geometry.distortion
            result.geometry.perspectiveVertical = source.geometry.perspectiveVertical
            result.geometry.perspectiveHorizontal = source.geometry.perspectiveHorizontal
            result.defringe = source.defringe
        case .retouch:
            result.retouch = source.retouch
        case .whiteBalance:
            result.whiteBalanceTemp = source.whiteBalanceTemp
            result.whiteBalanceTint = source.whiteBalanceTint
        case .light:
            result.exposure = source.exposure
            result.contrast = source.contrast
            result.highlights = source.highlights
            result.shadows = source.shadows
            result.whites = source.whites
            result.blacks = source.blacks
            result.rawBoost = source.rawBoost
        case .presence:
            result.texture = source.texture
            result.clarity = source.clarity
            result.dehaze = source.dehaze
            result.vibrance = source.vibrance
            result.saturation = source.saturation
        case .colorMixer:
            result.color.treatment = source.color.treatment
            result.color.mixer = source.color.mixer
            result.color.calibration = source.color.calibration
            result.color.creativeLUT = source.color.creativeLUT
        case .colorGrade:
            result.color.grading = source.color.grading
        case .pointColor:
            result.color.pointColors = source.color.pointColors
        case .toneCurve:
            result.toneCurvePoints = source.toneCurvePoints
            result.color.channelCurves = source.color.channelCurves
            result.toneCurveHighlights = source.toneCurveHighlights
            result.toneCurveLights = source.toneCurveLights
            result.toneCurveDarks = source.toneCurveDarks
            result.toneCurveShadows = source.toneCurveShadows
        case .masks:
            result.localAdjustments = source.localAdjustments
        case .detail:
            result.sharpenAmount = source.sharpenAmount
            result.sharpenRadius = source.sharpenRadius
            result.luminanceNoiseReduction = source.luminanceNoiseReduction
            result.colorNoiseReduction = source.colorNoiseReduction
        case .effects:
            result.vignetteAmount = source.vignetteAmount
            result.vignetteMidpoint = source.vignetteMidpoint
            result.vignetteRoundness = source.vignetteRoundness
            result.vignetteFeather = source.vignetteFeather
            result.vignetteHighlights = source.vignetteHighlights
            result.grainAmount = source.grainAmount
            result.grainSize = source.grainSize
        }
        return result
    }
}

/// Which pipeline sections a copy carries.
struct TransferScope: Equatable {
    var sections: Set<PipelineSection>

    static let all = TransferScope(sections: Set(PipelineSection.allCases))
    static let none = TransferScope(sections: [])

    /// The old default's spirit, stated in sections: everything except the
    /// per-frame ones — Frame (this photo's composition) and Retouch (this
    /// photo's dust).
    static let `default` = TransferScope(
        sections: Set(PipelineSection.allCases).subtracting([.frame, .retouch]))

    static func modified(in stack: EditStack) -> TransferScope {
        TransferScope(sections: Set(PipelineSection.allCases.filter { $0.isModified(in: stack) }))
    }
}

extension EditStack {
    func applying(_ other: EditStack, scope: TransferScope) -> EditStack {
        var result = self
        for section in PipelineSection.allCases where scope.sections.contains(section) {
            result = section.copied(from: other, onto: result)
        }
        return result
    }
}
