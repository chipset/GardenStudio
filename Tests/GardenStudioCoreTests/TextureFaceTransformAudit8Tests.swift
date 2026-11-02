import XCTest
@testable import GardenStudioCore
final class TextureFaceTransformAudit8Tests:XCTestCase {
    private let png=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    func testUntexturedFaceOverrideMasksBaseTextureOnLargeFace() throws {
        let mesh=MeshData(vertices:[Vec3(0,0,0),Vec3(1e38,0,0),Vec3(0,0,1),Vec3(0,1,0)],triangles:[0,2,1,0,3,2])
        let surface=SurfaceMaterial(textureData:png,textureScale:0.0001,faceOverrides:[FaceSurface(triangleIndices:[0],colorHex:"#FFFFFF")])
        let entity=GardenEntity(kind:.mesh,origin:Vec3(0,0,0),width:1e38,depth:1,height:1,mesh:mesh,surface:surface)
        XCTAssertNoThrow(try ModelDocument(entities:[entity]).validate())
    }
    func testCombinedRotationCanOverflowEvenWhenEachScaledCoordinateIsFinite() throws {
        let mesh=MeshData(vertices:[Vec3(0,0,0),Vec3(1,0,0),Vec3(0,0,1)],triangles:[0,1,2],textureCoordinates:[.init(u:3e38,v:3e38),.init(u:0,v:0),.init(u:0,v:1)])
        let entity=GardenEntity(kind:.mesh,origin:Vec3(0,0,0),width:1,depth:1,mesh:mesh,surface:SurfaceMaterial(textureData:png,textureRotation:.pi/4))
        XCTAssertThrowsError(try ModelDocument(entities:[entity]).validate())
    }
}
