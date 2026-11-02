import XCTest
import GardenStudioCore
@testable import GardenStudioIO

final class BrandCompatibilityTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testLegacyProjectJSONStillDecodes() throws {
        let json = ##"{"name":"Existing project","entities":[{"id":"51A75C5D-16CD-44F3-BDA1-DF24C2C7E5EA","kind":"rectangle","name":"Site","origin":{"x":0,"y":0,"z":0},"width":13,"depth":11,"height":0.12,"rotation":0,"colorHex":"#A9B59A"}]}"##
        let document = try JSONDecoder().decode(ModelDocument.self, from: Data(json.utf8))
        try document.validate()
        XCTAssertEqual(document.entities.first?.width, 13)
        XCTAssertEqual(document.name, "Existing project")
    }

    func testLegacySVGOriginMetadataStillImports() throws {
        let url = try folder().appendingPathComponent("legacy.svg")
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='1000mm' height='1000mm' viewBox='0 0 1 1' data-sketchmake-origin-x='-2' data-sketchmake-origin-y='3'><path d='M0 0 L1 0 L0 1 Z'/></svg>"
        try svg.write(to: url, atomically: true, encoding: .utf8)
        let paths = try VectorProfiles.paths(document: SVGFormat.read(url: url))
        XCTAssertEqual(paths[0].points[0].x, -2, accuracy: 1e-9)
        XCTAssertEqual(paths[0].points[0].y, 3, accuracy: 1e-9)
    }

    func testNewSVGExportsUseGardenStudioMetadata() throws {
        let document = try VectorProfiles.document(paths: [VectorPath(points: [VectorPoint(x: -2, y: 3), VectorPoint(x: -1, y: 3), VectorPoint(x: -2, y: 4)], closed: true)], name: "Garden")
        let url = try folder().appendingPathComponent("garden.svg")
        try SVGFormat.write(document, to: url)
        let text = try String(contentsOf: url)
        XCTAssertTrue(text.contains("data-gardenstudio-origin-x"))
        XCTAssertFalse(text.contains("sketchmake"))
    }

    func testLegacyOBJFallbackColorStillImports() throws {
        let directory = try folder()
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try png.write(to: directory.appendingPathComponent("paint.png"))
        try "newmtl paint\n# SketchMakeFallbackColor #AA3300\nKd 1 1 1\nmap_Kd paint.png\n".write(to: directory.appendingPathComponent("paint.mtl"), atomically: true, encoding: .utf8)
        let url = directory.appendingPathComponent("legacy.obj")
        try "mtllib paint.mtl\nv 0 0 0\nv 1 0 0\nv 0 0 1\nusemtl paint\nf 1 2 3\n".write(to: url, atomically: true, encoding: .utf8)
        let document = try OBJFormat.read(url: url)
        XCTAssertEqual(document.entities[0].surface?.faceOverrides.first?.colorHex, "#AA3300")
    }
}
