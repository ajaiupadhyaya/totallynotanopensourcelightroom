import CoreGraphics
import Foundation
import XCTest
@testable import PhotoEditor

/// The point-list model: pure editing operations plus the decode contract
/// that keeps every existing photo rendering unchanged.
final class CurvePointModelTests: XCTestCase {
    func testSeedingAnEmptyListYieldsTheFiveIdentityPoints() {
        XCTAssertEqual(CurvePointModel.seeded([]), CurvePointModel.identity)
        let custom = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
        XCTAssertEqual(CurvePointModel.seeded(custom), custom, "non-empty lists pass through")
    }

    func testAddingInsertsSortedByX() {
        let (points, index) = CurvePointModel.adding(CGPoint(x: 0.6, y: 0.4),
                                                     to: CurvePointModel.identity)
        XCTAssertEqual(points.count, 6)
        XCTAssertEqual(index, 3, "between 0.5 and 0.75")
        XCTAssertEqual(points.map(\.x), points.map(\.x).sorted(), "sorted invariant holds")
    }

    /// A click on top of an existing point must grab it, not stack a twin at
    /// the same x — twins make the interpolation vertical.
    func testAddingOnTopOfAPointReturnsThatPointInstead() {
        let (points, index) = CurvePointModel.adding(CGPoint(x: 0.505, y: 0.9),
                                                     to: CurvePointModel.identity)
        XCTAssertEqual(points.count, 5)
        XCTAssertEqual(index, 2)
    }

    func testMovingClampsBetweenNeighboursAndTheUnitSquare() {
        let moved = CurvePointModel.moving(index: 2, to: CGPoint(x: 0.9, y: 1.4),
                                           in: CurvePointModel.identity)
        XCTAssertLessThan(moved[2].x, moved[3].x, "cannot cross the next point")
        XCTAssertEqual(moved[2].y, 1.0, "y clamps to the unit square")
        XCTAssertEqual(moved.map(\.x), moved.map(\.x).sorted())
    }

    func testRemovingKeepsAtLeastTwoPoints() {
        var points: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.7), CGPoint(x: 1, y: 1)]
        points = CurvePointModel.removing(index: 1, from: points)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(CurvePointModel.removing(index: 0, from: points).count, 2,
                       "a curve needs two ends; the double-click reset clears the rest")
    }

    // MARK: The storage contract

    func testAbsentKeyDecodesToTodaysEmptyList() throws {
        let decoded = try JSONDecoder().decode(EditStack.self,
                                               from: Data("{}".utf8))
        XCTAssertEqual(decoded.toneCurvePoints, [], "absent → identity, exactly as today")
    }

    func testFivePointListsRoundTripBitExactly() throws {
        var stack = EditStack()
        stack.toneCurvePoints = [CGPoint(x: 0, y: 0.03), CGPoint(x: 0.25, y: 0.2),
                                 CGPoint(x: 0.5, y: 0.55), CGPoint(x: 0.75, y: 0.8),
                                 CGPoint(x: 1, y: 1)]
        let decoded = try JSONDecoder().decode(EditStack.self,
                                               from: JSONEncoder().encode(stack))
        XCTAssertEqual(decoded.toneCurvePoints, stack.toneCurvePoints)
    }

    func testSevenPointListsRoundTripToo() throws {
        var stack = EditStack()
        stack.toneCurvePoints = (0...6).map { CGPoint(x: Double($0) / 6, y: Double($0) / 6) }
        let decoded = try JSONDecoder().decode(EditStack.self,
                                               from: JSONEncoder().encode(stack))
        XCTAssertEqual(decoded.toneCurvePoints.count, 7)
    }
}
