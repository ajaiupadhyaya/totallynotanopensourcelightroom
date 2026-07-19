import SwiftUI

/// The application's visual constants.
///
/// A photo editor's chrome is not neutral decoration — it is the surround your
/// eye adapts to while judging color. The palette here is deliberately
/// achromatic and mid-dark:
///
/// - **Achromatic.** Any tint in the surround shifts your perception of the
///   image's white balance. Every interface gray has R = G = B exactly.
/// - **Mid-dark rather than black.** A pure-black surround exaggerates apparent
///   contrast and makes shadows look emptier than they are, so images get
///   edited flatter than intended. A calibrated neutral gray avoids that
///   simultaneous-contrast illusion.
/// - **Soft ivory text rather than pure white.** Full-white text on a dark
///   ground glares and fatigues over a long editing session.
enum Theme {
    /// Calibrated neutral background for color judgement.
    static let background = Color(white: 0x16 / 255)

    /// Panels and sidebars — one step up so structure reads without a border.
    static let surface = Color(white: 0x1E / 255)

    /// Raised controls within a panel.
    static let control = Color(white: 0x2A / 255)

    /// Hairline separators.
    static let separator = Color(white: 0x33 / 255)

    /// Primary text: soft ivory, not pure white.
    static let text = Color(red: 0xE2 / 255, green: 0xE8 / 255, blue: 0xF0 / 255)

    /// De-emphasized text.
    static let secondaryText = Color(white: 0x8A / 255)

    /// The canvas immediately around the photo. Darker than the chrome so the
    /// image reads as the brightest thing on screen, but still not black.
    static let canvas = Color(white: 0x10 / 255)

    /// Selection / active accent.
    static let accent = Color(red: 0.34, green: 0.60, blue: 0.98)

    /// Opacity applied to a rejected frame's thumbnail so it recedes during a
    /// culling pass without disappearing.
    static let rejectedOpacity = 0.4
}

extension View {
    /// Applies the editor's dark chrome to a container.
    func editorSurface() -> some View {
        background(Theme.surface).foregroundStyle(Theme.text)
    }
}
