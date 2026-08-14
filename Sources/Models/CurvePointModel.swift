import CoreGraphics

/// Pure editing operations on a tone-curve point list. The invariants every
/// caller relies on: sorted ascending by x, x and y inside the unit square,
/// no two points closer in x than `minimumSeparation`, never fewer than two
/// points once a list exists. `[]` remains the identity sentinel — the value
/// the double-click reset writes and absent storage decodes to.
enum CurvePointModel {
    /// The five identity points — the seed for first contact with an
    /// untouched curve, and exactly the columns today's editor shows.
    static let identity: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.5, y: 0.5),
        CGPoint(x: 0.75, y: 0.75), CGPoint(x: 1, y: 1),
    ]

    /// Closest two points may sit in x. Below this the spline turns vertical
    /// and the two pucks become one target.
    static let minimumSeparation: CGFloat = 0.02

    static func seeded(_ points: [CGPoint]) -> [CGPoint] {
        points.isEmpty ? identity : points
    }

    /// Inserts a point sorted by x — or, when one already lives within
    /// `minimumSeparation`, returns that point's index instead of stacking a
    /// twin. The returned index is the one to drag.
    static func adding(_ point: CGPoint, to points: [CGPoint]) -> (points: [CGPoint], index: Int) {
        let clamped = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        var list = seeded(points)
        if let existing = list.firstIndex(where: { abs($0.x - clamped.x) < minimumSeparation }) {
            return (list, existing)
        }
        let index = list.firstIndex { $0.x > clamped.x } ?? list.count
        list.insert(clamped, at: index)
        return (list, index)
    }

    /// Moves a point in both axes, clamped to the unit square and pinned
    /// between its neighbours so the list stays sorted.
    static func moving(index: Int, to point: CGPoint, in points: [CGPoint]) -> [CGPoint] {
        var list = seeded(points)
        guard list.indices.contains(index) else { return list }
        let lower = index > 0 ? list[index - 1].x + minimumSeparation : 0
        let upper = index < list.count - 1 ? list[index + 1].x - minimumSeparation : 1
        list[index] = CGPoint(x: min(max(point.x, lower), max(upper, lower)),
                              y: min(max(point.y, 0), 1))
        return list
    }

    /// Removes a point while more than two remain — a curve needs its ends;
    /// clearing the rest is the double-click reset's job.
    static func removing(index: Int, from points: [CGPoint]) -> [CGPoint] {
        var list = seeded(points)
        guard list.count > 2, list.indices.contains(index) else { return list }
        list.remove(at: index)
        return list
    }
}
