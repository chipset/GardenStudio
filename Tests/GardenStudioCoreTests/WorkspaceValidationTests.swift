import XCTest
@testable import GardenStudioCore

final class WorkspaceValidationTests: XCTestCase {
    func testInvalidMaterialAndPresentationCannotEnterSavedDocument() {
        var document = ModelDocument.demo
        document.entities[0].surface = SurfaceMaterial(name: "Bad", colorHex: "#XYZXYZ")
        XCTAssertThrowsError(try document.validate())
        document = .demo
        var state = PresentationState()
        state.section = SectionPlane(point: Vec3(0,0,0), normal: Vec3(0,0,0))
        document.presentation = state
        XCTAssertThrowsError(try document.validate())
    }
    func testProfileValidationRunsForPersistedGeometry() {
        var document = ModelDocument.demo
        document.entities[0].profile = FaceProfile(outer:[Vec3(0,0,0),Vec3(1,0,0)])
        XCTAssertThrowsError(try document.validate())
    }
    func testOldAndExpandedProjectsRoundTrip() throws {
        var document = ModelDocument.demo
        document.editor = EditorState(snapStep:0.0001,units:"mm")
        document.presentation = PresentationState()
        document.entities[0].surface = SurfaceMaterial(name:"Wood",colorHex:"#A27650")
        try document.validate()
        XCTAssertEqual(try JSONDecoder().decode(ModelDocument.self,from:JSONEncoder().encode(document)),document)
    }
}
