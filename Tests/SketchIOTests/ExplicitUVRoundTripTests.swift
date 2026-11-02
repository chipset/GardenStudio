import XCTest
import SketchCore
@testable import SketchIO

final class ExplicitUVRoundTripTests: XCTestCase {
    func testColladaRetainsExplicitUVsAndMaterialTransform() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:directory)}
        let vertices=[Vec3(0,0,0),Vec3(2,0,0),Vec3(0,0,1)]
        let uv=[TextureCoordinate(u:0.15,v:0.2),TextureCoordinate(u:0.8,v:0.3),TextureCoordinate(u:0.25,v:0.9)]
        let mesh=MeshData(vertices:vertices,triangles:[0,2,1],textureCoordinates:uv)
        let entity=SketchEntity(name:"UV mesh",kind:.mesh,origin:Vec3(0,0,0),width:2,depth:1,mesh:mesh,surface:SurfaceMaterial(colorHex:"#AABBCC",textureScale:0.5,textureRotation:0.3))
        let url=directory.appendingPathComponent("test.dae")
        try ColladaFormat.write(ModelDocument(entities:[entity]),to:url)
        let result=try ColladaFormat.read(url:url)
        let actual=try XCTUnwrap(result.entities[0].mesh)
        let actualUV=try XCTUnwrap(actual.textureCoordinates)
        for (point,expectedUV) in zip(vertices,uv) {
            let index=try XCTUnwrap(actual.vertices.firstIndex(where:{abs($0.x-point.x)<1e-5 && abs($0.y-point.y)<1e-5 && abs($0.z-point.z)<1e-5}))
            XCTAssertEqual(actualUV[index].u,expectedUV.u,accuracy:1e-5)
            XCTAssertEqual(actualUV[index].v,expectedUV.v,accuracy:1e-5)
        }
        XCTAssertEqual(result.entities[0].surface?.textureScale,0.5)
        XCTAssertEqual(result.entities[0].surface?.textureRotation,0.3)
    }
}
