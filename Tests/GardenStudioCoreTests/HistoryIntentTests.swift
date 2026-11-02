import XCTest
@testable import GardenStudioCore

final class HistoryIntentTests: XCTestCase {
    func testViewIntentTravelsWithItsActionThroughUndoAndRedo() throws {
        let empty = ModelDocument(name:"Empty")
        let first = ModelDocument(entities:[GardenEntity(kind:.rectangle,origin:Vec3(0,0,0),width:1,depth:1)])
        var viewed = first
        viewed.presentation = PresentationState(camera:CameraState(target:Vec3(2,3,4),distance:5))
        var history = ModelHistory()
        history.record(empty)
        history.record(first,restoresCamera:true)
        let undoView = try XCTUnwrap(history.undoChange(current:viewed))
        XCTAssertEqual(undoView.document,first)
        XCTAssertTrue(undoView.restoresCamera)
        let undoGeometry = try XCTUnwrap(history.undoChange(current:first))
        XCTAssertEqual(undoGeometry.document,empty)
        XCTAssertFalse(undoGeometry.restoresCamera)
        let redoGeometry = try XCTUnwrap(history.redoChange(current:empty))
        XCTAssertEqual(redoGeometry.document,first)
        XCTAssertFalse(redoGeometry.restoresCamera)
        let redoView = try XCTUnwrap(history.redoChange(current:first))
        XCTAssertEqual(redoView.document,viewed)
        XCTAssertTrue(redoView.restoresCamera)
    }
}
