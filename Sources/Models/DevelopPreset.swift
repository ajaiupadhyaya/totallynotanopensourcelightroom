import Foundation
import GRDB

/// A saved edit stack that can be applied to other photos.
///
/// The whole stack is stored, but applying it is selective (see
/// ``EditStack/applying(_:options:)``) — pasting a look onto another frame
/// should not also paste that frame's crop or its film base, which are
/// properties of the individual photo rather than of the look.
struct DevelopPreset: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "developPreset"

    var id: String
    var name: String

    /// Free-form grouping, e.g. "Portra roll 2026-07".
    var group: String

    var dateCreated: Date
    var editStack: EditStack

    init(
        id: String = UUID().uuidString,
        name: String,
        group: String = "User Presets",
        dateCreated: Date = Date(),
        editStack: EditStack
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.dateCreated = dateCreated
        self.editStack = editStack
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        group = c.lenient(.group, "User Presets")
        dateCreated = c.lenient(.dateCreated, Date())
        editStack = c.lenient(.editStack, EditStack())
    }
}

extension DevelopPreset {
    /// The group column parsed as a folder path: "Portra/Warm" nests Warm
    /// under Portra. Pure presentation — the catalog schema is untouched.
    var folderPath: [String] {
        let parts = group.split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? ["User Presets"] : parts
    }
}

/// Which parts of an edit stack to carry over when applying a preset or
/// pasting settings.
///
/// The defaults exclude crop and the film base on purpose. Both are properties
/// of an individual frame rather than of a look: every negative on a roll needs
/// its own base sample and its own framing, so copying a look across the roll
/// must not overwrite them. Everything else is what people actually mean by
/// "make these look the same."
struct EditTransferOptions: Equatable {
    var light = true
    var whiteBalance = true
    var presence = true
    var colorMixer = true
    var colorGrading = true
    var toneCurve = true
    var detail = true
    var effects = true

    /// Film stock character (contrast/saturation/gains) — but never the base
    /// color, which is measured per scan.
    var filmCharacter = true

    /// Off by default: the crop belongs to the individual frame.
    var geometry = false

    /// Off by default: the base is measured from *this* scan.
    var filmBase = false

    /// Everything, including the per-frame settings. Used by "paste all".
    static var everything: EditTransferOptions {
        var options = EditTransferOptions()
        options.geometry = true
        options.filmBase = true
        return options
    }
}

