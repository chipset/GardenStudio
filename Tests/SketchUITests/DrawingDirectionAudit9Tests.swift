import XCTest
import AppKit
import SketchCore
@testable import SketchUI
final class DrawingDirectionAudit9Tests:XCTestCase {
    private func view()->ModelViewport {
        let result=ModelViewport(frame:NSRect(x:0,y:0,width:800,height:600));result.tool = .line;return result
    }
    private func assertFreshNumericLine(_ view:ModelViewport,file:StaticString=#filePath,line:UInt=#line)throws {
        view.beginDrawing(at:Vec3(3,0,0));view.applyMeasurement("1")
        let last=try XCTUnwrap(view.document.entities.last,file:file,line:line)
        let mesh=try last.triangulatedMesh()
        XCTAssertEqual(mesh.vertices,[Vec3(3,0,0),Vec3(4,0,0)],file:file,line:line)
    }
    func testNewNumericLineDoesNotReuseCompletedPreviewDirection()throws {
        let view=view();view.beginDrawing(at:Vec3(0,0,0));view.updateDrawingPreview(to:Vec3(0,0,2));view.applyMeasurement("1")
        XCTAssertEqual(view.document.entities.count,1)
        try assertFreshNumericLine(view)
    }
    func testNewNumericLineDoesNotReuseCancelledPreviewDirection()throws {
        let view=view();view.beginDrawing(at:Vec3(0,0,0));view.updateDrawingPreview(to:Vec3(0,0,2));view.cancelOperation()
        try assertFreshNumericLine(view)
    }
    func testZeroMotionPreviewUsesPlaneDirectionForNumericLength()throws {
        let view=view();view.beginDrawing(at:Vec3(3,0,0));view.updateDrawingPreview(to:Vec3(3,0,0));view.applyMeasurement("1")
        let last=try XCTUnwrap(view.document.entities.last)
        XCTAssertEqual(try last.triangulatedMesh().vertices,[Vec3(3,0,0),Vec3(4,0,0)])
    }
}
