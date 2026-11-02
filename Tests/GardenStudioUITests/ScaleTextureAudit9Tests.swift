import XCTest
import SceneKit
import GardenStudioCore
@testable import GardenStudioUI
final class ScaleTextureAudit9Tests:XCTestCase {
    private func uv(_ entity:GardenEntity)throws->[Double] {
        let geometry=try XCTUnwrap(MaterialManager.geometry(for:entity))
        let source=try XCTUnwrap(geometry.sources(for:.texcoord).first)
        return try (0..<source.vectorCount).flatMap{vertex in
            try (0..<source.componentsPerVector).map{component in
                let offset=source.dataOffset+vertex*source.dataStride+component*source.bytesPerComponent
                if source.bytesPerComponent==4 {return source.data.withUnsafeBytes{Double($0.loadUnaligned(fromByteOffset:offset,as:Float.self))}}
                guard source.bytesPerComponent==8 else{throw GeometryIOError.invalid("Unexpected UV component size")}
                return source.data.withUnsafeBytes{$0.loadUnaligned(fromByteOffset:offset,as:Double.self)}
            }
        }
    }
    func testScalingRotatedTexturedGeometryPreservesItsLocalPaintMapping() throws {
        let png=try XCTUnwrap(Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let entity=GardenEntity(kind:.rectangle,origin:Vec3(0,0,0),width:2,depth:1,height:1,rotation:0.6,surface:SurfaceMaterial(textureData:png,textureScale:0.5,textureRotation:0.2))
        let before=try uv(entity)
        for factors in [Vec3(1,1,1),Vec3(2,2,2)] {
            let scaled=try EditorOperations.scale(document:ModelDocument(entities:[entity]),ids:[entity.id],factors:factors)
            let after=try uv(XCTUnwrap(scaled.entities.first))
            XCTAssertEqual(after.count,before.count)
            for (a,b) in zip(after,before) {XCTAssertEqual(a,b,accuracy:1e-6,"Scaling should preserve texture attachment instead of reprojecting it onto new axes")}
        }
    }
}
