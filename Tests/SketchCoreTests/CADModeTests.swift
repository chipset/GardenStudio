import XCTest
@testable import SketchCore

final class CADModeTests: XCTestCase {
    private func drawing(_ entities: String) -> String { "0\nSECTION\n2\nENTITIES\n" + entities + "0\nENDSEC\n0\nEOF\n" }
    private func sample() -> ModelDocument {
        ModelDocument(entities: [SketchEntity(name: "Face", kind: .mesh, origin: Vec3(0,0,0), width: 2, depth: 4, height: 3, mesh: MeshData(vertices: [Vec3(1,2,3),Vec3(3,2,3),Vec3(1,5,7)], triangles: [0,1,2]))])
    }
    func testThreeDFaceImportPreservesCoordinatesAndWinding() throws {
        let text = drawing("0\n3DFACE\n10\n1000\n20\n-3000\n30\n2000\n11\n3000\n21\n-3000\n31\n2000\n12\n1000\n22\n-7000\n32\n5000\n13\n1000\n23\n-7000\n33\n5000\n")
        let mesh = try XCTUnwrap(ModelDocument.importDXF(text, name: "Face").entities.first?.mesh)
        XCTAssertEqual(mesh.vertices, [Vec3(1,2,3),Vec3(3,2,3),Vec3(1,5,7)])
        XCTAssertEqual(mesh.triangles, [0,1,2])
    }
    func testPolyfaceAndThreeDPolylineImport() throws {
        let polyface = "0\nPOLYLINE\n70\n64\n0\nVERTEX\n70\n192\n10\n0\n20\n0\n30\n0\n0\nVERTEX\n70\n192\n10\n1000\n20\n0\n30\n0\n0\nVERTEX\n70\n192\n10\n0\n20\n1000\n30\n1000\n0\nVERTEX\n70\n128\n71\n1\n72\n-2\n73\n3\n0\nSEQEND\n"
        let mesh = try XCTUnwrap(ModelDocument.importDXF(drawing(polyface), name: "Polyface").entities.first?.mesh)
        XCTAssertEqual(mesh.triangles, [0,1,2]); XCTAssertEqual(mesh.vertices[2], Vec3(0,1,-1))
        XCTAssertThrowsError(try ModelDocument.importDXF(drawing(polyface.replacingOccurrences(of: "73\n3", with: "73\n4")), name: "Invalid"))
    }
    func testThreeDPolylineRetainsElevationAndVerticalEdges() throws {
        let text = drawing("0\nPOLYLINE\n70\n8\n0\nVERTEX\n70\n32\n10\n0\n20\n0\n30\n0\n0\nVERTEX\n70\n32\n10\n0\n20\n0\n30\n1000\n0\nVERTEX\n70\n32\n10\n1000\n20\n2000\n30\n3000\n0\nSEQEND\n")
        let model = try ModelDocument.importDXF(text,name:"3D wire")
        XCTAssertEqual(model.entities[0].mesh!.vertices,[Vec3(0,0,0),Vec3(0,1,0),Vec3(1,3,-2)])
        let roundtrip = try ModelDocument.importDXF(model.dxf3DString(),name:"Lines")
        XCTAssertEqual(roundtrip.entities.count,2)
        XCTAssertEqual(roundtrip.entities[0].height,1,accuracy:1e-10)
        XCTAssertThrowsError(try model.dxfString())
        XCTAssertThrowsError(try model.stlData(binary:false))
    }
    func testFaceQuadsAndDegenerateRejection() throws {
        let face = "0\n3DFACE\n10\n0\n20\n0\n30\n0\n11\n1000\n21\n0\n31\n0\n12\n1000\n22\n1000\n32\n1000\n13\n0\n23\n1000\n33\n1000\n"
        let model = try ModelDocument.importDXF(drawing(face),name:"Quad")
        XCTAssertEqual(model.entities[0].mesh!.triangles,[0,1,2,0,2,3])
        XCTAssertThrowsError(try ModelDocument.importDXF(drawing(face + "0\nINSERT\n2\nBlock\n"),name:"Partial"))
        var degenerate = sample()
        degenerate.entities[0].mesh!.vertices[2] = Vec3(2,2,3)
        XCTAssertThrowsError(try degenerate.dxf3DString())
        XCTAssertThrowsError(try degenerate.stlData(binary:false))
        XCTAssertThrowsError(try degenerate.stlData(binary:true))
    }
    func testEllipseArcKeepsEndpoints() throws {
        let mesh = try XCTUnwrap(ModelDocument.importDXF(drawing("0\nELLIPSE\n10\n0\n20\n0\n11\n2000\n21\n0\n40\n0.5\n41\n0\n42\n1.5707963267948966\n"),name:"Arc").entities.first?.mesh)
        XCTAssertEqual(mesh.vertices.first!.x,2,accuracy:1e-10); XCTAssertEqual(mesh.vertices.last!.z,-1,accuracy:1e-10)
        XCTAssertEqual(mesh.lineIndices.count, (mesh.vertices.count-1)*2)
    }
    func testRationalSplinePreservesQuarterCircle() throws {
        let spline = "0\nSPLINE\n70\n12\n71\n2\n72\n6\n73\n3\n40\n0\n40\n0\n40\n0\n40\n1\n40\n1\n40\n1\n41\n1\n41\n0.7071067811865476\n41\n1\n10\n1000\n20\n0\n30\n0\n10\n1000\n20\n1000\n30\n0\n10\n0\n20\n1000\n30\n0\n"
        let mesh = try XCTUnwrap(ModelDocument.importDXF(drawing(spline),name:"Spline").entities.first?.mesh)
        let middle = mesh.vertices[mesh.vertices.count/2]
        XCTAssertEqual(middle.x,sqrt(0.5),accuracy:1e-10); XCTAssertEqual(middle.z,-sqrt(0.5),accuracy:1e-10)
        XCTAssertEqual(mesh.vertices.first!,Vec3(1,0,0)); XCTAssertEqual(mesh.vertices.last!,Vec3(0,0,-1))
        XCTAssertThrowsError(try ModelDocument.importDXF(drawing(spline.replacingOccurrences(of:"41\n0.7071067811865476",with:"41\n0")),name:"Invalid"))
    }
    func testExplicitDXFThreeDModeRoundTrips() throws {
        let source = sample()
        let text = try source.dxf3DString()
        XCTAssertTrue(text.contains("3DFACE"))
        let actual = try ModelDocument.importDXF(text,name:"Roundtrip").entities[0].mesh!
        XCTAssertEqual(actual.vertices, source.entities[0].mesh!.vertices)
        XCTAssertThrowsError(try source.dxfString())
    }
    func testSTLAsciiBinaryUnitsAndAxisRoundTrips() throws {
        for binary in [false,true] { for zUp in [false,true] { for unit in [1.0,0.0254,0.001] {
            let data = try sample().stlData(binary:binary,metersPerUnit:unit,zUp:zUp)
            if !binary { XCTAssertTrue(String(data:data,encoding:.utf8)!.hasPrefix("solid")) }
            let mesh = try ModelDocument.importSTL(data,name:"Roundtrip",metersPerUnit:unit,zUp:zUp).entities[0].mesh!
            for (a,b) in zip(mesh.vertices,sample().entities[0].mesh!.vertices) {
                XCTAssertEqual(a.x,b.x,accuracy:1e-5); XCTAssertEqual(a.y,b.y,accuracy:1e-5); XCTAssertEqual(a.z,b.z,accuracy:1e-5)
            }
            XCTAssertEqual(mesh.triangles,[0,1,2])
        } } }
        XCTAssertThrowsError(try sample().stlData(metersPerUnit:0))
    }
}
