import XCTest
import AppKit
import SceneKit
import GardenStudioCore
@testable import GardenStudioUI
final class ViewportCameraUpAuditTests:XCTestCase {
    private func assertFinite(_ view:ModelViewport,file:StaticString=#filePath,line:UInt=#line) {
        let matrix=view.cameraNode.simdWorldTransform
        for column in 0..<4 {for row in 0..<4 {XCTAssertTrue(matrix[column][row].isFinite,file:file,line:line)}}
    }
    func testRepeatedStandardViewsAndHorizontalOrbitDoNotAccumulateRoll() throws {
        let view=ModelViewport(frame:NSRect(x:0,y:0,width:800,height:600))
        for name in Array(repeating:["iso","front","right","front","iso","right"],count:10).flatMap({$0}) {
            view.setStandardView(name)
            XCTAssertEqual(Double(view.cameraNode.worldRight.y),0,accuracy:1e-4,"\(name) must keep screen right horizontal")
            assertFinite(view)
        }
        view.setStandardView("front")
        let down=try XCTUnwrap(NSEvent.mouseEvent(with:.rightMouseDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1))
        let drag=try XCTUnwrap(NSEvent.mouseEvent(with:.rightMouseDragged,location:NSPoint(x:100,y:0),modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1))
        view.rightMouseDown(with:down);view.rightMouseDragged(with:drag)
        XCTAssertEqual(Double(view.cameraNode.worldRight.y),0,accuracy:1e-4)
        assertFinite(view)
    }
    func testExactVerticalViewsUseAStableFiniteUpVector() throws {
        let view=ModelViewport(frame:NSRect(x:0,y:0,width:800,height:600))
        for pitch in [Double.pi/2,-Double.pi/2] {
            view.applyCamera(CameraState(target:Vec3(0,0,0),yaw:0.7,pitch:pitch,distance:19))
            assertFinite(view)
            let right=view.cameraNode.worldRight,up=view.cameraNode.worldUp
            XCTAssertEqual(hypot(hypot(Double(right.x),Double(right.y)),Double(right.z)),1,accuracy:1e-6)
            XCTAssertEqual(hypot(hypot(Double(up.x),Double(up.y)),Double(up.z)),1,accuracy:1e-6)
            XCTAssertLessThan(Double(up.z),-0.99)
        }
        view.setStandardView("front")
        XCTAssertEqual(Double(view.cameraNode.worldRight.y),0,accuracy:1e-4)
    }
}
