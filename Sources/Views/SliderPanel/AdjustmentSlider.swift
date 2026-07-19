import AppKit
import SwiftUI

/// A labeled adjustment fader — the editor's fundamental control, drawn from
/// scratch rather than wrapping the platform slider.
///
/// ## Anatomy
///
/// A hairline baseline spans the row. A short tick marks the neutral value; a
/// quiet bar runs from the tick to the current value, so *what has been done
/// to this photo* is visible as a length, the way a console fader shows its
/// offset at a glance. A needle marks the current position. The numeric
/// readout doubles as a precision scrub control.
///
/// ## Interaction
///
/// - **Drag on the track** sets the value absolutely (jump to finger).
/// - **⌥ while dragging** switches to relative motion at 10× finer steps —
///   read live, so precision can be entered and left mid-drag.
/// - **Drag the readout** adjusts relatively (the original scrub gesture).
/// - **Double-click** anywhere resets to neutral.
///
/// ## Why precision is modifier-based, not velocity-based
///
/// Velocity acceleration demos well but makes a value hard to *return* to: the
/// same gesture lands differently depending on hand speed. Modifier-scaled
/// precision is reproducible — a given distance always means the same delta —
/// which is what tools people work in for hours converge on.
struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var neutral: Double = 0

    /// Points of readout-scrub travel to traverse the whole range.
    private let dragDistanceForFullRange = 260.0

    /// How much finer ⌥ makes either gesture.
    private let precisionFactor = 10.0

    @State private var valueAtDragStart: Double?
    @State private var isScrubbing = false
    @State private var isDraggingTrack = false
    @State private var lastTrackX: CGFloat?
    @State private var isHovering = false

    private var isNeutral: Bool { value == neutral }
    private var isActive: Bool { isDraggingTrack || isScrubbing }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(Theme.controlFont)
                    .foregroundStyle(Theme.text.opacity(0.92))
                Spacer()
                Text(String(format: format, value))
                    .font(Theme.valueFont)
                    .foregroundStyle(readoutStyle)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 2)
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

            track
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { value = neutral }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(String(format: format, value))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 100
            switch direction {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            @unknown default: break
            }
        }
    }

    private var readoutStyle: AnyShapeStyle {
        if isActive { return AnyShapeStyle(Theme.accent) }
        if isNeutral { return AnyShapeStyle(Theme.tertiaryText) }
        return AnyShapeStyle(Theme.text.opacity(0.9))
    }

    // MARK: Track

    private var track: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let valueX = xPosition(of: value, in: width)
            let neutralX = xPosition(of: neutral, in: width)

            ZStack(alignment: .leading) {
                // Baseline.
                Rectangle()
                    .fill(Theme.separator)
                    .frame(height: Theme.hairline)
                    .frame(maxHeight: .infinity, alignment: .center)

                // Neutral tick.
                Rectangle()
                    .fill(Theme.tertiaryText)
                    .frame(width: 1, height: 5)
                    .offset(x: neutralX - 0.5)
                    .frame(maxHeight: .infinity, alignment: .center)

                // Delta bar: neutral → value. The visible record of the edit.
                Rectangle()
                    .fill(isActive ? Theme.accent : Theme.secondaryText.opacity(0.65))
                    .frame(width: abs(valueX - neutralX), height: 3)
                    .offset(x: min(valueX, neutralX))
                    .frame(maxHeight: .infinity, alignment: .center)

                // Needle.
                Rectangle()
                    .fill(isActive ? Theme.accent : (isHovering ? Theme.text : Theme.text.opacity(0.8)))
                    .frame(width: 1.5, height: 11)
                    .offset(x: valueX - 0.75)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .contentShape(Rectangle())
            .gesture(trackGesture(width: width))
        }
        .frame(height: 14)
    }

    private func xPosition(of value: Double, in width: CGFloat) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0, width > 0 else { return 0 }
        let fraction = (value - range.lowerBound) / span
        return CGFloat(min(max(fraction, 0), 1)) * width
    }

    private func trackGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                let span = range.upperBound - range.lowerBound
                guard span > 0, width > 0 else { return }
                isDraggingTrack = true

                // ⌥ is read live so precision can start or stop mid-drag.
                if NSEvent.modifierFlags.contains(.option) {
                    // Relative, 10× finer.
                    let lastX = lastTrackX ?? gesture.location.x
                    let delta = Double(gesture.location.x - lastX) / Double(width)
                        * span / precisionFactor
                    value = min(max(value + delta, range.lowerBound), range.upperBound)
                } else {
                    // Absolute: the needle goes where the pointer is.
                    let fraction = min(max(gesture.location.x / width, 0), 1)
                    value = range.lowerBound + Double(fraction) * span
                }
                lastTrackX = gesture.location.x
            }
            .onEnded { _ in
                isDraggingTrack = false
                lastTrackX = nil
            }
    }

    // MARK: Readout scrub

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                let start = valueAtDragStart ?? value
                if valueAtDragStart == nil {
                    valueAtDragStart = start
                    isScrubbing = true
                }

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
