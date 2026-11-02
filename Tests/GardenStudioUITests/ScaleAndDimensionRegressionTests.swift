import AppKit
import SceneKit
import XCTest
import GardenStudioCore
@testable import GardenStudioUI

final class ScaleAndDimensionRegressionTests: XCTestCase {
    private func assertInsideDepthRange(_ entity: GardenEntity, view: ModelViewport, file: StaticString = #filePath, line: UInt = #line) throws {
        let state = view.captureCamera()
        let camera = try XCTUnwrap(view.cameraNode.camera)
        // Independently project vertices onto the camera's forward axis.
        let forward = Vec3(-cos(state.pitch)*sin(state.yaw), -sin(state.pitch), -cos(state.pitch)*cos(state.yaw))
        let eye = Vec3(state.target.x-state.distance*forward.x,state.target.y-state.distance*forward.y,state.target.z-state.distance*forward.z)
        for p in try entity.triangulatedMesh().vertices {
            let depth = (p.x-eye.x)*forward.x+(p.y-eye.y)*forward.y+(p.z-eye.z)*forward.z
            XCTAssertGreaterThan(depth, camera.zNear, file:file,line:line)
            XCTAssertLessThan(depth, camera.zFar, file:file,line:line)
        }
    }
    func testFitKeepsLargeAndTranslatedModelsInsideClippingPlanes() throws {
        for origin in [Vec3(0,0,0),Vec3(100000,200,300000)] {
            let entity = GardenEntity(kind:.rectangle,origin:origin,width:10000,depth:10000,height:100)
            let view = ModelViewport(frame:NSRect(x:0,y:0,width:800,height:600))
            view.document = ModelDocument(entities:[entity]); view.zoomExtents()
            try assertInsideDepthRange(entity,view:view)
            let fit = view.captureCamera().distance
            let scroll = try XCTUnwrap(CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:0,wheel2:0,wheel3:0))
            view.scrollWheel(with:try XCTUnwrap(NSEvent(cgEvent:scroll)))
            XCTAssertEqual(view.captureCamera().distance,fit,accuracy:1e-8)
        }
    }
    func testManualCameraAndMillimeterFitUseValidDepthRanges() throws {
        let entity = GardenEntity(kind:.rectangle,origin:Vec3(10000,0,20000),width:10000,depth:10000,height:100)
        let view = ModelViewport(frame:NSRect(x:0,y:0,width:800,height:600))
        view.document = ModelDocument(entities:[entity])
        view.applyCamera(CameraState(target:Vec3(10000,50,20000),distance:50000))
        try assertInsideDepthRange(entity,view:view)
        let before = view.captureCamera()
        view.applyCamera(CameraState(distance:.nan))
        XCTAssertEqual(view.captureCamera(),before)
        let small = GardenEntity(kind:.rectangle,origin:Vec3(0,0,0),width:0.001,depth:0.001,height:0.001)
        view.document = ModelDocument(entities:[small]); view.zoomExtents()
        try assertInsideDepthRange(small,view:view)
        XCTAssertEqual(view.models.boundingBox.max.x-view.models.boundingBox.min.x,0.001,accuracy:1e-8)
    }
}
