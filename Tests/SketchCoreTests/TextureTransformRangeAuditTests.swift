import XCTest
import SceneKit
@testable import SketchCore
final class TextureTransformRangeAuditTests:XCTestCase {
    private let png=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    func testRawFiniteUVCannotOverflowMaterialTransformInRenderer() throws {
        let mesh=MeshData(vertices:[Vec3(0,0,0),Vec3(1,0,0),Vec3(0,0,1)],triangles:[0,1,2],textureCoordinates:[.init(u:3e38,v:0),.init(u:0,v:0),.init(u:0,v:1)])
        try mesh.validate()
        let transform=SCNMatrix4MakeScale(10000,10000,1)
        XCTAssertFalse((Float(transform.m11)*Float(mesh.textureCoordinates![0].u)).isFinite)
        let entity=SketchEntity(kind:.mesh,origin:Vec3(0,0,0),width:1,depth:1,mesh:mesh,surface:SurfaceMaterial(textureData:png,textureScale:0.0001))
        XCTAssertThrowsError(try ModelDocument(entities:[entity]).validate())
    }
    func testImplicitPlanarProjectionCannotOverflowTextureTransform() throws {
        let entity=SketchEntity(kind:.rectangle,origin:Vec3(0,0,0),width:2e38,depth:1,height:0,surface:SurfaceMaterial(textureData:png,textureScale:0.0001))
        XCTAssertThrowsError(try ModelDocument(entities:[entity]).validate())
    }
    func testLargeCoordinatesOnUntexturedFacesRemainSupported() throws {
        let mesh=MeshData(vertices:[Vec3(0,0,0),Vec3(1e38,0,0),Vec3(0,0,1),Vec3(0,1,0)],triangles:[0,2,1,0,3,2])
        let surface=SurfaceMaterial(faceOverrides:[FaceSurface(triangleIndices:[1],colorHex:"#FFFFFF",textureData:png,textureScale:0.0001)])
        let entity=SketchEntity(kind:.mesh,origin:Vec3(0,0,0),width:1e38,depth:1,height:1,mesh:mesh,surface:surface)
        XCTAssertNoThrow(try ModelDocument(entities:[entity]).validate())
    }
}
