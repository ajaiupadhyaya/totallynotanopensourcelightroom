import SwiftUI

/// The application's design system.
///
/// ## The position
///
/// This is a develop desk — an instrument someone sits at for hours judging
/// colour. Three rules follow, and every token here obeys them.
///
/// **The chrome is achromatic.** Any tint in the surround shifts perceived
/// white balance, so every interface grey has R = G = B exactly. Colour appears
/// only where it carries photographic meaning: the histogram's channels, a film
/// base swatch, a label dot, a clipping warning. The one deliberate exception
/// is ``filmEdge``, the dim amber of film edge printing, used solely for the
/// roll's rebate legends — the vernacular of the subject itself, kept small,
/// low-chroma, and far from the image.
///
/// **Surfaces are mid-dark, not black.** A pure-black surround exaggerates
/// apparent contrast and photographs get edited flatter than intended. Text is
/// soft ivory rather than white, which glares over a long session.
///
/// **Monospace means data.** The chrome speaks in two voices and the split
/// carries meaning rather than style: anything *measured* — a value, a
/// dimension, a frame number, an exposure in stops — is set in monospace so
/// digits hold their column and don't jitter as they change. Everything a
/// person *reads* — control names, buttons, helper copy — is set in the system
/// text face. Setting the whole interface in monospace, as this once did, makes
/// a terminal costume out of a distinction that should be doing work.
enum Theme {

    // MARK: - Surfaces
    //
    // Elevation is luminance alone. Each step is large enough to read without a
    // border, so structure survives on a dim display and never depends on
    // drawing more lines.

    /// The well the photograph sits in — the darkest surface, so the image
    /// reads as the brightest thing on screen without being surrounded by black.
    static let canvas = Color(white: 0x0B / 255)

    /// The roll's rebate: unexposed film base the frames sit on.
    static let rebate = Color(white: 0x0D / 255)

    /// Window base, behind the panes.
    static let background = Color(white: 0x14 / 255)

    /// Panels and sidebars.
    static let surface = Color(white: 0x1C / 255)

    /// A panel header, a selected row — raised only by luminance.
    static let raisedSurface = Color(white: 0x24 / 255)

    /// Controls sitting inside a panel.
    static let control = Color(white: 0x2C / 255)

    /// A control under the pointer.
    static let controlHover = Color(white: 0x34 / 255)

    /// A control being pressed.
    static let controlActive = Color(white: 0x3C / 255)

    /// Hairline separators.
    static let separator = Color(white: 0x32 / 255)

    /// A stronger rule for workspace boundaries.
    static let strongSeparator = Color(white: 0x48 / 255)

    /// The specular top edge that gives a raised surface its machined feel.
    ///
    /// A single hairline of near-white at very low opacity along the top of a
    /// control reads as a bevel catching light. It is how these surfaces get
    /// depth without a drop shadow, a gradient, or any colour at all.
    static let specular = Color.white.opacity(0.055)

    /// The matching shadow line along the bottom of a raised surface.
    static let recess = Color.black.opacity(0.35)

    // MARK: - Text

    /// Primary text: soft ivory, not pure white.
    static let text = Color(white: 0xEC / 255)

    /// De-emphasized text.
    static let secondaryText = Color(white: 0x9C / 255)

    /// Faint text — section labels at rest, units, inactive state.
    static let tertiaryText = Color(white: 0x6C / 255)

    /// Text on a disabled control.
    static let disabledText = Color(white: 0x4E / 255)

    // MARK: - Accents

    /// Selection and active state. Cool and clearly "interface", so it is never
    /// mistaken for image content.
    static let accent = Color(red: 0.36, green: 0.61, blue: 1.0)

    /// The accent at panel-fill strength.
    static let accentMuted = Color(red: 0.36, green: 0.61, blue: 1.0).opacity(0.16)

    /// Diagnostic warning — clipping, irreversible actions. Never decorative.
    static let warning = Color(red: 0.93, green: 0.64, blue: 0.24)

    /// Destructive actions.
    static let destructive = Color(red: 0.90, green: 0.35, blue: 0.32)

    /// Film edge printing: the dim amber of frame numbers and stock names
    /// exposed along a negative's rebate. Used only in the roll.
    static let filmEdge = Color(red: 0xA8 / 255, green: 0x8A / 255, blue: 0x4E / 255)

    /// Histogram channels. Kept inside the histogram, where colour is data.
    static let histogramRed = Color(red: 0.95, green: 0.28, blue: 0.25)
    static let histogramGreen = Color(red: 0.30, green: 0.86, blue: 0.38)
    static let histogramBlue = Color(red: 0.34, green: 0.50, blue: 0.98)

    /// Opacity applied to a rejected frame so it recedes during a culling pass
    /// without disappearing — the decision stays visible and reversible.
    static let rejectedOpacity = 0.38

    // MARK: - Type
    //
    // Two families, split by meaning (see the type note above): the system text
    // face for language, monospace for measurement.

    // Language — things a person reads.

    /// Control names inside panels: "Exposure", "Highlights".
    static let controlLabel = Font.system(size: 12, weight: .regular)

    /// Body copy, file names, history rows.
    static let body = Font.system(size: 12, weight: .regular)

    /// Small helper copy under a heading.
    static let caption = Font.system(size: 11, weight: .regular)

    /// Section titles, always uppercased by the caller. Tracked caps in the
    /// text face read as engraved rather than typed.
    static let sectionTitle = Font.system(size: 10.5, weight: .semibold)

