import XCTest
import AppKit
import SketchCore
@testable import SketchUI

final class PresentationSettingsAuditTests:XCTestCase {
    func testUnchangedSnapSettingsKeepTheirPhysicalSpacing() throws {
        _ = NSApplication.shared
        let controller=AppDelegate()
        for spacing in [0.123456789012345,0.0000123456789012345,12345.6789012345] {
            let text=AppDelegate.snapSpacingForEditing(spacing)
            XCTAssertEqual(try controller.length(text),spacing,"Opening and applying settings changed the snap grid")
        }
    }
    func testFirstDimensionInLegacyProjectUsesItsDisplayUnits() throws {
        _ = NSApplication.shared
        let controller=AppDelegate()
        controller.window=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:[.borderless],backing:.buffered,defer:false)
        controller.document=ModelDocument(editor:EditorState(units:"mm"))
        controller.viewport.document=controller.document
        XCTAssertNil(controller.document.presentation)
        controller.addMeasurement(start:Vec3(0,0,0),end:Vec3(0.0254,0,0),dimension:true)
        let presentation=try XCTUnwrap(controller.document.presentation)
        XCTAssertEqual(presentation.units,"millimeters")
        XCTAssertEqual(presentation.formattedLength(0.0254),"25.40 mm")
    }
    func testExistingExplicitPresentationUnitsArePreserved() {
        _ = NSApplication.shared
        let controller=AppDelegate()
        controller.window=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:[.borderless],backing:.buffered,defer:false)
        controller.document=ModelDocument(editor:EditorState(units:"mm"),presentation:PresentationState(units:"inches"))
        controller.viewport.document=controller.document
        controller.addMeasurement(start:Vec3(0,0,0),end:Vec3(0.0254,0,0),dimension:true)
        XCTAssertEqual(controller.document.presentation?.units,"inches")
    }
}
