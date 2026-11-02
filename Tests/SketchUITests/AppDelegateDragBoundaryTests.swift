import XCTest
import AppKit
import SceneKit
import SketchCore
@testable import SketchUI
final class AppDelegateDragBoundaryTests:XCTestCase {
    private func editingController() throws -> AppDelegate {
        _ = NSApplication.shared
        let app=AppDelegate()
        app.window=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:[.borderless],backing:.buffered,defer:false)
        let line=SketchEntity(kind:.line,origin:Vec3(1,0,0),width:1,depth:0)
        app.document=ModelDocument(entities:[line])
        app.viewport.frame=NSRect(x:0,y:0,width:800,height:600)
        app.viewport.document=app.document;app.viewport.tool = .move
        app.selection=[line.id]
        let projected=app.viewport.projectPoint(SCNVector3(1.5,0,0))
        let down=try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:NSPoint(x:projected.x,y:projected.y),modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1))
        app.viewport.mouseDown(with:down)
        XCTAssertEqual(app.viewport.selectedIDs,[line.id])
        return app
    }
    func testParentDeleteCannotBeRevertedByCancellingOldViewportDrag() throws {
        let app=try editingController()
        app.deleteSelection()
        XCTAssertTrue(app.document.entities.isEmpty)
        app.viewport.cancelOperation()
        XCTAssertEqual(app.viewport.document,app.document)
    }
    func testParentUndoCannotBeRevertedByCancellingOldViewportDrag() throws {
        let app=try editingController()
        app.history.record(ModelDocument())
        app.undoAction()
        XCTAssertTrue(app.document.entities.isEmpty)
        app.viewport.cancelOperation()
        XCTAssertEqual(app.viewport.document,app.document)
    }
}
