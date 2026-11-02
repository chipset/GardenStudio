import XCTest
import AppKit
import SceneKit
import SketchCore
@testable import SketchUI

final class ViewportTransactionAuditTests:XCTestCase {
    private func mouse(_ type:NSEvent.EventType,point:NSPoint)->NSEvent {
        NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!
    }
    func testDeleteDuringAnEditCannotBeRevertedByCancellingTheOldDrag() throws {
        let line=SketchEntity(kind:.line,origin:Vec3(1,0,0),width:1,depth:0)
        let view=ModelViewport(frame:NSRect(x:0,y:0,width:800,height:600))
        view.document=ModelDocument(entities:[line]);view.tool = .move
        let projected=view.projectPoint(SCNVector3(1.5,0,0))
        view.mouseDown(with:mouse(.leftMouseDown,point:NSPoint(x:projected.x,y:projected.y)))
        XCTAssertEqual(view.selectedIDs,[line.id],"Fixture must start an edit on the wire")
        var committed:ModelDocument?
        view.onDocumentChange={committed=$0}
        let delete=try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:"\u{7f}",charactersIgnoringModifiers:"\u{7f}",isARepeat:false,keyCode:51))
        view.keyDown(with:delete)
        XCTAssertTrue(try XCTUnwrap(committed).entities.isEmpty)
        view.cancelOperation()
        XCTAssertEqual(view.document.entities,try XCTUnwrap(committed).entities,"Escape cannot resurrect geometry after its deletion was committed")
    }
    func testRenderedLargeFiniteRotationsMatchCoreGeometry() throws {
        for radians in [1e20,1e100] {
            let mesh=MeshData(vertices:[Vec3(1,0,0),Vec3(2,0,0)],lineIndices:[0,1])
            let entity=SketchEntity(kind:.mesh,origin:Vec3(0,0,0),width:1,depth:0,rotation:radians,mesh:mesh)
            let view=ModelViewport(frame:NSRect(x:0,y:0,width:800,height:600))
            view.document=ModelDocument(entities:[entity])
            let node=try XCTUnwrap(view.models.childNodes.first)
            let actual=node.convertPosition(SCNVector3(1,0,0),to:nil)
            let expected=try entity.triangulatedMesh().vertices[0]
            XCTAssertTrue(actual.x.isFinite && actual.z.isFinite)
            XCTAssertEqual(Double(actual.x),expected.x,accuracy:1e-5)
            XCTAssertEqual(Double(actual.z),expected.z,accuracy:1e-5)
        }
    }

    func testFittingVeryLargeGeometryCannotCreateAnUnsaveableCamera() throws {
        for entity in [
            SketchEntity(kind:.line,origin:Vec3(0,0,0),width:10_000_000,depth:0),
            SketchEntity(kind:.line,origin:Vec3(200_000_000,0,0),width:1,depth:0)
        ] {
            let view=ModelViewport(frame:NSRect(x:0,y:0,width:800,height:600))
            view.document=ModelDocument(entities:[entity])
            let previous=view.captureCamera()
            var status="";view.onStatus={status=$0}
            view.zoomExtents()
            XCTAssertNoThrow(try view.captureCamera().validate())
            XCTAssertEqual(view.captureCamera(),previous)
            XCTAssertTrue(status.contains("camera range"),status)
        }
    }

}
