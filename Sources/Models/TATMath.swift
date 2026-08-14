import CoreGraphics

/// The Targeted Adjustment Tool's weighting: pure functions from a sampled
/// colour and a vertical drag to field values. All taste constants live here.
enum TATMath {
    /// Vertical drag distance (points) that sweeps a control's full range —
    /// the same order as AdjustmentSlider's readout scrub (260).
    static let pointsForFullSweep = 300.0

    /// The mixer sliders' span (−100…100).
    private static let mixerSpan = 200.0

    /// The LUT's own near-grey ramp (`smoothstep(saturation / 0.2)`,
    /// `ColorCubeBuilder.applyMixer`) — mirrored so the TAT refuses to move
    /// bands for a colour the LUT would barely touch.
    static func strength(forSaturation s: Double) -> Double {
        let t = min(max(s / 0.2, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// One curve tick: seed, find-or-add the point at the sampled luminance,
    /// lift it by the drag. `existingIndex` is the anchor from the first tick,
    /// so the whole gesture drags one point.
    static func curveEdit(points: [CGPoint], luma: Double, existingIndex: Int?,
                          deltaPoints: Double) -> (points: [CGPoint], index: Int) {
        var seeded = CurvePointModel.seeded(points)
        let index: Int
        if let existingIndex, seeded.indices.contains(existingIndex) {
            index = existingIndex
        } else {
            let y = ColorScience.evaluateCurve(seeded, at: luma)
            (seeded, index) = CurvePointModel.adding(CGPoint(x: luma, y: y), to: seeded)
        }
        let anchor = seeded[index]
        let lifted = CGPoint(x: anchor.x,
                             y: anchor.y + deltaPoints / pointsForFullSweep)
        return (CurvePointModel.moving(index: index, to: lifted, in: seeded), index)
    }

    /// One mixer tick: the drag lands on every band in proportion to the
    /// LUT's own weights for the sampled hue, gated by the near-grey ramp.
    static func mixerEdit(_ mixer: ColorMixer, hue: Double, saturation: Double,
                          field: WritableKeyPath<HSLAdjustment, Double>,
                          deltaPoints: Double) -> ColorMixer {
        var result = mixer
        let weights = ColorCubeBuilder.bandWeights(for: hue)
        let delta = deltaPoints / pointsForFullSweep * mixerSpan * strength(forSaturation: saturation)
        for (index, band) in HueBand.allCases.enumerated() where weights[index] > 0 {
            let moved = result[band][keyPath: field] + delta * weights[index]
            result[band][keyPath: field] = min(max(moved, -100), 100)
        }
        return result
    }

    /// The B&W variant: same weighting, writes the channel mix instead —
    /// dragging the sky darker is exactly "more red filter".
    static func blackAndWhiteEdit(_ mixer: ColorMixer, hue: Double, saturation: Double,
                                  deltaPoints: Double) -> ColorMixer {
        var result = mixer
        let weights = ColorCubeBuilder.bandWeights(for: hue)
        let delta = deltaPoints / pointsForFullSweep * mixerSpan * strength(forSaturation: saturation)
        for (index, band) in HueBand.allCases.enumerated() where weights[index] > 0 {
            let moved = result.blackAndWhiteWeight(band) + delta * weights[index]
            result.setBlackAndWhiteWeight(min(max(moved, -100), 100), for: band)
        }
        return result
    }
}
