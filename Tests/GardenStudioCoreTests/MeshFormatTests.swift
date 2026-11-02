import XCTest
@testable import GardenStudioCore

final class MeshFormatTests: XCTestCase {
    func testBoxHasOutwardWindingAndTransforms() throws {
        let box = GardenEntity(kind: .rectangle, origin: Vec3(5, 2, -3), width: 2, depth: 4, height: 3, rotation: .pi / 2)
        let mesh = try box.triangulatedMesh()
        XCTAssertEqual(mesh.vertices.count, 8)
        XCTAssertEqual(mesh.triangles.count, 36)
        let center = Vec3(5, 3.5, -3)
        for face in stride(from: 0, to: mesh.triangles.count, by: 3) {
            let a = mesh.vertices[mesh.triangles[face]], b = mesh.vertices[mesh.triangles[face+1]], c = mesh.vertices[mesh.triangles[face+2]]
            let normal = cross(subtract(b, a), subtract(c, a))
            let outward = subtract(Vec3((a.x+b.x+c.x)/3, (a.y+b.y+c.y)/3, (a.z+b.z+c.z)/3), center)
            XCTAssertGreaterThan(normal.x*outward.x + normal.y*outward.y + normal.z*outward.z, 0)
        }
    }

    func testCircleHasClosedCapsAndOutwardWinding() throws {
        let entity = GardenEntity(kind: .circle, origin: Vec3(0,0,0), width: 2, depth: 4, height: 3)
        let mesh = try entity.triangulatedMesh()
        XCTAssertEqual(mesh.triangles.count / 3, 188)
        for face in stride(from: 0, to: mesh.triangles.count, by: 3) {
            let a = mesh.vertices[mesh.triangles[face]], b = mesh.vertices[mesh.triangles[face+1]], c = mesh.vertices[mesh.triangles[face+2]]
            let n = cross(subtract(b,a),subtract(c,a))
            let outward = Vec3((a.x+b.x+c.x)/3, (a.y+b.y+c.y)/3 - 1.5, (a.z+b.z+c.z)/3)
            XCTAssertGreaterThan(n.x*outward.x+n.y*outward.y+n.z*outward.z, 0)
        }
    }

    func testBinarySTLRoundTripUsesMillimetersAndZUp() throws {
        let document = ModelDocument(entities: [GardenEntity(kind: .rectangle, origin: Vec3(1,2,3), width: 2, depth: 4, height: 3)])
        let data = try document.stlData()
        XCTAssertEqual(data.count, 84 + 12 * 50)
        let imported = try ModelDocument.importSTL(data, name: "Test")
        try imported.validate()
        let mesh = try XCTUnwrap(imported.entities.first?.mesh)
        XCTAssertEqual(mesh.vertices.map(\.x).min()!, 0, accuracy: 0.000001)
        XCTAssertEqual(mesh.vertices.map(\.y).min()!, 2, accuracy: 0.000001)
        XCTAssertEqual(mesh.vertices.map(\.z).min()!, 1, accuracy: 0.000001)
        XCTAssertEqual(mesh.vertices.map(\.z).max()!, 5, accuracy: 0.000001)
        XCTAssertEqual(mesh.triangles.count, 36)
        let firstZ = readFloat(data, at: 84 + 12 + 8)
        XCTAssertEqual(firstZ, 2000, accuracy: 0.001)
    }

    func testASCIISTLAndScaleOverride() throws {
        let text = """
        solid triangle
        facet normal 0 0 1
        outer loop
        vertex 0 0 2
        vertex 10 0 2
        vertex 0 5 2
        endloop
        endfacet
        endsolid triangle
        """
        let imported = try ModelDocument.importSTL(Data(text.utf8), name: "inch", metersPerUnit: 0.0254)
        let mesh = try XCTUnwrap(imported.entities.first?.mesh)
        XCTAssertEqual(mesh.vertices[1].x, 0.254, accuracy: 0.000001)
        XCTAssertEqual(mesh.vertices[0].y, 0.0508, accuracy: 0.000001)
        XCTAssertEqual(mesh.vertices[2].z, -0.127, accuracy: 0.000001)
    }

    func testBinaryHeaderStartingSolidIsStillBinary() throws {
        let document = ModelDocument(entities: [GardenEntity(kind: .rectangle, origin: Vec3(0,0,0), width: 1, depth: 1, height: 1)])
        var data = try document.stlData()
        data.replaceSubrange(0..<5, with: Data("solid".utf8))
        XCTAssertEqual(try ModelDocument.importSTL(data, name: "binary").entities.first?.mesh?.triangles.count, 36)
    }

    func testSTLRejectsLinesMalformedDataAndInvalidScale() throws {
        let line = GardenEntity(kind: .line, origin: Vec3(0,0,0), width: 1, depth: 0)
        XCTAssertThrowsError(try ModelDocument(entities: [line]).stlData())
        XCTAssertThrowsError(try ModelDocument().stlData())
        let precisionLoss = GardenEntity(kind: .rectangle, origin: Vec3(1e12, 1e12, 1e12), width: 1, depth: 1, height: 1)
        XCTAssertThrowsError(try ModelDocument(entities: [precisionLoss]).stlData())
        XCTAssertThrowsError(try ModelDocument.importSTL(Data("solid empty\nendsolid empty".utf8), name: "Empty"))
        XCTAssertThrowsError(try ModelDocument.importSTL(Data(repeating: 0, count: 84), name: "Empty"))
        XCTAssertThrowsError(try ModelDocument.importSTL(Data("facet vertex 0 0 0".utf8), name: "Bad"))
        XCTAssertThrowsError(try ModelDocument.importSTL(Data(), name: "Bad", metersPerUnit: -.infinity))
        let text = "solid x\nfacet normal 0 0 1\nouter loop\nvertex nan 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid x"
        XCTAssertThrowsError(try ModelDocument.importSTL(Data(text.utf8), name: "Bad"))
    }

    func testMeshTransformAndLinePairs() throws {
        let entity = GardenEntity(kind: .mesh, origin: Vec3(4,5,6), width: 1, depth: 1, mesh: MeshData(vertices: [Vec3(1,2,3),Vec3(2,2,3)], triangles: [], lineIndices: [0,1]))
        let mesh = try entity.triangulatedMesh()
        XCTAssertEqual(mesh.vertices[0], Vec3(5,7,9))
        XCTAssertEqual(mesh.lineIndices, [0,1])
        XCTAssertThrowsError(try ModelDocument(entities: [entity]).stlData())
    }

    func testTruncatedBinaryAndDegenerateASCIIAreRejected() throws {
        let document = ModelDocument(entities: [GardenEntity(kind: .rectangle, origin: Vec3(0,0,0), width: 1, depth: 1, height: 1)])
        let data = try document.stlData()
        XCTAssertThrowsError(try ModelDocument.importSTL(data.dropLast(), name: "Truncated"))
        let text = "solid x\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 0 0 0\nvertex 0 0 0\nendloop\nendfacet\nendsolid x"
        XCTAssertThrowsError(try ModelDocument.importSTL(Data(text.utf8), name: "Bad"))
    }

    private func subtract(_ a: Vec3,_ b: Vec3) -> Vec3 { Vec3(a.x-b.x,a.y-b.y,a.z-b.z) }
    private func cross(_ a: Vec3,_ b: Vec3) -> Vec3 { Vec3(a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x) }
    private func readFloat(_ data: Data, at offset: Int) -> Float {
        let bits = data[offset..<offset+4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << UInt32($1.offset*8) }
        return Float(bitPattern: bits)
    }
}
