import CoreImage
import Foundation
import Observation

/// Roll actions — create, assign, convert — kept out of the 1100-line
/// `EditorModel` per the roadmap's own instruction. A roll is a physical
/// fact (one film, one development, one scan session); this model gives its
/// conversion constants one owner.
@Observable
final class RollModel {
    private unowned let app: AppModel
    private(set) var rolls: [Roll] = []
    private(set) var isConverting = false

    init(app: AppModel) {
        self.app = app
        reload()
    }

    func reload() {
        rolls = (try? app.catalog.allRolls()) ?? []
    }

    func roll(for entry: CatalogEntry) -> Roll? {
        guard let id = entry.rollID else { return nil }
        return rolls.first { $0.id == id }
    }

    @discardableResult
    func createRoll(identifier: String, stock: String?,
                    from entries: [CatalogEntry]) -> Roll? {
        let trimmed = identifier.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let roll = Roll(id: UUID(), identifier: trimmed,
                        stock: stock?.isEmpty == true ? nil : stock,
                        camera: nil, lens: nil, exposureIndex: nil, pushPull: nil,
                        developer: nil, devNotes: nil, lab: nil, scanDate: nil,
                        dateCreated: Date(), conversion: nil)
        do {
            try app.catalog.saveRoll(roll)
        } catch {
            app.reportError("Could not create the roll: \(error.localizedDescription)")
            return nil
        }
        reload()
        add(entries, to: roll)
        return roll
    }

    /// Assigns entries to the roll, numbering frames in import order and
    /// continuing from the roll's current highest frame. rollID/frameNumber
    /// are entry columns, not stack fields — saved directly, no undo step.
    func add(_ entries: [CatalogEntry], to roll: Roll) {
        let existing = (try? app.catalog.entries(inRoll: roll.id)) ?? []
        var next = (existing.compactMap(\.frameNumber).max() ?? 0) + 1
        var updates: [CatalogEntry] = []
        for entry in entries.sorted(by: { $0.dateImported < $1.dateImported })
        where entry.rollID != roll.id {
            var updated = entry
            updated.rollID = roll.id
            updated.frameNumber = next
            next += 1
            updates.append(updated)
        }
        app.updateEntries(updates)
    }

    /// Convert Roll: measure every frame, solve once as a roll, write every
    /// frame's stack as prepared (entry, stack) pairs — snapshotting each
    /// frame first, because this overwrites stacks and preservation is the
    /// house rule. Frames that fail to decode are skipped and reported, never
    /// fatal to the roll.
    func convertRoll(_ roll: Roll, profile: FilmToneProfile = .labStandard) async {
        guard !isConverting else { return }
        isConverting = true
        defer { isConverting = false }

        let entries = (try? app.catalog.entries(inRoll: roll.id)) ?? []
        guard !entries.isEmpty else { return }

        let context = CIContext()
        var measured: [(CatalogEntry, FrameMeasurement)] = []
        var skipped: [String] = []
        for entry in entries {
            guard let scan = ImageDecoder.loadPreviewImage(from: entry.fileURL,
                                                           maxDimension: 1600,
                                                           processVersion: 2) else {
                skipped.append(entry.fileName)
                continue
            }
            let film = entry.editStack.filmNegative
            let cropped = GeometryTransform.apply(scan, geometry: entry.editStack.geometry)
            let sampled = film.baseOrigin == .sampled ? film.baseColor : nil
            guard let m = AutoInvert.measure(scan: cropped, sampledBase: sampled,
                                             context: context) else {
                skipped.append(entry.fileName)
                continue
            }
            measured.append((entry, m))
        }
        guard !measured.isEmpty,
              let solution = RollAnalysis.solve(measurements: measured.map(\.1),
                                                profile: profile) else {
            app.reportError("Convert Roll: nothing measurable on \(roll.identifier)")
            return
        }
        if !skipped.isEmpty {
            app.reportError("Convert Roll skipped \(skipped.count) frame(s): "
                            + skipped.joined(separator: ", "))
        }

        // Preserve before overwriting — one snapshot per frame, the same
        // mechanism Update Conversion uses.
        for (entry, _) in measured {
            try? app.catalog.saveSnapshot(EditSnapshot(
                entryID: entry.id, name: "Before Roll Conversion",
                editStack: entry.editStack))
        }

        app.updateStacks(Self.conversionStacks(entries: measured.map(\.0),
                                               solution: solution))

        var updated = roll
        updated.conversion = solution.conversion
        do { try app.catalog.saveRoll(updated) } catch {
            app.reportError("Could not store the roll conversion: \(error.localizedDescription)")
        }
        reload()
    }

    /// Pure core of convertRoll, separated for testability: the stacks to
    /// write, one per entry, in entry order. Frames whose baseOrigin is
    /// .sampled keep their own base; everyone shares the roll constants.
    static func conversionStacks(entries: [CatalogEntry],
                                 solution: RollSolution) -> [(CatalogEntry, EditStack)] {
        zip(entries, zip(solution.frameExposures, solution.framePivots)).map {
            entry, solved in
            var stack = entry.editStack
            var film = stack.filmNegative
            film.isEnabled = true
            film.conversionModel = .density
            if film.baseOrigin != .sampled {
                film.baseColor = solution.conversion.baseColor
                film.baseOrigin = solution.conversion.baseOrigin
                film.isBaseSampled = false
            }
            // v2 semantics travel with the solve (see autoConvertNegative):
            // a roll mixing pre-Minilab and fresh frames must render its one
            // set of constants identically on every frame.
            film.print.renderVersion = 2
            film.print.applyToneProfile(solution.conversion.toneProfile)
            film.print.gamma = solution.conversion.gamma
            film.print.dmax = solution.conversion.dmax
            film.print.castRed = solution.conversion.castRed
            film.print.castGreen = solution.conversion.castGreen
            film.print.castBlue = solution.conversion.castBlue
            film.print.exposure = solved.0
            film.print.gradePivot = solved.1
            film.exposure = 0
            stack.filmNegative = film
            return (entry, stack)
        }
    }
}
