import XCTest
@testable import SketchCore

final class DXFFormatTests: XCTestCase {
    private func file(_ body: String, units: Int = 4) -> String {
        "0\nSECTION\n2\nHEADER\n9\n$INSUNITS\n70\n\(units)\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n" + body + "0\nENDSEC\n0\nEOF\n"
    }
    func testLineHonorsUnitsAndYUpConversion() throws {
        let model = try ModelDocument.importDXF(file("0\nLINE\n10\n25.4\n20\n50.8\n30\n76.2\n11\n50.8\n21\n76.2\n31\n101.6\n"), name: "line")
        let e = try XCTUnwrap(model.entities.first)
        XCTAssertEqual(e.origin, Vec3(0.0254, 0.0762, -0.0508))
        XCTAssertEqual(e.width, 0.0254, accuracy: 1e-10)
        XCTAssertEqual(e.height, 0.0254, accuracy: 1e-10)
        XCTAssertEqual(e.depth, -0.0254, accuracy: 1e-10)
    }
    func testOverrideUnitsAndInches() throws {
        let fixture = file("0\nCIRCLE\n10\n1\n20\n2\n40\n3\n", units: 1)
        let inches = try ModelDocument.importDXF(fixture, name: "circle")
        XCTAssertEqual(inches.entities[0].width, 0.1524, accuracy: 1e-10)
        let meters = try ModelDocument.importDXF(fixture, name: "circle", metersPerUnit: 1)
        XCTAssertEqual(meters.entities[0].width, 6)
    }
    func testClosedLWPolylineAndLegacyPolyline() throws {
        let lw = "0\nLWPOLYLINE\n90\n3\n70\n1\n10\n0\n20\n0\n10\n1000\n20\n0\n10\n0\n20\n1000\n"
        let legacy = "0\nPOLYLINE\n70\n1\n0\nVERTEX\n10\n0\n20\n0\n0\nVERTEX\n10\n1000\n20\n0\n0\nVERTEX\n10\n0\n20\n1000\n0\nSEQEND\n"
        for fixture in [lw, legacy] {
            let e = try ModelDocument.importDXF(file(fixture), name: "path").entities[0]
            XCTAssertEqual(e.kind, .mesh)
            XCTAssertEqual(e.mesh?.vertices.count, 3)
            XCTAssertEqual(e.mesh?.lineIndices, [0, 1, 1, 2, 2, 0])
        }
    }
    func testArcAndBulgeAreTessellated() throws {
        let arc = try ModelDocument.importDXF(file("0\nARC\n10\n0\n20\n0\n40\n1000\n50\n0\n51\n90\n"), name: "arc")
        XCTAssertGreaterThan(arc.entities[0].mesh?.vertices.count ?? 0, 10)
        XCTAssertEqual(arc.entities[0].mesh?.vertices.first?.x ?? -1, 1, accuracy: 1e-8)
        XCTAssertEqual(arc.entities[0].mesh?.vertices.last?.z ?? 0, -1, accuracy: 1e-8)
        let bulge = "0\nLWPOLYLINE\n90\n2\n10\n0\n20\n0\n42\n1\n10\n2000\n20\n0\n"
        let curve = try ModelDocument.importDXF(file(bulge), name: "bulge")
        XCTAssertGreaterThan(curve.entities[0].mesh?.vertices.count ?? 0, 10)
        XCTAssertEqual(curve.entities[0].mesh?.vertices.last?.x ?? -1, 2, accuracy: 1e-8)
    }
    func testRectangleRotationAndCircleRoundTripProfiles() throws {
        let original = ModelDocument(entities: [SketchEntity(name: "rotated", kind: .rectangle, origin: Vec3(1, 8, 2), width: 2, depth: 4, height: 5, rotation: .pi / 2), SketchEntity(name: "circle", kind: .circle, origin: Vec3(8, 2, 9), width: 2, depth: 2)])
        let output = try original.dxfString()
        XCTAssertTrue(output.contains("$INSUNITS\n70\n4"))
        XCTAssertTrue(output.contains("100\nAcDbEntity\n"))
        XCTAssertTrue(output.contains("100\nAcDbPolyline\n"))
        XCTAssertTrue(output.contains("100\nAcDbCircle\n"))
        let roundTrip = try ModelDocument.importDXF(output, name: "roundtrip")
        XCTAssertEqual(roundTrip.entities.count, 2)
        let points = try XCTUnwrap(roundTrip.entities[0].mesh?.vertices)
        XCTAssertEqual(points.map(\.x).min() ?? 0, -1, accuracy: 1e-8)
        XCTAssertEqual(points.map(\.x).max() ?? 0, 3, accuracy: 1e-8)
        XCTAssertEqual(points.map(\.z).min() ?? 0, 1, accuracy: 1e-8)
        XCTAssertEqual(roundTrip.entities[1].width, 2, accuracy: 1e-8)
        XCTAssertEqual(roundTrip.entities[1].origin.y, 0)
    }
    func testRejectsUnsupportedAndMalformedRatherThanDropping() {
        for fixture in ["0\nINSERT\n2\nblock\n", "0\nLINE\n10\nnan\n20\n0\n11\n1\n21\n1\n", "0\nLWPOLYLINE\n90\n2\n10\n0\n", "0\nCIRCLE\n10\n0\n20\n0\n40\n-1\n"] {
            XCTAssertThrowsError(try ModelDocument.importDXF(file(fixture), name: "bad"))
        }
        XCTAssertThrowsError(try ModelDocument.importDXF("not a dxf", name: "bad"))
        XCTAssertThrowsError(try ModelDocument.importDXF(file("", units: 999), name: "bad"))
    }
    func testLegacyElevationAndRedundantClosure() throws {
        let legacy = "0\nPOLYLINE\n70\n1\n30\n500\n0\nVERTEX\n10\n0\n20\n0\n30\n0\n0\nVERTEX\n10\n1000\n20\n0\n30\n0\n0\nVERTEX\n10\n0\n20\n1000\n30\n0\n0\nVERTEX\n10\n0\n20\n0\n30\n0\n0\nSEQEND\n"
        let result = try ModelDocument.importDXF(file(legacy), name: "elevated")
        XCTAssertEqual(result.entities[0].mesh?.vertices.count, 3)
        XCTAssertTrue(result.entities[0].mesh?.vertices.allSatisfy({ $0.y == 0.5 }) ?? false)
    }
    func testAsymmetricProfileUsesSameHandednessAsZUpModels() throws {
        let e = SketchEntity(name: "Asymmetric line", kind: .line, origin: Vec3(1,0,2), width: 3, depth: 5)
        let text = try ModelDocument(entities: [e]).dxfString()
        XCTAssertTrue(text.contains("20\n-2000.000000000\n"))
        XCTAssertTrue(text.contains("21\n-7000.000000000\n"))
        XCTAssertTrue(text.contains("100\nAcDbLine\n"))
        let imported = try ModelDocument.importDXF(text, name: "oriented").entities[0]
        XCTAssertEqual(imported.origin, e.origin)
        XCTAssertEqual(imported.depth, e.depth)
    }
    func testExtremeArcAnglesDoNotTrap() {
        XCTAssertThrowsError(try ModelDocument.importDXF(file("0\nARC\n10\n0\n20\n0\n40\n1000\n50\n1e308\n51\n90\n"), name: "bad"))
    }
    func testSurfaceMeshExportRejectsAmbiguousProjectedCutPaths() throws {
        let mesh = MeshData(vertices: [Vec3(0,0,0),Vec3(1,0,0),Vec3(0,0,1)], triangles: [0,1,2])
        let document = ModelDocument(entities: [SketchEntity(kind: .mesh, origin: Vec3(0,0,0), width: 1, depth: 1, mesh: mesh)])
        XCTAssertThrowsError(try document.dxfString())
    }
}
