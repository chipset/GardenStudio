import XCTest
@testable import SketchCore

final class GroupDepthAuditTests:XCTestCase {
    func testProjectRejectsExcessivelyDeepGroupsInEitherStorageOrder() throws {
        var groups:[ModelGroup]=[]
        for i in 0..<300 {groups.append(ModelGroup(name:"Level \(i)",parentID:groups.last?.id))}
        for ordered in [groups,Array(groups.reversed())] {
            let document=ModelDocument(editor:EditorState(groups:ordered))
            XCTAssertThrowsError(try document.validate())
        }
    }
    func testWideHierarchiesAndNormalNestedGroupsRemainSupported() throws {
        let wide=(0..<300).map{ModelGroup(name:"Group \($0)")}
        XCTAssertNoThrow(try ModelDocument(editor:EditorState(groups:wide)).validate())
        var nested:[ModelGroup]=[]
        for i in 0..<256 {nested.append(ModelGroup(name:"Level \(i)",parentID:nested.last?.id))}
        XCTAssertNoThrow(try ModelDocument(editor:EditorState(groups:nested)).validate())
    }
}
