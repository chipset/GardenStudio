import XCTest
@testable import SketchCore
final class ScaleTextureProjectionAudit9Tests:XCTestCase {
    private let png=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    func testScaleBakesOriginalLocalUVProjectionBeforeRotatedGeometry() throws {
        let surface=SurfaceMaterial(textureData:png,textureScale:0.2,textureRotation:0.3,faceOverrides:[FaceSurface(triangleIndices:[2,3],colorHex:"#FFFFFF",textureData:png,textureScale:0.4,textureRotation:-0.2)])
        let original=SketchEntity(kind:.rectangle,origin:Vec3(2,1,3),width:2,depth:1,height:0.5,rotation:0.7,surface:surface)
        var local=original;local.origin=Vec3(0,0,0);local.rotation=0
        let localMesh=try local.triangulatedMesh()
        let result=try EditorOperations.scale(document:ModelDocument(entities:[original]),ids:[original.id],factors:Vec3(2,1,1))
        let scaled=try XCTUnwrap(result.entities.first),mesh=try XCTUnwrap(scaled.mesh)
        let uv=try XCTUnwrap(mesh.textureCoordinates,"Scale must retain the source projection rather than recompute it after baking rotation")
        XCTAssertEqual(scaled.surface,original.surface)
        XCTAssertEqual(mesh.triangles.count,localMesh.triangles.count)
        for triangle in 0..<(localMesh.triangles.count/3) {
            let start=triangle*3,a=localMesh.vertices[localMesh.triangles[start]],b=localMesh.vertices[localMesh.triangles[start+1]],c=localMesh.vertices[localMesh.triangles[start+2]]
            let nx=(b.y-a.y)*(c.z-a.z)-(b.z-a.z)*(c.y-a.y),ny=(b.z-a.z)*(c.x-a.x)-(b.x-a.x)*(c.z-a.z),nz=(b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)
            for corner in 0..<3 {
                let p=localMesh.vertices[localMesh.triangles[start+corner]],actual=uv[mesh.triangles[start+corner]]
                let expected:TextureCoordinate
                if abs(nx)>=abs(ny) && abs(nx)>=abs(nz) {expected=TextureCoordinate(u:p.z,v:p.y)}
                else if abs(ny)>=abs(nz) {expected=TextureCoordinate(u:p.x,v:p.z)}
                else {expected=TextureCoordinate(u:p.x,v:p.y)}
                XCTAssertEqual(actual,expected)
            }
        }
    }
    func testExplicitUVScaleAndMirrorsKeepCornerAssociation() throws {
        let source=MeshData(vertices:[Vec3(0,0,0),Vec3(1,0,0),Vec3(0,0,1)],triangles:[0,1,2],textureCoordinates:[.init(u:0.1,v:0.2),.init(u:0.3,v:0.4),.init(u:0.5,v:0.6)])
        let entity=SketchEntity(kind:.mesh,origin:Vec3(2,0,3),width:1,depth:1,rotation:0.6,mesh:source,surface:SurfaceMaterial(textureData:png))
        let result=try EditorOperations.mirror(document:ModelDocument(entities:[entity]),ids:[entity.id],axis:"x")
        let mesh=try XCTUnwrap(result.entities[0].mesh)
        XCTAssertEqual(mesh.textureCoordinates,source.textureCoordinates)
        XCTAssertEqual(mesh.triangles,[0,2,1])
    }
}
