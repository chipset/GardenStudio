import AppKit
import XCTest
import GardenStudioCore
@testable import GardenStudioUI

final class AppLifecycleTests:XCTestCase {
    func testApplicationMenuActionsRemainEnabledWithoutKeyWindow() throws {
        let application=NSApplication.shared
        let previous=application.mainMenu
        defer{application.mainMenu=previous}
        let controller=AppDelegate()
        controller.setupMenus()
        let menu=try XCTUnwrap(application.mainMenu?.items.first?.submenu)
        menu.update()
        for name in ["About Garden Studio","Quit Garden Studio"] {
            let item=try XCTUnwrap(menu.items.first{$0.title==name})
            XCTAssertTrue(controller.responds(to:try XCTUnwrap(item.action)))
            XCTAssertTrue(item.isEnabled,name)
        }
    }
    func testOpenProjectPreservesEditableDocumentAndRejectsOversizedFiles() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:directory)}
        let file=directory.appendingPathComponent("project.json")
        var source=ModelDocument.demo
        source.editor=EditorState(snapStep:0.0254,units:"in")
        try JSONEncoder().encode(source).write(to:file)
        XCTAssertEqual(try AppDelegate.readProject(at:file),source)
        let writer=try FileHandle(forWritingTo:file)
        try writer.truncate(atOffset:100_000_001)
        try writer.close()
        XCTAssertThrowsError(try AppDelegate.readProject(at:file))
        XCTAssertThrowsError(try AppDelegate.readProject(at:directory))
    }

    func testResetToEqualDocumentInvalidatesPendingImport() {
        _ = NSApplication.shared
        let controller=AppDelegate()
        controller.window=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:[.borderless],backing:.buffered,defer:false)
        controller.document=ModelDocument()
        let captured=controller.documentRevision
        XCTAssertTrue(controller.importContextIsCurrent(revision:captured,groupID:nil))
        controller.reset(ModelDocument())
        XCTAssertFalse(controller.importContextIsCurrent(revision:captured,groupID:nil))
    }
    func testSaveWritesAReopenableProjectAndClearsDirtyState() throws {
        _ = NSApplication.shared
        let controller=AppDelegate()
        controller.window=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:[.borderless],backing:.buffered,defer:false)
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
        defer{try? FileManager.default.removeItem(at:file)}
        controller.currentURL=file
        controller.document=ModelDocument.demo
        controller.document.editor=EditorState(snapStep:0.0254,units:"in")
        controller.viewport.document=controller.document
        controller.dirty=true
        XCTAssertTrue(controller.performSave(forcePanel:false))
        XCTAssertFalse(controller.dirty)
        XCTAssertEqual(try AppDelegate.readProject(at:file),controller.document)
        XCTAssertEqual(controller.document.editor?.units,"in")
        XCTAssertNotNil(controller.document.presentation?.camera)
    }
}
