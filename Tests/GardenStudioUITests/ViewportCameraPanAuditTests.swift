import XCTest
import AppKit
import GardenStudioCore
@testable import GardenStudioUI
final class ViewportCameraPanAuditTests:XCTestCase {
    private func event(_ type:NSEvent.EventType,at point:NSPoint,flags:NSEvent.ModifierFlags=[] ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with:type,location:point,modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1))
    }
    func testPanCannotMoveCameraOutsideItsSaveableRange() throws {
        let view=ModelViewport(frame:NSRect(x:0,y:0,width:800,height:600))
        let original=CameraState(target:Vec3(100_000_000,0,0),yaw:.pi/4,pitch:0.52,distance:19)
        try original.validate();view.applyCamera(original)
        var status="";view.onStatus={status=$0}
        view.rightMouseDown(with:try event(.rightMouseDown,at:.zero))
        view.rightMouseDragged(with:try event(.rightMouseDragged,at:NSPoint(x:-100,y:0),flags:.shift))
        XCTAssertNoThrow(try view.captureCamera().validate())
        XCTAssertEqual(view.captureCamera(),original)
        XCTAssertTrue(status.contains("camera range"),status)
    }
    func testOrdinaryPanStillChangesTheViewAndRemainsSaveable() throws {
        let view=ModelViewport(frame:NSRect(x:0,y:0,width:800,height:600))
        let original=view.captureCamera()
        view.rightMouseDown(with:try event(.rightMouseDown,at:.zero))
        view.rightMouseDragged(with:try event(.rightMouseDragged,at:NSPoint(x:-100,y:20),flags:.shift))
        XCTAssertNotEqual(view.captureCamera().target,original.target)
        XCTAssertNoThrow(try view.captureCamera().validate())
    }
    func testOrbitAddsAnOrdinaryGestureToLargeSavedYawWithoutLosingIt() throws {
        for yaw in [0.7,1e50] {
            let view=ModelViewport(frame:NSRect(x:0,y:0,width:800,height:600))
            let original=CameraState(target:Vec3(2,3,4),yaw:yaw,pitch:0.52,distance:19)
            view.applyCamera(original)
            let before=view.cameraNode.position
            view.rightMouseDown(with:try event(.rightMouseDown,at:.zero))
            view.rightMouseDragged(with:try event(.rightMouseDragged,at:NSPoint(x:100,y:0)))
            let actual=view.cameraNode.position
            let x=Double(before.x)-2,z=Double(before.z)-4,delta = -0.8
            XCTAssertEqual(Double(actual.x),2+cos(delta)*x+sin(delta)*z,accuracy:1e-5)
            XCTAssertEqual(Double(actual.z),4-sin(delta)*x+cos(delta)*z,accuracy:1e-5)
            XCTAssertNoThrow(try view.captureCamera().validate())
        }
    }
    func testHorizontalAndZeroMotionOrbitPreserveStandardViewPitch() throws {
        for name in ["front","right"] {
            for horizontalDelta in [0.0,100.0] {
                let view=ModelViewport(frame:NSRect(x:0,y:0,width:800,height:600))
                view.setStandardView(name)
                let original=view.captureCamera()
                view.rightMouseDown(with:try event(.rightMouseDown,at:.zero))
                view.rightMouseDragged(with:try event(.rightMouseDragged,at:NSPoint(x:horizontalDelta,y:0)))
                XCTAssertEqual(view.captureCamera().pitch,original.pitch,"A horizontal gesture must not tilt the \(name) view")
                if horizontalDelta==0 {XCTAssertEqual(view.captureCamera(),original)}
            }
        }
    }
}
