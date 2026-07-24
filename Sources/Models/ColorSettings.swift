import CoreGraphics
import Foundation

/// The eight hue bands the color mixer works in — the same split Lightroom
/// uses, which is finer in the warm range because that's where skin tones and
/// most memory colors live.
enum HueBand: String, Codable, CaseIterable, Identifiable {
    case red, orange, yellow, green, aqua, blue, purple, magenta

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }

    /// The band's center hue in degrees.
    var centerHue: Double {
        switch self {
        case .red: 0
        case .orange: 30
        case .yellow: 60
        case .green: 120
        case .aqua: 180
        case .blue: 240
        case .purple: 280
        case .magenta: 320
        }
    }
}

/// A per-band hue / saturation / luminance adjustment.
struct HSLAdjustment: Codable, Equatable {
    /// Hue rotation, `-100...100`, mapped to roughly ±30°.
    var hue: Double = 0
    /// Saturation change, `-100...100`.
    var saturation: Double = 0
    /// Luminance change, `-100...100`.
    var luminance: Double = 0

    var isNeutral: Bool { hue == 0 && saturation == 0 && luminance == 0 }

    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hue = c.lenient(.hue, 0)
        saturation = c.lenient(.saturation, 0)
        luminance = c.lenient(.luminance, 0)
    }
}

/// Whether the photo renders in color or black and white.
enum Treatment: String, Codable, CaseIterable, Identifiable {
    case color, blackAndWhite

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .color: "Color"
        case .blackAndWhite: "Black & White"
        }
    }
}

/// The color mixer: per-hue-band HSL, plus the black-and-white channel mix.
struct ColorMixer: Codable, Equatable {
    /// One adjustment per ``HueBand``, in `HueBand.allCases` order.
    var bands: [HSLAdjustment] = Array(repeating: HSLAdjustment(),
                                       count: HueBand.allCases.count)

    /// Per-band weights for black-and-white conversion, `-100...100`. This is
    /// the digital equivalent of shooting through a colored filter: pushing
    /// the red band up is a red filter darkening skies.
    var blackAndWhiteMix: [Double] = Array(repeating: 0,
                                           count: HueBand.allCases.count)

    subscript(band: HueBand) -> HSLAdjustment {
        get { bands[indexOf(band)] }
        set { bands[indexOf(band)] = newValue }
    }

    func blackAndWhiteWeight(_ band: HueBand) -> Double {
        blackAndWhiteMix[indexOf(band)]
    }

    mutating func setBlackAndWhiteWeight(_ value: Double, for band: HueBand) {
        blackAndWhiteMix[indexOf(band)] = value
    }

    var isNeutral: Bool {
        bands.allSatisfy(\.isNeutral) && blackAndWhiteMix.allSatisfy { $0 == 0 }
    }

    private func indexOf(_ band: HueBand) -> Int {
        HueBand.allCases.firstIndex(of: band) ?? 0
    }

    init() {}

    /// Decodes leniently, and pads or trims the arrays to the expected band
    /// count so a stack written when the band list differed can't crash the
    /// renderer with an out-of-range subscript.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let count = HueBand.allCases.count

        var decodedBands = c.lenient(.bands, [HSLAdjustment]())
        decodedBands = Array(decodedBands.prefix(count))
        while decodedBands.count < count { decodedBands.append(HSLAdjustment()) }
        bands = decodedBands

        var decodedMix = c.lenient(.blackAndWhiteMix, [Double]())
        decodedMix = Array(decodedMix.prefix(count))
        while decodedMix.count < count { decodedMix.append(0) }
        blackAndWhiteMix = decodedMix
    }
}

/// One tonal zone of the three-way color grade.
struct ColorGradeZone: Codable, Equatable {
    /// The tint hue in degrees, `0...360`.
    var hue: Double = 0
    /// Tint strength, `0...100`. Zero means no tint regardless of hue.
    var saturation: Double = 0
    /// Brightness offset for this zone, `-100...100`.
    var luminance: Double = 0

    var isNeutral: Bool { saturation == 0 && luminance == 0 }

    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hue = c.lenient(.hue, 0)
        saturation = c.lenient(.saturation, 0)
        luminance = c.lenient(.luminance, 0)
    }
}

/// Three-way color grading: separate tints for shadows, midtones, and
/// highlights — split toning generalized to the whole tonal range.
struct ColorGrading: Codable, Equatable {
    var shadows = ColorGradeZone()
    var midtones = ColorGradeZone()
    var highlights = ColorGradeZone()

    /// How far the zones bleed into each other, `0...100`. Higher blending
    /// means a softer handoff between shadow and highlight tints.
    var blending: Double = 50

