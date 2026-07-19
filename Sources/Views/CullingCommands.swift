import SwiftUI

/// The keyboard actions for a culling pass.
///
/// Culling is the highest-volume thing a photographer does — hundreds of frames
/// judged in a sitting — so it has to work without the mouse. The layout keeps
/// one hand on the number row for classification and the other free to move
/// through frames.
///
/// - `1`–`5`: star rating (pressing the current rating again clears it)
/// - `0`: clear the rating
/// - `6`–`9`: color label
/// - `P`: pick · `X`: reject · `U`: unflag
///
/// Rejected frames dim rather than vanish, so a reject stays reversible and you
/// can still see what you threw away in context.
enum CullingCommands {
    /// Applies a key press to the given entries. Returns `true` if the key was
    /// one this handler owns, so callers can fall through for anything else.
    @discardableResult
    static func handle(
        key: KeyEquivalent,
        on entries: [CatalogEntry],
        app: AppModel
    ) -> Bool {
        guard !entries.isEmpty else { return false }

        switch key {
        case "0", "1", "2", "3", "4", "5":
            let stars = Int(String(key.character)) ?? 0
            for entry in entries {
                // Pressing the rating a frame already has clears it, so the
                // same key both sets and unsets.
                app.setRating(entry.rating == stars ? 0 : stars, for: entry)
            }
            return true

        case "6", "7", "8", "9":
            let labels: [ColorLabel] = [.red, .yellow, .green, .blue]
            let index = (Int(String(key.character)) ?? 6) - 6
            guard labels.indices.contains(index) else { return false }
            let label = labels[index]
            for entry in entries {
                app.setColorLabel(entry.colorLabel == label ? .none : label, for: entry)
            }
            return true

        case "p", "P":
            for entry in entries {
                app.setFlag(entry.flag == .picked ? .unflagged : .picked, for: entry)
            }
            return true

        case "x", "X":
            for entry in entries {
                app.setFlag(entry.flag == .rejected ? .unflagged : .rejected, for: entry)
            }
            return true

        case "u", "U":
            for entry in entries { app.setFlag(.unflagged, for: entry) }
            return true

        default:
            return false
        }
    }

    /// Every key this handler responds to, for wiring up `.onKeyPress`.
    static let handledKeys: Set<KeyEquivalent> = [
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
        "p", "P", "x", "X", "u", "U",
    ]
}