extension EditStack {
    /// `self` moved `amount` of the way toward `target`: every `Double` in
    /// the stack lerps; everything discrete (treatments, point lists, LUT
    /// data, spot arrays) takes `target`'s value whole for any amount > 0 —
    /// half a curve point list is not a meaningful object. Callers produce
    /// `target` via `applying(_:options:)`, so the per-frame exclusions
    /// (crop, film base) are already respected before interpolation.
    func interpolated(toward target: EditStack, amount: Double) -> EditStack {
        let t = min(max(amount, 0), 1)
        if t <= 0 { return self }
        if t >= 1 { return target }
        var result = target
        func lerp(_ path: WritableKeyPath<EditStack, Double>) {
            result[keyPath: path] = self[keyPath: path]
                + (target[keyPath: path] - self[keyPath: path]) * t
        }
        // Light, WB, presence, detail, effects, parametric curve — the same
        // field inventory ControlConformanceTests walks; keep the two lists
        // in sight of each other when adding a slider.
        for path: WritableKeyPath<EditStack, Double> in [
            \.exposure, \.contrast, \.highlights, \.shadows, \.whites, \.blacks,
            \.whiteBalanceTemp, \.whiteBalanceTint,
            \.texture, \.clarity, \.dehaze, \.vibrance, \.saturation,
            \.sharpenAmount, \.sharpenRadius, \.luminanceNoiseReduction, \.colorNoiseReduction,
            \.vignetteAmount, \.vignetteMidpoint, \.vignetteRoundness,
            \.vignetteFeather, \.vignetteHighlights, \.grainAmount, \.grainSize,
            \.toneCurveHighlights, \.toneCurveLights, \.toneCurveDarks, \.toneCurveShadows,
        ] { lerp(path) }
        // Colour scalars: mixer bands, B&W mix, grading zones lerp per field.
        for (index, band) in target.color.mixer.bands.enumerated() {
            let mine = color.mixer.bands[index]
            result.color.mixer.bands[index].hue = mine.hue + (band.hue - mine.hue) * t
            result.color.mixer.bands[index].saturation =
                mine.saturation + (band.saturation - mine.saturation) * t
            result.color.mixer.bands[index].luminance =
                mine.luminance + (band.luminance - mine.luminance) * t
        }
        for index in target.color.mixer.blackAndWhiteMix.indices {
            let mine = color.mixer.blackAndWhiteMix[index]
            result.color.mixer.blackAndWhiteMix[index] =
                mine + (target.color.mixer.blackAndWhiteMix[index] - mine) * t
        }
        for path: WritableKeyPath<EditStack, ColorGradeZone> in [
            \.color.grading.shadows, \.color.grading.midtones,
            \.color.grading.highlights, \.color.grading.global,
        ] {
            let mine = self[keyPath: path]
            let theirs = target[keyPath: path]
            result[keyPath: path].saturation = mine.saturation
                + (theirs.saturation - mine.saturation) * t
            result[keyPath: path].luminance = mine.luminance
                + (theirs.luminance - mine.luminance) * t
        }
        return result
    }

    /// Returns this stack with the selected parts of `other` applied over it.
    func applying(_ other: EditStack, options: EditTransferOptions = .init()) -> EditStack {
        var result = self

        if options.light {
            result.exposure = other.exposure
            result.contrast = other.contrast
            result.highlights = other.highlights
            result.shadows = other.shadows
            result.whites = other.whites
            result.blacks = other.blacks
        }
        if options.whiteBalance {
            result.whiteBalanceTemp = other.whiteBalanceTemp
            result.whiteBalanceTint = other.whiteBalanceTint
        }
        if options.presence {
            result.texture = other.texture
            result.clarity = other.clarity
            result.dehaze = other.dehaze
            result.vibrance = other.vibrance
            result.saturation = other.saturation
        }
        if options.colorMixer {
            result.color.treatment = other.color.treatment
            result.color.mixer = other.color.mixer
        }
        if options.colorGrading {
            result.color.grading = other.color.grading
        }
        if options.toneCurve {
            result.toneCurvePoints = other.toneCurvePoints
            result.color.channelCurves = other.color.channelCurves
        }
        if options.detail {
            result.sharpenAmount = other.sharpenAmount
            result.sharpenRadius = other.sharpenRadius
            result.luminanceNoiseReduction = other.luminanceNoiseReduction
            result.colorNoiseReduction = other.colorNoiseReduction
        }
        if options.effects {
            result.vignetteAmount = other.vignetteAmount
            result.vignetteMidpoint = other.vignetteMidpoint
            result.grainAmount = other.grainAmount
            result.grainSize = other.grainSize
        }
        if options.geometry {
            result.geometry = other.geometry
        }
        if options.filmCharacter {
            result.filmNegative.isEnabled = other.filmNegative.isEnabled
            result.filmNegative.type = other.filmNegative.type
            result.filmNegative.stockID = other.filmNegative.stockID
            result.filmNegative.stockName = other.filmNegative.stockName
            result.filmNegative.channelGains = other.filmNegative.channelGains
            result.filmNegative.exposure = other.filmNegative.exposure
            result.filmNegative.stockContrast = other.filmNegative.stockContrast
            result.filmNegative.stockSaturation = other.filmNegative.stockSaturation
        }
        if options.filmBase {
            result.filmNegative.baseColor = other.filmNegative.baseColor
        }

        return result
    }
}