    /// Shifts the shadow/highlight split point, `-100...100`. Negative widens
    /// the shadows, positive widens the highlights.
    var balance: Double = 0

    var isNeutral: Bool {
        shadows.isNeutral && midtones.isNeutral && highlights.isNeutral
    }

    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shadows = c.lenient(.shadows, ColorGradeZone())
        midtones = c.lenient(.midtones, ColorGradeZone())
        highlights = c.lenient(.highlights, ColorGradeZone())
        blending = c.lenient(.blending, 50)
        balance = c.lenient(.balance, 0)
    }
}

/// Per-channel tone curves, alongside the combined RGB curve.
struct ChannelCurves: Codable, Equatable {
    /// Control points in the unit square, sorted by ascending x. Empty means
    /// the identity curve.
    var red: [CGPoint] = []
    var green: [CGPoint] = []
    var blue: [CGPoint] = []

    var isNeutral: Bool { red.isEmpty && green.isEmpty && blue.isEmpty }

    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        red = c.lenient(.red, [])
        green = c.lenient(.green, [])
        blue = c.lenient(.blue, [])
    }
}

/// A targeted adjustment sampled from one colour on the photograph.
struct PointColorTarget: Codable, Equatable, Identifiable {
    var id = UUID()
    var red = 0.5
    var green = 0.5
    var blue = 0.5
    var hue = 0.0
    var saturation = 0.0
    var luminance = 0.0
    var range = 0.15
    var falloff = 0.10

    var isNeutral: Bool { hue == 0 && saturation == 0 && luminance == 0 }

    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, UUID())
        red = c.lenient(.red, 0.5)
        green = c.lenient(.green, 0.5)
        blue = c.lenient(.blue, 0.5)
        hue = c.lenient(.hue, 0)
        saturation = c.lenient(.saturation, 0)
        luminance = c.lenient(.luminance, 0)
        range = c.lenient(.range, 0.15)
        falloff = c.lenient(.falloff, 0.10)
    }
}

/// Primary hue/saturation calibration applied before the mixer.
struct ColorCalibration: Codable, Equatable {
    var redHue = 0.0
    var redSaturation = 0.0
    var greenHue = 0.0
    var greenSaturation = 0.0
    var blueHue = 0.0
    var blueSaturation = 0.0

    var isNeutral: Bool {
        redHue == 0 && redSaturation == 0 && greenHue == 0 && greenSaturation == 0
            && blueHue == 0 && blueSaturation == 0
    }

    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        redHue = c.lenient(.redHue, 0)
        redSaturation = c.lenient(.redSaturation, 0)
        greenHue = c.lenient(.greenHue, 0)
        greenSaturation = c.lenient(.greenSaturation, 0)
        blueHue = c.lenient(.blueHue, 0)
        blueSaturation = c.lenient(.blueSaturation, 0)
    }
}

/// Imported `.cube` look stored alongside custom film stocks.
struct CreativeLUT: Codable, Equatable {
    var name = "Imported LUT"
    var dimension = 32
    var cubeData = Data()
    var intensity: Double = 1.0

    var isNeutral: Bool { cubeData.isEmpty || intensity == 0 }

    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.lenient(.name, "Imported LUT")
        dimension = c.lenient(.dimension, 32)
        cubeData = c.lenient(.cubeData, Data())
        intensity = c.lenient(.intensity, 1.0)
    }
}

/// Everything the color LUT is built from, grouped so the renderer can cache
/// on a single `Equatable` value rather than comparing a dozen fields.
struct ColorSettings: Codable, Equatable {
    var treatment: Treatment = .color
    var calibration = ColorCalibration()
    var mixer = ColorMixer()
    var grading = ColorGrading()
    var channelCurves = ChannelCurves()
    var pointColors: [PointColorTarget] = []
    var creativeLUT = CreativeLUT()

    /// True when the LUT would be the identity and can be skipped entirely.
    var isNeutral: Bool {
        treatment == .color
            && calibration.isNeutral
            && mixer.isNeutral
            && grading.isNeutral
            && channelCurves.isNeutral
            && pointColors.allSatisfy(\.isNeutral)
            && creativeLUT.isNeutral
    }

    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        treatment = c.lenient(.treatment, Treatment.color)
        calibration = c.lenient(.calibration, ColorCalibration())
        mixer = c.lenient(.mixer, ColorMixer())
        grading = c.lenient(.grading, ColorGrading())
        channelCurves = c.lenient(.channelCurves, ChannelCurves())
        pointColors = c.lenient(.pointColors, [])
        creativeLUT = c.lenient(.creativeLUT, CreativeLUT())
    }
}
