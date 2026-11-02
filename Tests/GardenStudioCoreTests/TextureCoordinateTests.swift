import XCTest
@testable import GardenStudioCore

final class TextureCoordinateTests: XCTestCase {
    private var vertices:[Vec3] {[Vec3(0,0,0),Vec3(1,0,0),Vec3(0,0,1)]}
    func testExplicitUVsRoundTripAndOldMeshesStillDecode() throws {
        let uv=[TextureCoordinate(u:0.1,v:0.2),TextureCoordinate(u:0.8,v:0.3),TextureCoordinate(u:0.2,v:0.9)]
        let mesh=MeshData(vertices:vertices,triangles:[0,2,1],textureCoordinates:uv)
        try mesh.validate()
        XCTAssertEqual(try JSONDecoder().decode(MeshData.self,from:JSONEncoder().encode(mesh)),mesh)
        let legacy=MeshData(vertices:vertices,triangles:[0,2,1])
        XCTAssertNil(try JSONDecoder().decode(MeshData.self,from:JSONEncoder().encode(legacy)).textureCoordinates)
    }
    func testInvalidUVCountsAndNonfiniteCoordinatesReject() {
        XCTAssertThrowsError(try MeshData(vertices:vertices,triangles:[0,2,1],textureCoordinates:[TextureCoordinate(u:0,v:0)]).validate())
        XCTAssertThrowsError(try MeshData(vertices:vertices,triangles:[0,2,1],textureCoordinates:Array(repeating:TextureCoordinate(u:.nan,v:0),count:3)).validate())
    }
    func testPlanarUVGenerationPreservesTrianglesAndCreatesFaceSeams()throws {
        let source=MeshData(vertices:[Vec3(0,0,0),Vec3(1,0,0),Vec3(1,0,1),Vec3(0,0,1)],triangles:[0,1,2,0,2,3],lineIndices:[0,1])
        let mapped=try TextureTools.generatePlanarUVs(source)
        XCTAssertEqual(mapped.triangles,[4,5,6,7,8,9])
        XCTAssertEqual(mapped.lineIndices,[0,1])
        XCTAssertEqual(mapped.vertices.count,10)
        XCTAssertEqual(try XCTUnwrap(mapped.textureCoordinates).count,mapped.vertices.count)
        XCTAssertEqual(mapped.textureCoordinates?[4],TextureCoordinate(u:0,v:0))
        XCTAssertNoThrow(try mapped.validate())
    }
    func testPlanarUVGenerationRejectsMeshExpansionPastVertexLimit() {
        let base=MeshData(vertices:vertices,triangles:[0,1,2])
        XCTAssertThrowsError(try TextureTools.generatePlanarUVs(MeshData(vertices:Array(repeating:base.vertices[0],count:250_000),triangles:Array(repeating:0,count:250_002))))
    }
}
