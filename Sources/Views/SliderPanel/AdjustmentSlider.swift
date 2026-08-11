import AppKit
import SwiftUI

/// A labeled adjustment fader — the editor's fundamental control, drawn from
/// scratch rather than wrapping the platform slider.
///
/// ## Anatomy
///
/// One 20pt line: a fixed label column, then an inset groove, then the
/// numeric readout. A tick marks the neutral value; a lit bar runs from that
/// tick to the current value, so *what has been done to this photograph* is
/// visible as a length, the way a console fader shows its offset at a
/// glance. A machined thumb marks the position, and the readout doubles as a
/// precision scrub control. The fixed columns mean every groove in a panel
/// starts and ends on the same x — the delta bars scan as one instrument.
///
/// The delta bar is the point of the whole design. A conventional slider fills
/// from its left end, which says where the value sits on an abstract scale but
/// not what you changed. Filling from *neutral* means an untouched photograph
/// shows a column of bare grooves, and one glance down the panel says exactly
/// which stages have been touched and how hard.
///
/// ## Interaction
///
/// - **Drag the groove** sets the value absolutely — the thumb jumps to the
///   pointer, because hunting for a small handle is not work.
/// - **⌥ while dragging** switches to relative motion at 10× finer steps, read
///   live so precision can be entered and left mid-drag.
/// - **Drag the readout** scrubs relatively.
/// - **Double-click** anywhere on the row resets to neutral.
/// - **← →** nudge once the row has keyboard focus; **⇧** makes the step ten.
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
    @FocusState private var isFocused: Bool

    private var isNeutral: Bool { abs(value - neutral) < 1e-9 }
    private var isActive: Bool { isDraggingTrack || isScrubbing }

    /// The label column: fixed, so every groove in a panel starts on the
    /// same x and the delta bars read as a single aligned instrument — the
    /// design audit measured the old two-line anatomy at a 57pt row pitch,
    /// three sliders per screen; one 20pt line puts a whole panel in view,
    /// which is the density a working tool needs.
    private static let labelColumn: CGFloat = 96
    private static let readoutColumn: CGFloat = 58

    var body: some View {
        HStack(alignment: .center, spacing: Theme.space2) {
            Text(title)
                .font(Theme.controlLabel)
                .foregroundStyle(isNeutral ? Theme.text.opacity(0.82) : Theme.text)
                .lineLimit(1)
                .frame(width: Self.labelColumn, alignment: .leading)

            track

            // A reserved slot, not a conditional insert: the reset appearing
            // must never resize the groove.
            ZStack {
                if !isNeutral, isHovering || isFocused {
                    Button(action: reset) {
                        Icon(kind: .reset, size: 10)
                            .foregroundStyle(Theme.tertiaryText)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Reset \(title)")
                    .transition(.opacity)
                }
            }
            .frame(width: 14)

            readout
                .frame(minWidth: Self.readoutColumn, alignment: .trailing)
        }
        .frame(height: 20)
        .animation(Theme.quick, value: isHovering)
        .animation(Theme.quick, value: isNeutral)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { reset() }
        .onHover { isHovering = $0 }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { nudge(-1) }
        .onKeyPress(.rightArrow) { nudge(1) }
        .overlay(alignment: .leading) {
            // Keyboard focus has to be visible, and a ring around a wide row is
            // noisy — so focus reads as a lit edge on the row's leading side.
            if isFocused {
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 2)
                    .padding(.vertical, 1)
                    .offset(x: -Theme.space2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(String(format: format, value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(1)
            case .decrement: nudge(-1)
            @unknown default: break
            }
        }
    }

    private var readout: some View {
        Text(String(format: format, value))
            .font(Theme.valueFont)
            .monospacedDigit()
            .foregroundStyle(readoutColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(isScrubbing ? Theme.controlActive
                                      : (isHovering ? Theme.control.opacity(0.6) : .clear))
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                // Signal that the number is a control, not just a label.
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(scrubGesture)
            .help("Drag to adjust · hold ⌥ for fine control · double-click to reset")
            .accessibilityHidden(true)
    }

    private var readoutColor: Color {
        if isActive { return Theme.accent }
        if isNeutral { return Theme.tertiaryText }
        return Theme.text
    }

    // MARK: Track

    private var track: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let valueX = xPosition(of: value, in: width)
            let neutralX = xPosition(of: neutral, in: width)
            let midY = proxy.size.height / 2

            ZStack(alignment: .topLeading) {
                // The groove: inset, so it reads as cut into the panel.
                Capsule()
                    .fill(Theme.canvas.opacity(0.75))
                    .frame(width: max(width, 0), height: 3)
                    .overlay {
                        Capsule().strokeBorder(Theme.specular, lineWidth: Theme.hairline)
                    }
                    .offset(y: midY - 1.5)

                // Neutral tick, below the groove so the bar never hides it.
                Rectangle()
                    .fill(Theme.tertiaryText.opacity(0.9))
                    .frame(width: 1, height: 5)
                    .offset(x: neutralX - 0.5, y: midY + 4)

                // The delta bar: neutral → value. The visible record of the edit.
                Capsule()
                    .fill(isActive ? Theme.accent : Theme.secondaryText.opacity(0.85))
                    .frame(width: max(abs(valueX - neutralX), 0), height: 3)
                    .offset(x: min(valueX, neutralX), y: midY - 1.5)

                thumb
                    .offset(x: valueX - 3, y: midY - 7)
            }
            .frame(width: width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(trackGesture(width: width))
        }
        // Draws fine, but stays grabbable across a comfortable band.
        .frame(height: 18)
    }

    private var thumb: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(isActive ? Theme.accent : Theme.text)
            .frame(width: 6, height: 14)
            .overlay {
                RoundedRectangle(cornerRadius: 1.5)
                    .strokeBorder(Theme.canvas.opacity(0.55), lineWidth: Theme.hairline)
            }
            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            .scaleEffect(x: isHovering || isActive ? 1.2 : 1, anchor: .center)
            .animation(Theme.quick, value: isHovering)
            .animation(Theme.quick, value: isActive)
    }

    private func xPosition(of value: Double, in width: CGFloat) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0, width > 0 else { return 0 }
        let fraction = (value - range.lowerBound) / span
        return CGFloat(min(max(fraction, 0), 1)) * width
    }

    // MARK: Gestures

    private func trackGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                let span = range.upperBound - range.lowerBound
                guard span > 0, width > 0 else { return }
                isDraggingTrack = true
                isFocused = true

                // ⌥ is read live so precision can start or stop mid-drag.
                if NSEvent.modifierFlags.contains(.option) {
                    // Relative, 10× finer.
                    let lastX = lastTrackX ?? gesture.location.x
                    let delta = Double(gesture.location.x - lastX) / Double(width)
                        * span / precisionFactor
                    value = clamp(value + delta)
                } else {
                    // Absolute: the thumb goes where the pointer is.
                    let fraction = min(max(gesture.location.x / width, 0), 1)
                    value = clamp(range.lowerBound + Double(fraction) * span)
                }
                lastTrackX = gesture.location.x
            }
            .onEnded { _ in
                isDraggingTrack = false
                lastTrackX = nil
            }
    }

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

                value = clamp(start + gesture.translation.width * perPoint)
            }
            .onEnded { _ in
                valueAtDragStart = nil
                isScrubbing = false
            }
    }

    // MARK: Value helpers

    private func clamp(_ proposed: Double) -> Double {
        min(max(proposed, range.lowerBound), range.upperBound)
    }

    private func reset() {
        value = neutral
    }

    /// One arrow-key step; ⇧ makes it ten. Two hundred steps across the range
    /// puts a single press near the smallest change worth making on any of
    /// these sliders, from a six-stop exposure range to a 0–100 amount.
    @discardableResult
    private func nudge(_ direction: Double) -> KeyPress.Result {
        let span = range.upperBound - range.lowerBound
        let coarse = NSEvent.modifierFlags.contains(.shift)
        value = clamp(value + direction * span / 200 * (coarse ? 10 : 1))
        return .handled
    }
}