    /// Tracking for section titles.
    static let sectionTracking: CGFloat = 1.1

    /// Buttons, tabs, and lamps.
    static let plateFont = Font.system(size: 10.5, weight: .medium)

    /// Tracking for plate/tab/lamp caps.
    static let plateTracking: CGFloat = 0.8

    /// The wordmark.
    static let wordmarkFont = Font.system(size: 12, weight: .semibold)

    /// A workspace heading.
    static let heading = Font.system(size: 15, weight: .semibold)

    // Measurement — things the instrument reports.

    /// Numeric readouts. Monospaced digits so values don't jitter as they move.
    static let valueFont = Font.system(size: 11.5, weight: .medium, design: .monospaced)

    /// A large readout, for the canvas status and headline figures.
    static let largeValueFont = Font.system(size: 12.5, weight: .medium, design: .monospaced)

    /// The stage index preceding a section title ("04" in "04 · RETOUCH").
    static let indexFont = Font.system(size: 9.5, weight: .medium, design: .monospaced)

    /// Film-edge print in the roll: the exposed legend along a rebate.
    static let filmEdgeFont = Font.system(size: 8.5, weight: .medium, design: .monospaced)

    /// Units and suffixes trailing a value ("EV", "K", "px").
    static let unitFont = Font.system(size: 9.5, weight: .medium, design: .monospaced)

    // MARK: - Space
    //
    // A 4-point scale. Every inset, gap, and pad in the app comes from here, so
    // rhythm is a property of the system rather than of each view's judgement.

    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space5: CGFloat = 20
    static let space6: CGFloat = 24
    static let space8: CGFloat = 32

    /// Horizontal inset shared by every panel section.
    static let panelInset: CGFloat = 14

    /// Vertical rhythm between controls in a section.
    static let controlSpacing: CGFloat = 14

    // MARK: - Shape

    /// Corner radius for controls. Small: this is machined, not soft.
    static let radius: CGFloat = 4

    /// Corner radius for larger surfaces — the histogram, sheets.
    static let largeRadius: CGFloat = 6

    /// Width of a hairline rule. One device pixel on Retina.
    static let hairline: CGFloat = 1

    /// The smallest comfortable pointer target. Controls may *draw* finer than
    /// this, but they must not be *hittable* smaller than it.
    static let minimumHitTarget: CGFloat = 22

    // MARK: - Metrics

    static let topBarHeight: CGFloat = 46
    static let contextBarHeight: CGFloat = 40
    static let statusBarHeight: CGFloat = 30
    static let toolRailWidth: CGFloat = 48
    static let libraryWidth: CGFloat = 252
    static let inspectorWidth: CGFloat = 352

    /// Width of the inspector's stage gutter — the column the pipeline indices
    /// sit in, and the spine runs down.
    static let stageGutter: CGFloat = 26

    // MARK: - Motion
    //
    // Motion is for state changes a person needs to follow, never for
    // decoration, and never on a value being scrubbed — a fader must track the
    // pointer exactly or it stops being an instrument.

    /// Hover and press feedback.
    static let quick = Animation.easeOut(duration: 0.11)

    /// Selection moving, a panel folding.
    static let standard = Animation.easeOut(duration: 0.18)

    /// A section expanding: enough spring to feel physical, not bouncy.
    static let expand = Animation.spring(response: 0.28, dampingFraction: 0.86)
}

// MARK: - Shared view treatments

extension View {
    /// Applies the editor's dark chrome to a container.
    func editorSurface() -> some View {
        background(Theme.surface).foregroundStyle(Theme.text)
    }

    /// Styles a string as a section label: tracked caps, quiet at rest.
    func sectionLabel(_ emphasis: Color = Theme.tertiaryText) -> some View {
        font(Theme.sectionTitle)
            .kerning(Theme.sectionTracking)
            .foregroundStyle(emphasis)
    }

    /// Styles a string as a caps label on a button, tab, or lamp.
    func plateLabel() -> some View {
        font(Theme.plateFont).kerning(Theme.plateTracking)
    }

    /// Gives a raised surface its machined edge: a specular hairline along the
    /// top and a shadow line along the bottom.
    ///
    /// This is the app's only depth device. It costs one pixel each way, adds
    /// no colour, and survives on a dim display — where a drop shadow would
    /// either disappear or turn into a grey smear.
    func machinedEdges(radius: CGFloat = Theme.radius) -> some View {
        overlay {
            UnevenRoundedRectangle(
                topLeadingRadius: radius, bottomLeadingRadius: radius,
                bottomTrailingRadius: radius, topTrailingRadius: radius
            )
            .strokeBorder(
                LinearGradient(
                    colors: [Theme.specular, .clear, Theme.recess],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: Theme.hairline
            )
        }
    }

    /// Guarantees a control is at least as tall as a comfortable pointer
    /// target, whatever it draws.
    func comfortableHitTarget(_ height: CGFloat = Theme.minimumHitTarget) -> some View {
        frame(minHeight: height).contentShape(Rectangle())
    }
}

/// A hairline rule. Named so the intent is legible at every call site and the
/// weight can never drift between them.
struct Rule: View {
    enum Axis { case horizontal, vertical }

    var axis: Axis = .horizontal
    var color: Color = Theme.separator

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(
                width: axis == .vertical ? Theme.hairline : nil,
                height: axis == .horizontal ? Theme.hairline : nil
            )
    }
}
