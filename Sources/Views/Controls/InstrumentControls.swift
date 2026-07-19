import SwiftUI

// The drawn control kit. Nothing here wraps an AppKit control — every
// affordance is drawn, so the editor's chrome owes nothing to the host
// platform's widget set. Shared vocabulary:
//
// - **TabStrip** — a typographic segmented control: tracked caps, the active
//   segment carried by an accent underline rather than a filled capsule.
// - **PlateButton** — a hairline-bordered caps label, like an engraved plate;
//   pressing fills it, hovering brightens the border.
// - **LampToggle** — a square indicator lamp beside a caps label; the lamp
//   lights with the accent when on.
// - **Glyph** — the few pictographic marks the chrome needs (chevrons, plus,
//   cross, stars), drawn as paths at hairline weight.

// MARK: - TabStrip

/// A typographic segmented control.
struct TabStrip<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 14) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(option.label.uppercased())
                            .font(Theme.plateFont)
                            .kerning(Theme.plateTracking)
                            .lineLimit(1)
                            .foregroundStyle(isSelected ? Theme.text : Theme.tertiaryText)
                        Rectangle()
                            .fill(isSelected ? Theme.accent : .clear)
                            .frame(height: 2)
                    }
                    // Hug the label: an unconstrained Rectangle would expand
                    // each tab to fill all available width.
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }
}

// MARK: - PlateButton

/// A drawn button: caps label in a hairline plate.
struct PlateButton: View {
    let title: String
    var isEnabled: Bool = true
    var fillsWidth: Bool = false
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Text(title.uppercased())
            .font(Theme.plateFont)
            .kerning(Theme.plateTracking)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(isEnabled ? Theme.text.opacity(isHovering ? 1 : 0.85)
                                       : Theme.tertiaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .background(isPressed ? Theme.control : .clear)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(isEnabled && isHovering ? Theme.secondaryText : Theme.separator,
                            lineWidth: Theme.hairline)
            )
            .contentShape(Rectangle())
            .onHover { isHovering = isEnabled && $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if isEnabled { isPressed = true } }
                    .onEnded { gesture in
                        isPressed = false
                        guard isEnabled else { return }
                        // Only fire if the release happens over the button,
                        // matching real button behavior.
                        if abs(gesture.translation.width) < 24,
                           abs(gesture.translation.height) < 24 {
                            action()
                        }
                    }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(title)
    }
}

// MARK: - LampToggle

/// A drawn toggle: a small square lamp that lights with the accent.
struct LampToggle: View {
    let label: String
    @Binding var isOn: Bool

    @State private var isHovering = false

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isOn ? Theme.accent : Color.clear)
                    .frame(width: 7, height: 7)
                    .overlay(
                        RoundedRectangle(cornerRadius: 1.5)
                            .stroke(isOn ? Theme.accent
                                         : (isHovering ? Theme.secondaryText : Theme.tertiaryText),
                                    lineWidth: Theme.hairline)
                    )
                Text(label.uppercased())
                    .font(Theme.plateFont)
                    .kerning(Theme.plateTracking)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(isOn ? Theme.text : Theme.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

// MARK: - Glyph

/// The few pictographic marks the chrome needs, drawn as hairline paths so
/// they share one weight and voice.
struct Glyph: View {
    enum Kind {
        case chevronDown
        case chevronRight
        case plus
        case cross
    }

    let kind: Kind
    var size: CGFloat = 7
    var weight: CGFloat = 1.2

    var body: some View {
        GlyphShape(kind: kind)
            .stroke(style: StrokeStyle(lineWidth: weight, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }

    private struct GlyphShape: Shape {
        let kind: Glyph.Kind

        func path(in rect: CGRect) -> Path {
            var path = Path()
            switch kind {
            case .chevronDown:
                path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.28))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.22))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.28))
            case .chevronRight:
                path.move(to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.22, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.maxY))
            case .plus:
                path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            case .cross:
                path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            }
            return path
        }
    }
}

/// A small drawn icon button (delete row, add item…).
struct GlyphButton: View {
    let kind: Glyph.Kind
    var label: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Glyph(kind: kind)
                .foregroundStyle(isHovering ? Theme.text : Theme.secondaryText)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(label)
    }
}

// MARK: - Drawn star (ratings)

/// A five-pointed star path used for the filmstrip's rating row — drawn, so
/// its weight matches the rest of the chrome.
struct StarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.42
        var path = Path()
        for i in 0..<10 {
            let radius = i.isMultiple(of: 2) ? outer : inner
            let angle = (Double(i) / 10) * 2 * .pi - .pi / 2
            let point = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}
