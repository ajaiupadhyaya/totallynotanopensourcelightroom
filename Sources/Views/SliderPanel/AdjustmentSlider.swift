import AppKit
import SwiftUI

/// A labeled adjustment control: a coarse slider plus a scrubbable numeric
/// readout for precision.
///
/// ## Why the readout is draggable
///
/// A slider spanning `-100...100` in ~250 points gives about 0.8 units per
/// point — fine for finding a look, useless for landing on an exact value. So
/// the number itself is a scrub control: drag it horizontally to adjust, and
/// hold **⌥** for ten-times-finer steps.
///
/// ## Why precision is modifier-based, not velocity-based
///
/// The obvious alternative is velocity acceleration — small movements make
/// small changes, fast movements cover ground. It demos well, but it makes a
/// value hard to *return* to: the same gesture produces a different result
/// depending on how fast your hand moved, so nudging back to where you were
/// becomes trial and error. Modifier-scaled precision is predictable — a given
/// distance always means the same delta — which is what tools people work in
/// for hours converge on. The coarse slider already covers the "get there
/// fast" case.
struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var neutral: Double = 0

    /// Points of drag to traverse the whole range at normal speed.
    private let dragDistanceForFullRange = 260.0

    /// How much finer ⌥ makes the scrub.
    private let precisionFactor = 10.0

    @State private var valueAtDragStart: Double?
    @State private var isScrubbing = false

    private var isNeutral: Bool { value == neutral }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                Text(String(format: format, value))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(isNeutral && !isScrubbing
                                     ? AnyShapeStyle(.secondary)
                                     : AnyShapeStyle(.tint))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isScrubbing ? Theme.control : .clear)
                    )
                    .onHover { hovering in
                        // Signal that the number is a control, not just a label.
                        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(scrubGesture)
                    .accessibilityLabel("\(title) value")
                    .help("Drag to adjust · hold ⌥ for fine control · double-click to reset")
            }
            Slider(value: $value, in: range)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { value = neutral }
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                let start = valueAtDragStart ?? value
                if valueAtDragStart == nil {
                    valueAtDragStart = start
                    isScrubbing = true
                }

                // Modifier flags are read live, so ⌥ can be pressed or released
                // partway through a drag and take effect immediately.
                let isPrecise = NSEvent.modifierFlags.contains(.option)
                let span = range.upperBound - range.lowerBound
                let perPoint = span / dragDistanceForFullRange / (isPrecise ? precisionFactor : 1)

                let proposed = start + gesture.translation.width * perPoint
                value = min(max(proposed, range.lowerBound), range.upperBound)
            }
            .onEnded { _ in
                valueAtDragStart = nil
                isScrubbing = false
            }
    }
}
