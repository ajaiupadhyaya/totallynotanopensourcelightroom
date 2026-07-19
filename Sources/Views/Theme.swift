import SwiftUI

/// The application's visual constants.
///
/// ## The design position
///
/// This is a darkroom instrument, and its chrome is the surround the eye
/// adapts to while judging color. Two rules follow, and every token here obeys
/// them:
///
/// - **The chrome is achromatic.** Any tint in the surround shifts perceived
///   white balance, so every interface gray has R = G = B exactly, and the
///   accent is used sparingly, away from the canvas.
/// - **Color appears only where it carries photographic meaning** — the
///   histogram's channels, a film base swatch, a label dot. The one deliberate
///   exception is ``filmEdge``: the dim amber of film edge printing, used
///   solely for the filmstrip's rebate labels. It is the vernacular of the
///   subject itself, kept small, low-chroma, and far from the image.
///
/// Surfaces are mid-dark rather than black: a pure-black surround exaggerates
/// apparent contrast and images get edited flatter than intended. Text is soft
/// ivory rather than white, which glares over a long session.
enum Theme {
    // MARK: Surfaces

    /// Calibrated neutral background for color judgement.
    static let background = Color(white: 0x16 / 255)

    /// Panels and sidebars — one step up so structure reads without a border.
    static let surface = Color(white: 0x1E / 255)

    /// Raised controls within a panel.
    static let control = Color(white: 0x2A / 255)

    /// Hairline separators.
    static let separator = Color(white: 0x33 / 255)

    /// The canvas immediately around the photo. Darker than the chrome so the
    /// image reads as the brightest thing on screen, but still not black.
    static let canvas = Color(white: 0x10 / 255)

    /// The filmstrip rebate — the darkest chrome surface, standing in for the
    /// unexposed film base the frames sit on.
    static let rebate = Color(white: 0x0C / 255)

    // MARK: Text

    /// Primary text: soft ivory, not pure white.
    static let text = Color(red: 0xE2 / 255, green: 0xE8 / 255, blue: 0xF0 / 255)

    /// De-emphasized text.
    static let secondaryText = Color(white: 0x8A / 255)

    /// Faint text — engraved section labels at rest.
    static let tertiaryText = Color(white: 0x5E / 255)

    // MARK: Accents

    /// Selection / active accent. Cool and clearly "interface", so it is never
    /// mistaken for image content.
    static let accent = Color(red: 0.34, green: 0.60, blue: 0.98)

    /// Film edge printing: the dim amber of frame numbers and stock names
    /// exposed along a negative's rebate. Used only in the filmstrip.
    static let filmEdge = Color(red: 0xA8 / 255, green: 0x8A / 255, blue: 0x4E / 255)

    /// Opacity applied to a rejected frame's thumbnail so it recedes during a
    /// culling pass without disappearing.
    static let rejectedOpacity = 0.4

    // MARK: Type

    /// Engraved section label, like the labels on darkroom equipment:
    /// small, semibold, tracked wide, always uppercased by the caller.
    static let engravedLabel = Font.system(size: 10, weight: .semibold)

    /// Tracking (kerning) for engraved labels.
    static let engravedTracking: CGFloat = 1.4

    /// Numeric readouts. Monospaced so values don't jitter as they change.
    static let valueFont = Font.system(size: 11, weight: .regular, design: .monospaced)

    /// Control labels inside panels.
    static let controlFont = Font.system(size: 11.5)

    /// Film-edge print in the filmstrip: monospaced caps, like the exposed
    /// legend along a rebate.
    static let filmEdgeFont = Font.system(size: 8.5, weight: .medium, design: .monospaced)

    // MARK: Metrics

    /// Horizontal inset shared by every panel section.
    static let panelInset: CGFloat = 14

    /// Vertical rhythm between controls in a section.
    static let controlSpacing: CGFloat = 10
}

extension View {
    /// Applies the editor's dark chrome to a container.
    func editorSurface() -> some View {
        background(Theme.surface).foregroundStyle(Theme.text)
    }

    /// Styles a string as an engraved panel label.
    func engraved() -> some View {
        font(Theme.engravedLabel)
            .kerning(Theme.engravedTracking)
            .foregroundStyle(Theme.tertiaryText)
    }
}
