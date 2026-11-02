import XCTest
import GardenStudioCore
@testable import GardenStudioIO
final class ProjectExportLimitTests:XCTestCase {
    func testProjectExportOverBudgetDoesNotReplaceDestination() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
        defer{try? FileManager.default.removeItem(at:url)}
        let original=Data("Existing project".utf8)
        try original.write(to:url)
        XCTAssertThrowsError(try ExchangeCatalog.writeProject(.demo,to:url,maximumBytes:1))
        XCTAssertEqual(try Data(contentsOf:url),original)
    }
    func testProjectExportWithinBudgetRoundTripsEditableDocument() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
        defer{try? FileManager.default.removeItem(at:url)}
        var document=ModelDocument.demo
        document.editor=EditorState(snapStep:0.0254,units:"in")
        document.presentation=PresentationState()
        try ExchangeCatalog.writeProject(document,to:url,maximumBytes:100_000)
        XCTAssertEqual(try ExchangeCatalog.read(url:url),document)
    }
}
