import XCTest
import AppKit
import SceneKit
import SketchCore
@testable import SketchUI
final class ViewportInteractionAudit5Tests:XCTestCase {
    func testBoxSelectionDoesNotSelectGeometryClippedByTheSectionPlane() throws {
        let visible=SketchEntity(name:"Visible",kind:.line,origin:Vec3(1,0,0),width:1,depth:0)
        let clipped=SketchEntity(name:"Clipped",kind:.line,origin:Vec3(3,0,0),width:1,depth:0)
        let view=ModelViewport(frame:NSRect(x:0,y:0,width:800,height:600))
        view.document=ModelDocument(entities:[visible,clipped],presentation:PresentationState(section:SectionPlane(point:Vec3(2,0,0),normal:Vec3(1,0,0))))
        view.setStandardView("top")
        XCTAssertEqual(view.boxSelectionIDs(in:view.bounds),[visible.id])
        var uncut=view.document;uncut.presentation?.section?.enabled=false;view.document=uncut
        XCTAssertEqual(view.boxSelectionIDs(in:view.bounds),[visible.id,clipped.id])
    }
    func testBoxSelectionCannotSeedAPartialObjectFromItsClippedEndpoint() {
        let line=SketchEntity(kind:.line,origin:Vec3(1,0,0),width:3,depth:0)
        let view=ModelViewport(frame:NSRect(x:0,y:0,width:800,height:600))
        view.document=ModelDocument(entities:[line],presentation:PresentationState(section:SectionPlane(point:Vec3(2,0,0),normal:Vec3(1,0,0))))
        view.setStandardView("top")
        func around(_ point:SCNVector3)->NSRect {
            let projected=view.projectPoint(point)
            return NSRect(x:projected.x-0.25,y:projected.y-0.25,width:0.5,height:0.5)
        }
        XCTAssertTrue(view.boxSelectionIDs(in:around(SCNVector3(4,0,0))).isEmpty)
        XCTAssertEqual(view.boxSelectionIDs(in:around(SCNVector3(1,0,0))),[line.id])
    }

}
