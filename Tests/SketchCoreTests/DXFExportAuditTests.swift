import XCTest
@testable import SketchCore

final class DXFExportAuditTests:XCTestCase {
    func testProfileExportChecksActualMillimeterCoordinatesAfterTransform() throws {
        let beyond=SketchEntity(name:"Far wire",kind:.line,origin:Vec3(2e9,0,0),width:1,depth:0)
        try ModelDocument(entities:[beyond]).validate()
        XCTAssertThrowsError(try ModelDocument(entities:[beyond]).dxfString())
        let rotated=SketchEntity(name:"Rotated wire",kind:.line,origin:Vec3(0,0,0),width:1.1e9,depth:0,rotation:0.1)
        XCTAssertThrowsError(try ModelDocument(entities:[rotated]).dxfString())
        let near=SketchEntity(name:"Within range",kind:.line,origin:Vec3(1e8,0,0),width:1,depth:0)
        let exported=try ModelDocument(entities:[near]).dxfString()
        let imported=try ModelDocument.importDXF(exported,name:"Valid range")
        XCTAssertEqual(try imported.entities[0].triangulatedMesh().vertices.first?.x,near.origin.x)
    }
    func testProfileWireExportCannotExceedItsReadersObjectLimit() throws {
        let mesh=MeshData(vertices:[Vec3(0,0,0),Vec3(1,0,0)],lineIndices:Array(repeating:[0,1],count:50_001).flatMap{$0})
        let entity=SketchEntity(name:"Dense wire",kind:.mesh,origin:Vec3(0,0,0),width:1,depth:0,mesh:mesh)
        let source=ModelDocument(entities:[entity])
        try source.validate()
        XCTAssertThrowsError(try source.dxfString())
    }
    func testThreeDExportCannotExceedItsReadersObjectLimit() throws {
        let mesh=MeshData(vertices:[Vec3(0,0,0),Vec3(1,0,0),Vec3(0,1,0)],triangles:Array(repeating:[0,1,2],count:50_001).flatMap{$0})
        let entity=SketchEntity(name:"Dense single mesh",kind:.mesh,origin:Vec3(0,0,0),width:1,depth:0,height:1,mesh:mesh)
        let source=ModelDocument(entities:[entity])
        try source.validate()
        XCTAssertThrowsError(try source.dxf3DString())
    }
}
