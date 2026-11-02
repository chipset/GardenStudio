import Foundation
import XCTest
import SketchCore
@testable import SketchIO

final class TextGeometryTests: XCTestCase {
    func testTextIsExportableSolidMeshAtRequestedSizeAndOrigin() throws {
        let entity = try TextGeometry.make(text: "Make", height: 0.1, depth: 0.02, origin: Vec3(1, 2, 3), colorHex: "#2879DF")
        let local = try XCTUnwrap(entity.mesh)
        XCTAssertEqual(entity.kind, .mesh)
        XCTAssertFalse(local.triangles.isEmpty)
        XCTAssertGreaterThan(local.vertices.count, 20)
        XCTAssertEqual(entity.height, 0.1, accuracy: 1e-6)
        XCTAssertEqual(entity.depth, 0.02, accuracy: 1e-6)
        XCTAssertEqual(local.vertices.map(\.y).min()!, 0, accuracy: 1e-6)
        XCTAssertEqual(local.vertices.map(\.y).max()!, 0.1, accuracy: 1e-6)
        XCTAssertEqual(local.vertices.map(\.z).min()!, 0, accuracy: 1e-6)
        XCTAssertEqual(local.vertices.map(\.z).max()!, 0.02, accuracy: 1e-6)
        let world = try entity.triangulatedMesh()
        XCTAssertEqual(world.vertices.map(\.x).min()!, 1, accuracy: 1e-6)
        XCTAssertEqual(world.vertices.map(\.y).min()!, 2, accuracy: 1e-6)
        XCTAssertEqual(world.vertices.map(\.z).max()!, 3.02, accuracy: 1e-6)
        let document = ModelDocument(entities: [entity])
        XCTAssertNoThrow(try document.validate())
        let stl = try document.stlData()
        XCTAssertEqual(stl.count, 84 + local.triangles.count / 3 * 50)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("text-\(UUID().uuidString).dae")
        defer { try? FileManager.default.removeItem(at: url) }
        try ColladaFormat.write(document, to: url)
        let imported = try ColladaFormat.read(url: url)
        XCTAssertEqual(imported.entities.compactMap(\.mesh).reduce(0) { $0 + $1.triangles.count }, local.triangles.count)
    }
    func testGlyphCounterRemainsOpenInsteadOfBeingFilledByBoundingBox() throws {
        let entity = try TextGeometry.make(text: "O", height: 0.1, depth: 0.01, origin: Vec3(0, 0, 0))
        let mesh = try XCTUnwrap(entity.mesh)
        let x = entity.width / 2, y = entity.height / 2
        func contains2D(_ p:Vec3,_ a:Vec3,_ b:Vec3,_ c:Vec3)->Bool {
            func sign(_ p:Vec3,_ a:Vec3,_ b:Vec3)->Double { (p.x-b.x)*(a.y-b.y)-(a.x-b.x)*(p.y-b.y) }
            let s=[sign(p,a,b),sign(p,b,c),sign(p,c,a)]
            return !(s.contains{$0 < -1e-10} && s.contains{$0 > 1e-10})
        }
        var caps = 0
        for i in stride(from: 0, to: mesh.triangles.count, by: 3) {
            let a=mesh.vertices[mesh.triangles[i]],b=mesh.vertices[mesh.triangles[i+1]],c=mesh.vertices[mesh.triangles[i+2]]
            if abs(a.z-b.z)<1e-8 && abs(b.z-c.z)<1e-8 {
                caps += 1
                XCTAssertFalse(contains2D(Vec3(x,y,a.z),a,b,c), "O's center must remain empty on both caps")
            }
        }
        XCTAssertGreaterThan(caps, 10)
    }
    func testWhitespaceInvalidDimensionsAndOversizeTextRejected() {
        XCTAssertThrowsError(try TextGeometry.make(text: " \n\t ", height: 0.1, depth: 0.01, origin: Vec3(0,0,0)))
        XCTAssertThrowsError(try TextGeometry.make(text: "A", height: 0, depth: 0.01, origin: Vec3(0,0,0)))
        XCTAssertThrowsError(try TextGeometry.make(text: "A", height: 0.1, depth: -.infinity, origin: Vec3(0,0,0)))
        XCTAssertThrowsError(try TextGeometry.make(text: String(repeating:"A",count:2001), height: 0.1, depth: 0.01, origin: Vec3(0,0,0)))
        XCTAssertThrowsError(try TextGeometry.make(text: "A", height: 0.1, depth: 0.01, origin: Vec3(.nan,0,0)))
    }
}
