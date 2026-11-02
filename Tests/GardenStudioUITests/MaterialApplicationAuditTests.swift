import XCTest
import AppKit
import GardenStudioCore
@testable import GardenStudioUI
final class MaterialApplicationAuditTests:XCTestCase {
    private func controller(_ document:ModelDocument)->AppDelegate {
        _ = NSApplication.shared
        let result=AppDelegate()
        result.window=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:[.borderless],backing:.buffered,defer:false)
        result.document=document;result.viewport.document=document
        return result
    }
    func testApplyingWithoutSelectionReportsFailureAndLeavesDocumentAlone() throws {
        let original=ModelDocument.demo,app=controller(ModelDocument.demo)
        app.document=original
        XCTAssertThrowsError(try app.applySurface(SurfaceMaterial(colorHex:"#AA3300"),faceOnly:false))
        XCTAssertEqual(app.document,original)
        XCTAssertFalse(app.dirty)
    }
    func testApplyingToLockedSelectionReportsFailureAndLeavesDocumentAlone() throws {
        var entity=GardenEntity(kind:.rectangle,origin:Vec3(0,0,0),width:1,depth:1)
        entity.metadata=EntityMetadata(isLocked:true)
        let original=ModelDocument(entities:[entity]),app=controller(original)
        app.selection=[entity.id]
        XCTAssertThrowsError(try app.applySurface(SurfaceMaterial(colorHex:"#AA3300"),faceOnly:false))
        XCTAssertEqual(app.document,original)
        XCTAssertFalse(app.dirty)
    }
    func testApplyingToEditableSelectionChangesOnlyThatObject() throws {
        let original=ModelDocument.demo,app=controller(ModelDocument.demo)
        app.document=original
        app.selection=[original.entities[0].id]
        try app.applySurface(SurfaceMaterial(colorHex:"#AA3300"),faceOnly:false)
        XCTAssertEqual(app.document.entities[0].surface?.colorHex,"#AA3300")
        XCTAssertEqual(Array(app.document.entities.dropFirst()),Array(original.entities.dropFirst()))
        XCTAssertTrue(app.dirty)
    }
}
