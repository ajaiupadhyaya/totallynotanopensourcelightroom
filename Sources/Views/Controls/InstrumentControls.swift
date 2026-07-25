import SwiftUI

// The drawn control kit.
//
// Nothing here wraps an AppKit control — every affordance is drawn, so the
// chrome owes nothing to the host platform's widget set. What the kit does owe
// the platform is *behaviour*: a control has to look pressable, respond the
// instant the pointer arrives, be reachable from the keyboard, and never be
// smaller than a comfortable target. A drawn control that skips those reads as
// a picture of a control.
//
// Shared vocabulary:
//
// - **TabStrip** — a typographic segmented control; the active segment carries
//   an accent underline that slides between positions.
// - **PlateButton** — a caps label on a machined plate.
// - **LampToggle** — a square indicator lamp beside a caps label.
// - **IconButton** — a drawn glyph in a square plate, for the tool rail.
// - **Icon** — the app's pictographic marks, drawn as paths at one weight.

// MARK: - TabStrip

/// A typographic segmented control.
///
/// The active segment is marked by an underline that *moves* between segments
/// rather than appearing and disappearing, so the eye follows the selection
/// instead of re-finding it.
struct TabStrip<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    /// Gap between segments. Narrow panels need a tighter strip than the top
    /// bar does, and a strip that overflows silently drops its first tab.
    var spacing: CGFloat = Theme.space4

    @Namespace private var underline
    @State private var hovering: Value?

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Button {
                    withAnimation(Theme.standard) { selection = option.value }
                } label: {
                    VStack(spacing: 4) {
                        Text(option.label.uppercased())
                            .plateLabel()
                            .lineLimit(1)
                            .foregroundStyle(
                                isSelected ? Theme.text
                                    : (hovering == option.value ? Theme.secondaryText
                                                                : Theme.tertiaryText)
                            )

                        // The rail is always present so the label never shifts
                        // vertically when selection moves.
                        ZStack {
                            Capsule().fill(Color.clear).frame(height: 2)
                            if isSelected {
                                Capsule()
                                    .fill(Theme.accent)
                                    .frame(height: 2)
                                    .matchedGeometryEffect(id: "tab", in: underline)
                            }
                        }
                    }
                    .fixedSize()
                    .comfortableHitTarget(Theme.contextBarHeight - 12)
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 ? option.value : nil }
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }
}

// MARK: - PlateButton

/// A drawn button: a caps label on a machined plate.
struct PlateButton: View {
    enum Emphasis {
        /// The default: a quiet plate that fills on hover.
        case normal
        /// The one action a surface is really for.
        case prominent
        /// Destroys something.
        case destructive
    }

    let title: String
    var emphasis: Emphasis = .normal
    var isEnabled: Bool = true
    var fillsWidth: Bool = false
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Button(action: { if isEnabled { action() } }) {
            Text(title.uppercased())
                .plateLabel()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(foreground)
                .padding(.horizontal, Theme.space3)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .frame(height: Theme.minimumHitTarget)
                .background(background, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.radius)
                        .strokeBorder(border, lineWidth: Theme.hairline)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressReporting(isPressed: $isPressed))
        .disabled(!isEnabled)
        .onHover { isHovering = isEnabled && $0 }
        .animation(Theme.quick, value: isHovering)
        .animation(Theme.quick, value: isPressed)
        .accessibilityLabel(title)
    }

    private var tint: Color {
        switch emphasis {
        case .normal: Theme.text
        case .prominent: Theme.accent
        case .destructive: Theme.destructive
        }
    }

    private var foreground: Color {
        guard isEnabled else { return Theme.disabledText }
        switch emphasis {
        case .normal: return isHovering ? Theme.text : Theme.text.opacity(0.86)
        case .prominent, .destructive: return isPressed ? tint.opacity(0.8) : tint
        }
    }

    private var background: Color {
        guard isEnabled else { return .clear }
        if isPressed { return Theme.controlActive }
        if isHovering { return emphasis == .normal ? Theme.controlHover : tint.opacity(0.14) }
        return emphasis == .normal ? Theme.control.opacity(0.55) : tint.opacity(0.08)
    }

    private var border: Color {
        guard isEnabled else { return Theme.separator.opacity(0.6) }
        switch emphasis {
        case .normal: return isHovering ? Theme.strongSeparator : Theme.separator
        case .prominent, .destructive: return tint.opacity(isHovering ? 0.7 : 0.42)
        }
    }
}

/// Reports the press state of a real `Button`, so plates get pressed styling
/// without hand-rolling a drag gesture that then has to re-implement
/// "did the pointer leave before release".
private struct PressReporting: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in isPressed = pressed }
    }
}

// MARK: - LampToggle

/// A drawn toggle: a small square lamp that lights with the accent.
struct LampToggle: View {
    let label: String
    @Binding var isOn: Bool

