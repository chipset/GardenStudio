import AppKit
import XCTest
import SketchCore
@testable import SketchUI

private final class OutlinerTestPasteboard: GeometryPasteboard {
    var values: [NSPasteboard.PasteboardType: Data] = [:]
    func data(forType type:NSPasteboard.PasteboardType)->Data? { values[type] }
    func string(forType type:NSPasteboard.PasteboardType)->String? { values[type].flatMap { String(data:$0,encoding:.utf8) } }
    func writeGeometry(data:Data,text:String,type:NSPasteboard.PasteboardType)->Bool {
        values = [type:data,.string:Data(text.utf8)]
        return true
    }
}

final class OutlinerClipboardTests: XCTestCase {
    private func controller() -> AppDelegate {
        _ = NSApplication.shared
        let app = AppDelegate()
        app.window = NSWindow(contentRect:NSRect(x:0,y:0,width:1200,height:800),styleMask:[.titled],backing:.buffered,defer:false)
        app.document = ModelDocument(entities:[
            SketchEntity(name:"Visible",kind:.rectangle,origin:Vec3(0,0,0),width:1,depth:1),
            SketchEntity(name:"Hidden",kind:.rectangle,origin:Vec3(3,0,0),width:1,depth:1,metadata:EntityMetadata(isHidden:true))
        ])
        app.buildUI()
        app.viewport.geometryPasteboard = OutlinerTestPasteboard()
        app.viewport.onDocumentChange = { [weak app] in app?.commit($0) }
        app.viewport.onSelectionSetChange = { [weak app] in app?.setSelection($0) }
        app.refresh()
        return app
    }

    func testOutlinerFocusForwardsCopyPasteCutAndUndo() {
        let app = controller()
        app.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        XCTAssertTrue(app.window.makeFirstResponder(app.table))
        XCTAssertTrue(app.window.firstResponder === app.table)

        guard app.table.tryToPerform(#selector(ModelViewport.copy(_:)),with:nil) else {
            XCTFail("Outliner focus has no geometry Copy responder")
            return
        }
        XCTAssertTrue(app.table.tryToPerform(#selector(ModelViewport.paste(_:)),with:nil))
        XCTAssertEqual(app.document.entities.count,3)
        XCTAssertEqual(app.selection.count,1)
        XCTAssertTrue(app.table.tryToPerform(#selector(ModelViewport.cut(_:)),with:nil))
        XCTAssertEqual(app.document.entities.count,2)
        app.undoAction()
        XCTAssertEqual(app.document.entities.count,3)
        app.undoAction()
        XCTAssertEqual(app.document.entities.count,2)
    }

    func testOutlinerSelectAllUsesGeometryVisibilityAndContext() {
        let app = controller()
        XCTAssertTrue(app.window.makeFirstResponder(app.table))
        app.table.selectAll(nil)
        XCTAssertEqual(app.selection,Set([app.document.entities[0].id]))
        XCTAssertFalse(app.selection.contains(app.document.entities[1].id))
    }

    func testTextFieldSelectAllStillEditsTextRatherThanGeometry() throws {
        let app = controller()
        app.select(app.document.entities[0].id)
        app.measurements.stringValue = "125mm"
        XCTAssertTrue(app.window.makeFirstResponder(app.measurements))
        let editor = try XCTUnwrap(app.window.firstResponder as? NSTextView)
        editor.selectAll(nil)
        XCTAssertEqual(editor.selectedRange().length,5)
        XCTAssertEqual(app.selection,Set([app.document.entities[0].id]))
    }
}
