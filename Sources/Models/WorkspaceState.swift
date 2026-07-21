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
        case .compare: "Compare"
        }
    }

    /// SF Symbols are the platform's native, coherent icon library and match
    /// the thin tool glyphs in the selected design direction.
    var symbolName: String {
        switch self {
        case .hand: "hand.draw"
        case .crop: "crop"
        case .heal: "bandage"
        case .clone: "stamp"
        case .brush: "paintbrush.pointed"
        case .gradient: "square.lefthalf.filled"
        case .eyedropper: "eyedropper"
        case .compare: "rectangle.split.2x1"
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
