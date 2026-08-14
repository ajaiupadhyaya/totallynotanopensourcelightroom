import Foundation

/// The three deliberate modes of the inspector. Global development, local
/// masking, and history are separate working contexts instead of one endlessly
/// scrolling column.
enum InspectorMode: String, CaseIterable, Identifiable {
    case adjust
    case masks
    case history

    var id: Self { self }
    var label: String { rawValue.uppercased() }
}

/// Pointer-first tools that operate directly on the photograph.
enum EditorTool: String, CaseIterable, Identifiable {
    case hand
    case crop
    case heal
    case clone
    case brush
    case gradient
    case eyedropper
    case targetedAdjustment
    case compare

    var id: Self { self }

    var label: String {
        switch self {
        case .hand: "Hand"
        case .crop: "Crop"
        case .heal: "Heal"
        case .clone: "Clone"
        case .brush: "Brush"
        case .gradient: "Gradient"
        case .eyedropper: "Eyedropper"
        case .targetedAdjustment: "Target"
        case .compare: "Compare"
        }
    }

    /// The tool marks come from SF Symbols.
    ///
    /// The rest of the chrome draws its own glyphs, because a chevron or a plus
    /// is two strokes and has to match the hairline weight of the faders beside
    /// it. A hand, a plaster, a loaded brush are different work: they are real
    /// pictograms that have to stay legible at 15 points, and hand-drawing them
    /// produced marks that read as blobs at exactly the size they are used.
    /// Apple's set is drawn and hinted for this size, so the tools use it and
    /// the chrome does not.
    var symbolName: String {
        switch self {
        case .hand: "hand.raised"
        case .crop: "crop"
        case .heal: "bandage"
        case .clone: "stamp"
        case .brush: "paintbrush.pointed"
        case .gradient: "circle.righthalf.filled"
        case .eyedropper: "eyedropper.halffull"
        case .targetedAdjustment: "target"
        case .compare: "rectangle.split.2x1"
        }
    }

    /// Tools that act on the frame's geometry and content, versus tools that
    /// only change what you are looking at. The rail groups them, because
    /// reaching for "compare" is a different kind of act from reaching for
    /// "brush", and a flat list of eight hides that.
    var isViewingAid: Bool {
        switch self {
        case .hand, .compare: true
        case .crop, .heal, .clone, .brush, .gradient, .eyedropper, .targetedAdjustment: false
        }
    }

    var shortcutHint: String? {
        switch self {
        case .hand: "H"
        case .crop: "C"
        case .heal: "J"
        case .clone: "S"
        case .brush: "B"
        case .gradient: "G"
        case .eyedropper: "I"
        case .targetedAdjustment: "T"
        case .compare: "\\"
        }
    }

    /// Resolves the bare key a tool advertises in ``shortcutHint``. Selecting
    /// a tool by keystroke and reading its tooltip must never disagree, so
    /// both sides derive from the same table.
    ///
    /// `compare` is excluded on purpose: `\` is a momentary before/after look,
    /// not a mode to enter, and routing it through tool activation would
    /// commit an in-progress crop as a side effect.
    init?(shortcutKey: String) {
        let key = shortcutKey.lowercased()
        guard let match = Self.allCases.first(where: {
            $0 != .compare && $0.shortcutHint?.lowercased() == key
        }) else { return nil }
        self = match
    }
}
