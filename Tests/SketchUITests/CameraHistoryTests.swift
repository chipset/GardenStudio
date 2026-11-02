import AppKit
import XCTest
import SketchCore
@testable import SketchUI

final class CameraHistoryTests: XCTestCase {
    private func delegate() -> AppDelegate {
        _ = NSApplication.shared
        let controller = AppDelegate()
        controller.window = NSWindow(contentRect: NSRect(x:0,y:0,width:800,height:600),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        controller.document = ModelDocument()
        controller.viewport.document = controller.document
        return controller
    }

    private func assertCamera(_ actual: CameraState, _ expected: CameraState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.target, expected.target, file:file,line:line)
        XCTAssertEqual(actual.distance, expected.distance, accuracy:1e-8,file:file,line:line)
        XCTAssertEqual(actual.yaw, expected.yaw, accuracy:1e-8,file:file,line:line)
        XCTAssertEqual(actual.pitch, expected.pitch, accuracy:1e-8,file:file,line:line)
        XCTAssertEqual(actual.orthographic, expected.orthographic,file:file,line:line)
    }

    func testFreshDocumentCameraUndoAndRedo() {
        let controller = delegate()
        let before = controller.viewport.captureCamera()
        XCTAssertNil(controller.document.presentation)
        let replacement = CameraState(target:Vec3(10,20,30),yaw:0.2,pitch:0.3,distance:1,orthographic:true)
        controller.changeCamera(to:replacement)
        assertCamera(controller.viewport.captureCamera(),replacement)
        controller.undoAction()
        assertCamera(controller.viewport.captureCamera(),before)
        controller.redoAction()
        assertCamera(controller.viewport.captureCamera(),replacement)
    }

    func testCameraUndoUsesLiveViewNotStaleSavedCamera() {
        let controller = delegate()
        controller.document.presentation = PresentationState()
        let live = CameraState(target:Vec3(3,4,5),yaw:0.8,pitch:0.4,distance:7)
        controller.viewport.applyCamera(live)
        let replacement = CameraState(target:Vec3(-1,2,-3),yaw:0,pitch:0.2,distance:2)
        controller.changeCamera(to:replacement)
        controller.undoAction()
        assertCamera(controller.viewport.captureCamera(),live)
    }

    func testGeometryUndoDoesNotUndoSubsequentViewNavigation() {
        let controller = delegate()
        var changed = controller.document
        changed.entities.append(SketchEntity(kind:.rectangle,origin:Vec3(0,0,0),width:1,depth:1))
        controller.commit(changed)
        let navigated = CameraState(target:Vec3(1,2,3),yaw:1,pitch:0.5,distance:4)
        controller.viewport.applyCamera(navigated)
        controller.undoAction()
        XCTAssertTrue(controller.document.entities.isEmpty)
        assertCamera(controller.viewport.captureCamera(),navigated)
    }
    func testRestoringSameSavedSceneAfterOrbitCanBeUndoneToLiveView() {
        let controller = delegate()
        let savedCamera = CameraState(target:Vec3(1,0,0),yaw:0.1,pitch:0.2,distance:3)
        controller.changeCamera(to:savedCamera)
        let live = CameraState(target:Vec3(4,5,6),yaw:1,pitch:0.6,distance:8)
        controller.viewport.applyCamera(live)
        controller.restoreScene(SavedScene(name:"Saved",camera:savedCamera))
        assertCamera(controller.viewport.captureCamera(),savedCamera)
        controller.undoAction()
        assertCamera(controller.viewport.captureCamera(),live)
        controller.redoAction()
        assertCamera(controller.viewport.captureCamera(),savedCamera)
    }

    func testMultipleGeometryUndosAndRedosPreserveLiveNavigation() {
        let controller = delegate()
        var first = controller.document
        first.entities.append(SketchEntity(kind:.rectangle,origin:Vec3(0,0,0),width:1,depth:1))
        controller.commit(first)
        let middle = CameraState(target:Vec3(4,0,0),yaw:0.5,pitch:0.3,distance:5)
        controller.viewport.applyCamera(middle)
        var second = controller.document
        second.entities.append(SketchEntity(kind:.circle,origin:Vec3(2,0,0),width:1,depth:1))
        controller.commit(second)
        let live = CameraState(target:Vec3(8,0,0),yaw:1,pitch:0.4,distance:9)
        controller.viewport.applyCamera(live)
        controller.undoAction()
        assertCamera(controller.viewport.captureCamera(),live)
        controller.undoAction()
        assertCamera(controller.viewport.captureCamera(),live)
        XCTAssertTrue(controller.document.entities.isEmpty)
        controller.redoAction()
        assertCamera(controller.viewport.captureCamera(),live)
        controller.redoAction()
        assertCamera(controller.viewport.captureCamera(),live)
        XCTAssertEqual(controller.document.entities.count,2)
    }

    func testMixedGeometryAndExplicitViewHistoryRestoresOnlyViewActions() {
        let controller = delegate()
        var shape = controller.document
        shape.entities.append(SketchEntity(kind:.rectangle,origin:Vec3(0,0,0),width:1,depth:1))
        controller.commit(shape)
        let beforeView = CameraState(target:Vec3(3,1,0),yaw:0.4,pitch:0.2,distance:6)
        let savedView = CameraState(target:Vec3(7,2,0),yaw:0.8,pitch:0.3,distance:8,orthographic:true)
        let latestView = CameraState(target:Vec3(10,3,0),yaw:1.1,pitch:0.5,distance:12,orthographic:true)
        controller.viewport.applyCamera(beforeView)
        controller.changeCamera(to:savedView)
        var second = controller.document
        second.entities[0].colorHex = "#112233"
        controller.commit(second)
        controller.viewport.applyCamera(latestView)
        controller.undoAction()
        assertCamera(controller.viewport.captureCamera(),latestView)
        controller.undoAction()
        assertCamera(controller.viewport.captureCamera(),beforeView)
        controller.undoAction()
        assertCamera(controller.viewport.captureCamera(),beforeView)
        controller.redoAction()
        assertCamera(controller.viewport.captureCamera(),beforeView)
        controller.redoAction()
        assertCamera(controller.viewport.captureCamera(),savedView)
        controller.redoAction()
        assertCamera(controller.viewport.captureCamera(),savedView)
    }

}
