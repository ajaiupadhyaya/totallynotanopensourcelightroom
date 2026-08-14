import AppKit
import SwiftUI

/// The wheel's geometry, kept pure so the puck round-trip is provable.
/// Hue 0° sits at 3 o'clock and increases counter-clockwise (the colour-science
/// convention `hslToRGB` uses); view y grows downward, hence the sign flips.
enum ColorWheelMath {
    static func puckOffset(hue: Double, saturation: Double, radius: CGFloat) -> CGSize {
        let angle = hue * .pi / 180
        let r = radius * CGFloat(min(max(saturation / 100, 0), 1))
        return CGSize(width: cos(angle) * r, height: -sin(angle) * r)
    }

    static func value(atOffset offset: CGSize, radius: CGFloat) -> (hue: Double, saturation: Double) {
        let r = hypot(offset.width, offset.height)
        guard r > 0.5 else { return (0, 0) }
        let hue = ColorScience.wrapHue(Double(atan2(-offset.height, offset.width)) * 180 / .pi)
        return (hue, Double(min(r / radius, 1)) * 100)
    }
}

/// A drawn hue/saturation wheel for one grading zone. The interior is the one
/// place in this panel colour legitimately appears — it is data, a
/// colour-selection surface — ringed by the same hairline as every instrument.
/// ⌥-drag is 10× finer (read live, like AdjustmentSlider); double-click
/// resets the zone.
struct ColorWheel: View {
    @Binding var zone: ColorGradeZone
    var diameter: CGFloat = 132

    @State private var dragAnchor: CGSize?

    private var radius: CGFloat { diameter / 2 }

    var body: some View {
        ZStack {
            Circle()
                .fill(AngularGradient(
                    colors: stride(from: 0.0, through: 360.0, by: 30.0).map {
                        let rgb = ColorScience.hslToRGB(360 - $0, 0.8, 0.5)
                        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
                    },
                    center: .center))
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.5), .clear],
                                     center: .center, startRadius: 0, endRadius: radius))
            Circle()
                .strokeBorder(Theme.strongSeparator, lineWidth: Theme.hairline)

            // The puck: the mask-pin language, no colour of its own.
            Circle()
                .fill(Theme.text)
                .frame(width: 11, height: 11)
                .overlay { Circle().strokeBorder(Theme.canvas, lineWidth: 1.5) }
                .shadow(color: .black.opacity(0.6), radius: 2)
                .offset(ColorWheelMath.puckOffset(hue: zone.hue,
                                                  saturation: zone.saturation,
                                                  radius: radius))
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle().scale(1.1))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let centre = CGSize(width: value.location.x - radius,
                                        height: value.location.y - radius)
                    let anchor = dragAnchor ?? ColorWheelMath.puckOffset(
                        hue: zone.hue, saturation: zone.saturation, radius: radius)
                    if dragAnchor == nil { dragAnchor = anchor }
                    // ⌥ read live: relative from the puck at 10× finer.
                    let offset: CGSize
                    if NSEvent.modifierFlags.contains(.option) {
                        offset = CGSize(width: anchor.width + value.translation.width / 10,
                                        height: anchor.height + value.translation.height / 10)
                    } else {
                        offset = centre
                    }
                    let picked = ColorWheelMath.value(atOffset: offset, radius: radius)
                    zone.hue = picked.saturation > 0 ? picked.hue : zone.hue
                    zone.saturation = picked.saturation
                }
                .onEnded { _ in dragAnchor = nil }
        )
        .onTapGesture(count: 2) { zone = ColorGradeZone() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Colour wheel")
        .accessibilityValue(String(format: "hue %.0f°, saturation %.0f",
                                   zone.hue, zone.saturation))
    }
}
