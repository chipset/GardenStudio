import XCTest
@testable import SketchCore

final class ProfileDXFTests: XCTestCase {
    func testExtrudedPolygonExportsOutlineAndHoleWithoutTriangleEdges() throws {
        let face = try GeometryTools.face(points:[Vec3(0,0,0),Vec3(0,0,2),Vec3(3,0,2),Vec3(3,0,0)],holes:[[Vec3(1,0,0.5),Vec3(2,0,0.5),Vec3(2,0,1.5),Vec3(1,0,1.5)]])
        let solid = try GeometryTools.extrude(entity:face,distance:0.02)
        let text = try ModelDocument(entities:[solid]).dxfString()
        let imported = try ModelDocument.importDXF(text,name:"profiles")
        XCTAssertEqual(imported.entities.count,2)
        XCTAssertEqual(imported.entities[0].mesh?.lineIndices.count,8)
        XCTAssertEqual(imported.entities[1].mesh?.lineIndices.count,8)
        XCTAssertEqual(imported.entities[0].width,3,accuracy:1e-7)
        XCTAssertEqual(imported.entities[0].depth,2,accuracy:1e-7)
    }
    func testEdgeOnProfileFailsRatherThanExportingCollapsedCutPath() throws {
        let face=try GeometryTools.face(points:[Vec3(0,0,0),Vec3(1,0,0),Vec3(1,1,0),Vec3(0,1,0)])
        XCTAssertThrowsError(try ModelDocument(entities:[face]).dxfString())
    }
}
