import Foundation

/// Closed-form cast correction (spec §Cast correction). Given the densities
/// of something that SHOULD render neutral — the eyedropper's patch, or the
/// per-channel medians for auto colour balance — solve the per-channel
/// density offsets that equalize the three straight-line log outputs at
/// their mean: τ = mean(L_c), L_c = γ_c·(D_c − Dmax_c), o_c = (τ − L_c)/γ_c.
/// Equalizing AT THE MEAN moves colour without moving exposure.
enum CastSolver {
    static func densityOffsets(neutralDensity d: DensityTriple,
                               gamma: DensityTriple,
                               dmax: DensityTriple) -> DensityTriple {
        let l = (gamma.red * (d.red - dmax.red),
                 gamma.green * (d.green - dmax.green),
                 gamma.blue * (d.blue - dmax.blue))
        let tau = (l.0 + l.1 + l.2) / 3
        func safe(_ g: Double) -> Double { abs(g) > 1e-6 ? g : 1 }
        return DensityTriple(red: (tau - l.0) / safe(gamma.red),
                             green: (tau - l.1) / safe(gamma.green),
                             blue: (tau - l.2) / safe(gamma.blue))
    }

    /// The same offsets in ±100 cast-slider units (`PaperResponse.castDensity`
    /// inverted), clamped to the slider range; `clipped` reports truncation.
    static func castSliders(neutralDensity: DensityTriple,
                            gamma: DensityTriple,
                            dmax: DensityTriple)
        -> (red: Double, green: Double, blue: Double, clipped: Bool) {
        let o = densityOffsets(neutralDensity: neutralDensity, gamma: gamma, dmax: dmax)
        let unit = PaperResponse.castFullScaleEV * log10(2.0) / 100.0
        let raw = (o.red / unit, o.green / unit, o.blue / unit)
        func clamp(_ v: Double) -> Double { min(max(v, -100), 100) }
        let clipped = raw.0 != clamp(raw.0) || raw.1 != clamp(raw.1) || raw.2 != clamp(raw.2)
        return (clamp(raw.0), clamp(raw.1), clamp(raw.2), clipped)
    }

    /// Warm/cool auto-balance biases in slider units — a gentle, documented
    /// push either side of neutral (±0.04 EV split red/blue), the NLP
    /// auto-warm/auto-cool idea sized to this engine's slider scale.
    static let warmBias = (red: 8.0, green: 0.0, blue: -8.0)
}
