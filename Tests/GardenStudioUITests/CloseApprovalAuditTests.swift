import AppKit
import XCTest
import GardenStudioCore
@testable import GardenStudioUI
final class CloseApprovalAuditTests:XCTestCase {
    func testApprovedDocumentCloseDoesNotPromptAgainWhenAppQuits() {
        _ = NSApplication.shared
        let app=AppDelegate();app.dirty=true
        var prompts=0
        XCTAssertTrue(app.approveDocumentWindowClose{prompts+=1;return true})
        let reply=app.documentTerminationReply{prompts+=1;return false}
        XCTAssertEqual(reply,.terminateNow)
        XCTAssertEqual(prompts,1,"Window close approval must satisfy the immediate app-quit handoff")
    }
    func testChangingDocumentInvalidatesPreviousCloseApproval() {
        _ = NSApplication.shared
        let app=AppDelegate();app.dirty=true
        XCTAssertTrue(app.approveDocumentWindowClose{return true})
        app.document=ModelDocument(name:"A different document")
        var prompts=0
        XCTAssertEqual(app.documentTerminationReply{prompts+=1;return false},.terminateCancel)
        XCTAssertEqual(prompts,1,"An old approval cannot discard a new document")
    }
    func testCancelledCloseDoesNotApproveLaterQuit() {
        _ = NSApplication.shared
        let app=AppDelegate();app.dirty=true
        XCTAssertTrue(app.approveDocumentWindowClose{return true})
        XCTAssertFalse(app.approveDocumentWindowClose{return false})
        var prompts=0
        XCTAssertEqual(app.documentTerminationReply{prompts+=1;return false},.terminateCancel)
        XCTAssertEqual(prompts,1)
    }
}