    @State private var isHovering = false

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isOn ? Theme.accent : Color.clear)
                    .frame(width: 7, height: 7)
                    .overlay {
                        RoundedRectangle(cornerRadius: 1.5)
                            .strokeBorder(
                                isOn ? Theme.accent
                                     : (isHovering ? Theme.secondaryText : Theme.tertiaryText),
                                lineWidth: Theme.hairline
                            )
                    }
                    // The lit lamp gets a faint bloom, the way an indicator on
                    // a real panel spills a little light onto its bezel.
                    .shadow(color: isOn ? Theme.accent.opacity(0.55) : .clear, radius: 3)

                Text(label.uppercased())
                    .plateLabel()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(isOn ? Theme.text : Theme.secondaryText)
            }
            .padding(.horizontal, 2)
            .comfortableHitTarget()
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Theme.quick, value: isOn)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
        .accessibilityLabel(label)
    }
}

// MARK: - Icons

/// The app's pictographic marks, drawn as paths so they share one weight,
/// one optical size, and one voice.
///
/// These are drawn rather than taken from SF Symbols because they are two or
/// three strokes each and have to carry exactly the hairline weight of the
/// faders and plates beside them. The *tool* marks are a different problem —
/// real pictograms that must survive at 15 points — and those come from SF
/// Symbols, which is drawn and hinted for that size. The split is by what the
/// mark has to do, not by preference.
struct Icon: View {
    enum Kind {
        // Chrome
        case chevronDown, chevronRight, plus, cross, check
        // Actions
        case undo, redo, exportArrow, importArrow, reset, trash
        // State
        case star, warningTriangle, viewfinder
    }

    let kind: Kind
    var size: CGFloat = 13
    var weight: CGFloat = 1.3

