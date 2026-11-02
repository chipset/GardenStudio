import XCTest
import SketchCore
@testable import SketchIO

final class ColladaFormatTests: XCTestCase {
    private func temporaryURL(_ suffix: String = "dae") -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("sketchmake-\(UUID().uuidString).\(suffix)") }
    private func fixture(unit: String = "1", axis: String = "Y_UP", transform: String = "", material: Bool = false) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">
        <asset><created>2026-01-01T00:00:00Z</created><modified>2026-01-01T00:00:00Z</modified><unit meter="\(unit)" name="unit"/><up_axis>\(axis)</up_axis></asset>
        \(material ? "<library_effects><effect id=\"red-fx\"><profile_COMMON><technique sid=\"common\"><lambert><diffuse><color>1 0.25 0 1</color></diffuse></lambert></technique></profile_COMMON></effect></library_effects><library_materials><material id=\"red\"><instance_effect url=\"#red-fx\"/></material></library_materials>" : "")
        <library_geometries><geometry id="shape" name="Triangle"><mesh>
        <source id="positions"><float_array id="positions-array" count="9">0 0 0 100 0 0 0 100 0</float_array><technique_common><accessor source="#positions-array" count="3" stride="3"><param name="X" type="float"/><param name="Y" type="float"/><param name="Z" type="float"/></accessor></technique_common></source>
        <vertices id="vertices"><input semantic="POSITION" source="#positions"/></vertices>
        <triangles count="1"\(material ? " material=\"surface\"" : "")><input semantic="VERTEX" source="#vertices" offset="0"/><p>0 1 2</p></triangles>
        </mesh></geometry></library_geometries>
        <library_visual_scenes><visual_scene id="scene"><node id="node" name="Test triangle">\(transform)<instance_geometry url="#shape">\(material ? "<bind_material><technique_common><instance_material symbol=\"surface\" target=\"#red\"/></technique_common></bind_material>" : "")</instance_geometry></node></visual_scene></library_visual_scenes>
        <scene><instance_visual_scene url="#scene"/></scene></COLLADA>
        """
    }
    private func read(_ xml: String) throws -> ModelDocument { let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }; try xml.write(to: url, atomically: true, encoding: .utf8); return try ColladaFormat.read(url: url) }

    func testCentimeterZUpTranslationNormalizesToMetersAndYUp() throws {
        let document = try read(fixture(unit: "0.01", axis: "Z_UP", transform: "<translate>200 300 400</translate>"))
        XCTAssertEqual(document.entities.count, 1)
        let vertices = try XCTUnwrap(document.entities.first?.mesh).vertices
        XCTAssertEqual(vertices.count, 3)
        // Z-up → Y-up is (x,z,-y), including node translations, then cm → m.
        let first = vertices[0]
        XCTAssertEqual(first.x, 2, accuracy: 0.0001)
        XCTAssertEqual(first.y, 4, accuracy: 0.0001)
        XCTAssertEqual(first.z, -3, accuracy: 0.0001)
        XCTAssertEqual(vertices[1].x, 3, accuracy: 0.0001)
        XCTAssertEqual(vertices[2].z, -4, accuracy: 0.0001)
    }
    func testBasicDiffuseColorPreserved() throws {
        let document = try read(fixture(material: true))
        XCTAssertEqual(document.entities.first?.colorHex, "#FF4000")
    }
    func testBoxAndLineRoundTripPreservesWorldBoundsAndLineSegments() throws {
        let box = SketchEntity(name: "Box & <part>", kind: .rectangle, origin: Vec3(2, 1, -3), width: 2, depth: 4, height: 3, colorHex: "#7FABB5", rotation: .pi / 2)
        let line = SketchEntity(name: "Guide", kind: .line, origin: Vec3(-2, 0, 1), width: 3, depth: -4, height: 2)
        let source = ModelDocument(entities: [box, line], name: "Round trip")
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        try ColladaFormat.write(source, to: url)
        let xml = try String(contentsOf: url)
        XCTAssertTrue(xml.contains("Y_UP")); XCTAssertTrue(xml.contains("meter=\"1\"")); XCTAssertTrue(xml.contains("Box &amp; &lt;part&gt;"))
        let result = try ColladaFormat.read(url: url)
        XCTAssertEqual(result.entities.count, 2)
        let triangles = result.entities.compactMap(\.mesh).reduce(0) { $0 + $1.triangles.count / 3 }
        let lines = result.entities.compactMap(\.mesh).reduce(0) { $0 + $1.lineIndices.count / 2 }
        XCTAssertEqual(triangles, 12); XCTAssertEqual(lines, 1)
        let boxMesh = try XCTUnwrap(result.entities.first?.mesh)
        XCTAssertEqual(boxMesh.vertices.map(\.x).min()!, 0, accuracy: 0.0001)
        XCTAssertEqual(boxMesh.vertices.map(\.x).max()!, 4, accuracy: 0.0001)
        XCTAssertEqual(boxMesh.vertices.map(\.y).max()!, 4, accuracy: 0.0001)
    }
    func testExternalGeometryReferenceRejectedBeforeSceneKitLoad() throws {
        let xml = fixture().replacingOccurrences(of: "url=\"#shape\"", with: "url=\"https://example.com/model.dae#shape\"")
        XCTAssertThrowsError(try read(xml))
    }
    func testMalformedOrEmptyDocumentRejected() throws {
        XCTAssertThrowsError(try read("<COLLADA><broken>"))
        XCTAssertThrowsError(try read("<COLLADA xmlns=\"http://www.collada.org/2005/11/COLLADASchema\" version=\"1.4.1\"><asset/><scene/></COLLADA>"))
    }
    func testImageTexturesAreExplicitlyRejected() throws {
        let xml = fixture().replacingOccurrences(of: "<library_geometries>", with: "<library_images><image id=\"texture\"><init_from>wall.png</init_from></image></library_images><library_geometries>")
        XCTAssertThrowsError(try read(xml))
    }
    func testRelativeExternalSourceIsRejectedByPreflight() throws {
        let xml = fixture().replacingOccurrences(of: "url=\"#shape\"", with: "url=\"other.xml#shape\"")
        XCTAssertThrowsError(try read(xml)) { error in
            XCTAssertTrue(error.localizedDescription.contains("External COLLADA"))
        }
    }
    func testMirroredTransformKeepsTriangleWinding() throws {
        let document = try read(fixture(transform: "<scale>-2 3 1</scale>"))
        let mesh = try XCTUnwrap(document.entities.first?.mesh)
        let a = mesh.vertices[mesh.triangles[0]], b = mesh.vertices[mesh.triangles[1]], c = mesh.vertices[mesh.triangles[2]]
        let normalZ = (b.x-a.x)*(c.y-a.y) - (b.y-a.y)*(c.x-a.x)
        XCTAssertGreaterThan(normalZ, 0)
        XCTAssertEqual(mesh.vertices.map(\.x).min()!, -200, accuracy: 0.0001)
        XCTAssertEqual(mesh.vertices.map(\.y).max()!, 300, accuracy: 0.0001)
    }
    func testInvalidDeclaredUnitRejected() throws {
        XCTAssertThrowsError(try read(fixture(unit: "-1")))
    }

}
