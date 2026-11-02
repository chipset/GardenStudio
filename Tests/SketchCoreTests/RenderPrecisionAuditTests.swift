import XCTest
import SceneKit
@testable import SketchCore

final class RenderPrecisionAuditTests:XCTestCase {
    func testFiniteDoubleMeshThatOverflowsTheActualRendererBufferIsRejected() throws {
        let mesh=MeshData(vertices:[Vec3(1e100,0,0),Vec3(0,1,0),Vec3(0,0,1)],triangles:[0,1,2])
        let source=SCNGeometrySource(vertices:mesh.vertices.map{SCNVector3(CGFloat($0.x),CGFloat($0.y),CGFloat($0.z))})
        XCTAssertEqual(source.bytesPerComponent,4)
        let renderedX=source.data.withUnsafeBytes{$0.loadUnaligned(fromByteOffset:source.dataOffset,as:Float.self)}
        XCTAssertFalse(renderedX.isFinite,"The finite JSON number actually becomes infinity in SceneKit")
        XCTAssertThrowsError(try mesh.validate())
        let entity=SketchEntity(kind:.mesh,origin:Vec3(0,0,0),width:1,depth:1,height:1,mesh:mesh)
        XCTAssertThrowsError(try ModelDocument(entities:[entity]).validate())
    }
    func testPrimitiveLocalAndWorldCoordinatesMustRemainRenderable() {
        let origin=SketchEntity(kind:.rectangle,origin:Vec3(1e100,0,0),width:1,depth:1,height:1)
        let wide=SketchEntity(kind:.rectangle,origin:Vec3(0,0,0),width:1e100,depth:1,height:1)
        let tall=SketchEntity(kind:.circle,origin:Vec3(0,0,0),width:1,depth:1,height:1e100)
        let line=SketchEntity(kind:.line,origin:Vec3(3e38,0,0),width:3e38,depth:0)
        for entity in [origin,wide,tall,line] {
            XCTAssertThrowsError(try ModelDocument(entities:[entity]).validate())
        }
    }
    func testMeshTransformCannotOverflowAnOtherwiseFiniteLocalVertex() {
        let mesh=MeshData(vertices:[Vec3(3e38,0,0),Vec3(0,1,0),Vec3(0,0,1)],triangles:[0,1,2])
        XCTAssertNoThrow(try mesh.validate())
        let entity=SketchEntity(kind:.mesh,origin:Vec3(3e38,0,0),width:3e38,depth:1,height:1,mesh:mesh)
        XCTAssertThrowsError(try ModelDocument(entities:[entity]).validate())
    }
    func testLargeRepresentableGeometryStillValidatesAndExportsWorldCoordinates() throws {
        let entity=SketchEntity(kind:.rectangle,origin:Vec3(1e12,0,-1e12),width:200,depth:300,height:50,rotation:0.42)
        try ModelDocument(entities:[entity]).validate()
        let mesh=try entity.triangulatedMesh()
        XCTAssertTrue(mesh.vertices.allSatisfy{Float($0.x).isFinite && Float($0.y).isFinite && Float($0.z).isFinite})
    }
    func testFiniteDoubleUVThatOverflowsTheRendererBufferIsRejected() {
        let source=SCNGeometrySource(textureCoordinates:[CGPoint(x:1e100,y:0)])
        XCTAssertEqual(source.bytesPerComponent,4)
        let renderedU=source.data.withUnsafeBytes{$0.loadUnaligned(fromByteOffset:source.dataOffset,as:Float.self)}
        XCTAssertFalse(renderedU.isFinite)
        let mesh=MeshData(vertices:[Vec3(0,0,0),Vec3(1,0,0),Vec3(0,0,1)],triangles:[0,1,2],textureCoordinates:[.init(u:1e100,v:0),.init(u:0,v:0),.init(u:0,v:1)])
        XCTAssertThrowsError(try mesh.validate())
    }
    func testRotationCannotOverflowBeforeATranslationCancelsTheMagnitude() {
        let rotation=Double.pi/4
        let origin=Vec3(-1e38,0,0),point=Vec3(3e38,0,3e38)
        let finalX=origin.x+cos(rotation)*point.x+sin(rotation)*point.z
        XCTAssertTrue(Float(finalX).isFinite,"Double's final result hides the renderer's earlier overflow")
        let node=SCNNode()
        node.position=SCNVector3(CGFloat(origin.x),0,0);node.eulerAngles.y=CGFloat(rotation)
        let actual=node.convertPosition(SCNVector3(CGFloat(point.x),0,CGFloat(point.z)),to:nil)
        XCTAssertFalse(actual.x.isFinite,"SceneKit's rotation overflows before translation")
        let line=SketchEntity(kind:.line,origin:origin,width:point.x,depth:point.z,rotation:rotation)
        XCTAssertThrowsError(try ModelDocument(entities:[line]).validate())
    }
}
