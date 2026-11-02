import XCTest
@testable import GardenStudioIO

final class SVGArcNumericAuditTests:XCTestCase {
    func testTinyFiniteRadiiAreScaledWithoutTrapping() throws {
        // SVG scales undersized radii to reach the endpoints. The resulting arc
        // is ordinary-sized even though the authored radii are extremely small.
        let paths=try vectorPath("M0 0 A1e-200 1e-200 0 0 1 1 1")
        XCTAssertEqual(paths.count,1)
        XCTAssertGreaterThan(paths[0].points.count,2)
        XCTAssertTrue(paths[0].points.allSatisfy{$0.x.isFinite && $0.y.isFinite})
        XCTAssertEqual(paths[0].points.last?.x,1)
        XCTAssertEqual(paths[0].points.last?.y,1)
    }
    func testUnrepresentableRadiusRatioRejectsInsteadOfTrapping() throws {
        XCTAssertThrowsError(try vectorPath("M0 0 A1e-320 1e-320 0 0 1 1 1"))
    }
    func testOrdinaryArcRetainsItsExpectedEndpoints() throws {
        let path=try XCTUnwrap(vectorPath("M0 0 A1 1 0 0 1 1 1").first)
        XCTAssertEqual(path.points.first?.x,0)
        XCTAssertEqual(path.points.first?.y,0)
        XCTAssertEqual(path.points.last?.x,1)
        XCTAssertEqual(path.points.last?.y,1)
        XCTAssertTrue(path.points.allSatisfy{$0.x>=0 && $0.y>=0 && $0.x<=1.000000001 && $0.y<=1.000000001})
    }
}
