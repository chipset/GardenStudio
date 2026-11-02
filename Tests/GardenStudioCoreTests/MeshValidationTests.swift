import XCTest
@testable import GardenStudioCore

final class MeshValidationTests: XCTestCase {
    func testExistingJSONWithoutMeshStillDecodes() throws {
        let original = ModelDocument.demo
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ModelDocument.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.entities.allSatisfy { $0.mesh == nil })
    }
    func testPlanarMeshWithZeroBoundingHeightIsValidAndRoundTrips() throws {
        let mesh = MeshData(vertices: [Vec3(0,0,0),Vec3(1,0,0),Vec3(0,0,1)], triangles: [0,2,1])
        let entity = GardenEntity(kind: .mesh, origin: Vec3(0,0,0), width: 1, depth: 1, mesh: mesh)
        let document = ModelDocument(entities: [entity])
        try document.validate()
        XCTAssertEqual(try JSONDecoder().decode(ModelDocument.self, from: JSONEncoder().encode(document)), document)
    }
    func testInvalidMeshIndicesAndNonFiniteVerticesAreRejected() {
        for mesh in [MeshData(vertices: [Vec3(0,0,0)], triangles: [0,1,2]), MeshData(vertices: [Vec3(.infinity,0,0)], lineIndices: [0,0]), MeshData(vertices: [Vec3(0,0,0)], triangles: [0]) ] {
            let entity = GardenEntity(kind: .mesh, origin: Vec3(0,0,0), width: 0, depth: 0, mesh: mesh)
            XCTAssertThrowsError(try ModelDocument(entities:[entity]).validate())
        }
    }
    func testMeshKindRequiresGeometryAndPrimitiveRejectsUnexpectedMesh() {
        XCTAssertThrowsError(try ModelDocument(entities:[GardenEntity(kind:.mesh,origin:Vec3(0,0,0),width:1,depth:1)]).validate())
        let mesh = MeshData(vertices:[Vec3(0,0,0),Vec3(1,0,0)],lineIndices:[0,1])
        XCTAssertThrowsError(try ModelDocument(entities:[GardenEntity(kind:.rectangle,origin:Vec3(0,0,0),width:1,depth:1,mesh:mesh)]).validate())
    }
}
