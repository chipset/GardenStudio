import XCTest
@testable import SketchCore

final class GeometryPlacementAuditTests:XCTestCase {
    func testStraightSweepPreservesTheStartingProfilePosition() throws {
        let outline=[Vec3(1,2,0),Vec3(3,2,0),Vec3(3,4,0),Vec3(1,4,0)]
        let profile=try GeometryTools.face(points:outline)
        let swept=try GeometryTools.sweep(profile:profile,path:[Vec3(0,0,0),Vec3(0,0,5)])
        let vertices=try swept.triangulatedMesh().vertices
        for point in outline {
            XCTAssertTrue(vertices.contains{close($0,point)},"The starting face moved away from its source")
            XCTAssertTrue(vertices.contains{close($0,Vec3(point.x,point.y,5))})
        }
        XCTAssertEqual(vertices.map(\.x).min()!,1,accuracy:1e-9)
        XCTAssertEqual(vertices.map(\.y).min()!,2,accuracy:1e-9)
    }
    func testSweepRejectsAPathStartingOutsideTheProfilePlane() throws {
        let profile=try GeometryTools.face(points:[Vec3(-1,-1,2),Vec3(1,-1,2),Vec3(1,1,2),Vec3(-1,1,2)])
        XCTAssertThrowsError(try GeometryTools.sweep(profile:profile,path:[Vec3(0,0,0),Vec3(0,0,5)]))
    }
    func testTransformedSweepRetainsOffCenterHoleAndReverseDirection() throws {
        var face=try GeometryTools.face(points:[Vec3(1,2,0),Vec3(5,2,0),Vec3(5,6,0),Vec3(1,6,0)],holes:[[Vec3(2,3,0),Vec3(4,3,0),Vec3(4,5,0),Vec3(2,5,0)]])
        face.origin=Vec3(10,4,-3);face.rotation = .pi/2
        let outline=try GeometryTools.worldProfile(of:face)
        let swept=try GeometryTools.sweep(profile:face,path:[Vec3(10,4,-3),Vec3(5,4,-3)])
        let vertices=try swept.triangulatedMesh().vertices
        for point in outline.outer+outline.holes.flatMap({$0}) {
            XCTAssertTrue(vertices.contains{close($0,point)})
            XCTAssertTrue(vertices.contains{close($0,Vec3(point.x-5,point.y,point.z))})
        }
    }
    private func close(_ a:Vec3,_ b:Vec3)->Bool {abs(a.x-b.x)<1e-8 && abs(a.y-b.y)<1e-8 && abs(a.z-b.z)<1e-8}
}