    var body: some View {
        Shape(kind: kind)
            .stroke(style: StrokeStyle(lineWidth: weight, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }

    /// Filled variants, for marks that read better solid at small sizes.
    struct Filled: View {
        let kind: Kind
        var size: CGFloat = 13

        var body: some View {
            Shape(kind: kind).frame(width: size, height: size)
        }
    }

    fileprivate struct Shape: SwiftUI.Shape {
        let kind: Kind

        // Every glyph is drawn on a 0…1 square and scaled, so weights and
        // proportions stay consistent at any size.
        func path(in rect: CGRect) -> Path {
            let w = rect.width, h = rect.height
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: rect.minX + x * w, y: rect.minY + y * h)
            }
            var path = Path()

            switch kind {
            case .chevronDown:
                path.move(to: p(0.20, 0.38)); path.addLine(to: p(0.50, 0.66))
                path.addLine(to: p(0.80, 0.38))

            case .chevronRight:
                path.move(to: p(0.38, 0.20)); path.addLine(to: p(0.66, 0.50))
                path.addLine(to: p(0.38, 0.80))

            case .plus:
                path.move(to: p(0.5, 0.16)); path.addLine(to: p(0.5, 0.84))
                path.move(to: p(0.16, 0.5)); path.addLine(to: p(0.84, 0.5))

            case .cross:
                path.move(to: p(0.22, 0.22)); path.addLine(to: p(0.78, 0.78))
                path.move(to: p(0.78, 0.22)); path.addLine(to: p(0.22, 0.78))

            case .check:
                path.move(to: p(0.20, 0.52)); path.addLine(to: p(0.42, 0.74))
                path.addLine(to: p(0.80, 0.28))

            case .undo, .redo:
                let mirrored = kind == .redo
                func q(_ x: CGFloat, _ y: CGFloat) -> CGPoint { p(mirrored ? 1 - x : x, y) }
                path.move(to: q(0.20, 0.40))
                path.addLine(to: q(0.56, 0.40))
                path.addQuadCurve(to: q(0.56, 0.80), control: q(0.92, 0.60))
                path.addLine(to: q(0.36, 0.80))
                path.move(to: q(0.20, 0.40)); path.addLine(to: q(0.36, 0.24))
                path.move(to: q(0.20, 0.40)); path.addLine(to: q(0.36, 0.56))

            case .exportArrow:
                path.move(to: p(0.5, 0.72)); path.addLine(to: p(0.5, 0.14))
                path.move(to: p(0.30, 0.34)); path.addLine(to: p(0.5, 0.14))
                path.addLine(to: p(0.70, 0.34))
                path.move(to: p(0.16, 0.62)); path.addLine(to: p(0.16, 0.88))
                path.addLine(to: p(0.84, 0.88)); path.addLine(to: p(0.84, 0.62))

            case .importArrow:
                path.move(to: p(0.5, 0.14)); path.addLine(to: p(0.5, 0.72))
                path.move(to: p(0.30, 0.52)); path.addLine(to: p(0.5, 0.72))
                path.addLine(to: p(0.70, 0.52))
                path.move(to: p(0.16, 0.62)); path.addLine(to: p(0.16, 0.88))
                path.addLine(to: p(0.84, 0.88)); path.addLine(to: p(0.84, 0.62))

            case .reset:
                path.addArc(center: p(0.5, 0.52), radius: 0.34 * min(w, h),
                            startAngle: .degrees(150), endAngle: .degrees(60),
                            clockwise: false)
                path.move(to: p(0.20, 0.18)); path.addLine(to: p(0.22, 0.42))
                path.addLine(to: p(0.46, 0.38))

            case .trash:
                path.move(to: p(0.14, 0.26)); path.addLine(to: p(0.86, 0.26))
                path.move(to: p(0.36, 0.26)); path.addLine(to: p(0.36, 0.14))
                path.addLine(to: p(0.64, 0.14)); path.addLine(to: p(0.64, 0.26))
                path.move(to: p(0.24, 0.26)); path.addLine(to: p(0.30, 0.88))
                path.addLine(to: p(0.70, 0.88)); path.addLine(to: p(0.76, 0.26))

            case .star:
                let outer = min(w, h) / 2
                let inner = outer * 0.42
                let centre = CGPoint(x: rect.midX, y: rect.midY)
                for i in 0..<10 {
                    let radius = i.isMultiple(of: 2) ? outer : inner
                    let angle = (Double(i) / 10) * 2 * .pi - .pi / 2
                    let point = CGPoint(x: centre.x + cos(angle) * radius,
                                        y: centre.y + sin(angle) * radius)
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                path.closeSubpath()

            case .warningTriangle:
                path.move(to: p(0.5, 0.14)); path.addLine(to: p(0.94, 0.86))
                path.addLine(to: p(0.06, 0.86)); path.closeSubpath()

            case .viewfinder:
                for (x, y, dx, dy) in [(0.10, 0.30, 0.0, -1.0), (0.90, 0.30, 0.0, -1.0),
                                       (0.10, 0.70, 0.0, 1.0), (0.90, 0.70, 0.0, 1.0)] {
                    let toward: CGFloat = x < 0.5 ? 0.26 : -0.26
                    path.move(to: p(CGFloat(x), CGFloat(y) + CGFloat(dy) * 0.16))
                    path.addLine(to: p(CGFloat(x), CGFloat(y)))
                    path.addLine(to: p(CGFloat(x) + toward, CGFloat(y)))
                    _ = dx
                }
            }
            return path
        }
    }
}

/// A small drawn icon button — delete a row, add an item.
struct IconButton: View {
    let icon: Icon.Kind
    var label: String
    var tint: Color = Theme.secondaryText
    var size: CGFloat = 12
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Icon(kind: icon, size: size)
                .foregroundStyle(isHovering ? Theme.text : tint)
                .frame(width: Theme.minimumHitTarget, height: Theme.minimumHitTarget)
                .background(
                    isHovering ? Theme.controlHover : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.radius)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Theme.quick, value: isHovering)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A tool-rail button: a symbol in a square plate that lights when the tool is
/// in hand.
struct ToolButton: View {
    let symbol: String
    let label: String
    let shortcut: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: isSelected ? .medium : .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(isSelected ? Theme.accent
                                            : (isHovering ? Theme.text : Theme.secondaryText))
                .frame(width: 32, height: 32)
                .background(
                    isSelected ? Theme.accentMuted : (isHovering ? Theme.controlHover : .clear),
                    in: RoundedRectangle(cornerRadius: Theme.radius)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.radius)
                        .strokeBorder(isSelected ? Theme.accent.opacity(0.45) : .clear,
                                      lineWidth: Theme.hairline)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Theme.quick, value: isSelected)
        .animation(Theme.quick, value: isHovering)
        .help("\(label)  ·  \(shortcut)")
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Fields

/// A drawn text field. Wraps `TextField` for editing behaviour — text input is
/// one place where re-implementing the platform would cost selection, dead
/// keys, and the input menu — but draws its own frame so it sits in the kit.
struct InstrumentField: View {
    let placeholder: String
    @Binding var text: String
    var icon: Icon.Kind?

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Icon(kind: icon, size: 11)
                    .foregroundStyle(isFocused ? Theme.accent : Theme.tertiaryText)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.controlLabel)
                .foregroundStyle(Theme.text)
                .focused($isFocused)
        }
        .padding(.horizontal, Theme.space2)
        .frame(height: Theme.minimumHitTarget + 2)
        .background(Theme.canvas.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(isFocused ? Theme.accent.opacity(0.7) : Theme.separator,
                              lineWidth: Theme.hairline)
        }
        .animation(Theme.quick, value: isFocused)
    }
}

// MARK: - Compatibility

/// A five-pointed star path, kept for the roll's rating row.
struct StarShape: Shape {
    func path(in rect: CGRect) -> Path { Icon.Shape(kind: .star).path(in: rect) }
}
