import AppKit
import SceneKit
import XCTest
import GardenStudioCore
@testable import GardenStudioUI

final class ViewportAuditRegressionTests:XCTestCase {
    func testPrimitiveAndMeshLinesRenderTheirStoredPaintColor() throws {
        let line=GardenEntity(kind:.line,origin:Vec3(0,0,0),width:2,depth:0,colorHex:"#AB3412")
        var mesh=line;mesh.id=UUID();mesh.kind = .mesh
        mesh.mesh=MeshData(vertices:[Vec3(0,0,0),Vec3(2,0,0)],lineIndices:[0,1])
        let view=ModelViewport(frame:NSRect(x:0,y:0,width:800,height:600))
        view.document=ModelDocument(entities:[line,mesh])
        for node in view.models.childNodes {
            let color=try XCTUnwrap(node.childNodes.compactMap{$0.geometry?.firstMaterial?.diffuse.contents as? NSColor}.first)
            XCTAssertEqual(MaterialManager.hex(color),"#AB3412")
        }
    }
    func testSelectedLineMeasurementsKeepSignedAndZeroAxisComponents() throws {
        let line=GardenEntity(kind:.line,origin:Vec3(0,0,0),width:2,depth:0)
        let view=ModelViewport(frame:NSRect(x:0,y:0,width:800,height:600))
        view.document=ModelDocument(entities:[line]);view.selectedIDs=[line.id]
        view.applyMeasurement("-2, 0, -1")
        let actual=try XCTUnwrap(view.document.entities.first)
        XCTAssertEqual(actual.width,-2)
        XCTAssertEqual(actual.depth,0)
        XCTAssertEqual(actual.height,-1)
        let original=view.document
        var status="";view.onStatus={status=$0}
        view.applyMeasurement("0, 0, 0")
        XCTAssertEqual(view.document,original,"A zero-length edit must reject atomically")
        XCTAssertTrue(status.contains("nonzero"),status)
    }
    func testFacePickingDoesNotIncludeDisconnectedCoplanarIslands() throws {
        let mesh=MeshData(vertices:[Vec3(0,0,0),Vec3(1,0,0),Vec3(1,0,1),Vec3(0,0,1),Vec3(3,0,0),Vec3(4,0,0),Vec3(3,0,1)],triangles:[0,2,1,0,3,2,4,6,5])
        let entity=GardenEntity(kind:.mesh,origin:Vec3(0,0,0),width:4,depth:1,mesh:mesh)
        let view=ModelViewport(frame:NSRect(x:0,y:0,width:800,height:600))
        let indices=view.coplanarFaceIndices(entity:entity,point:Vec3(0.7,0,0.3),normal:Vec3(0,1,0),seedTriangle:0)
        XCTAssertEqual(indices,[0,1])
    }
    func testFacePickingConnectsTrianglesAcrossDuplicatedUVSeamVertices() throws {
        let mesh=MeshData(vertices:[Vec3(0,0,0),Vec3(1,0,1),Vec3(1,0,0),Vec3(0,0,0),Vec3(0,0,1),Vec3(1,0,1)],triangles:[0,1,2,3,4,5])
        let entity=GardenEntity(kind:.mesh,origin:Vec3(0,0,0),width:1,depth:1,mesh:mesh)
        let view=ModelViewport(frame:NSRect(x:0,y:0,width:800,height:600))
        XCTAssertEqual(view.coplanarFaceIndices(entity:entity,point:Vec3(0.7,0,0.3),normal:Vec3(0,1,0),seedTriangle:0),[0,1])
    }
}
