import XCTest
@testable import SketchCore
final class ComponentDuplicateAudit8Tests:XCTestCase {
    func testDuplicatingOrdinarySubgroupInsideComponentCreatesNewPartIdentities() throws {
        let item=SketchEntity(kind:.rectangle,origin:Vec3(0,0,0),width:1,depth:1,height:1)
        var document=try EditorOperations.group(document:ModelDocument(entities:[item]),ids:[item.id],name:"Outer",component:true)
        let outer=try XCTUnwrap(document.entities[0].metadata?.groupID)
        document=try EditorOperations.group(document:document,ids:[item.id],name:"Ordinary subgroup",component:false,editingGroupID:outer)
        let originalPart=try XCTUnwrap(document.entities[0].metadata?.componentPartID)
        let result=try EditorOperations.duplicate(document:document,ids:[item.id],count:1,delta:Vec3(2,0,0),editingGroupID:outer)
        XCTAssertEqual(result.entities.count,2)
        XCTAssertEqual(result.entities[0].metadata?.componentPartID,originalPart)
        XCTAssertNotEqual(result.entities[1].metadata?.componentPartID,originalPart)
        XCTAssertNotEqual(result.entities[1].metadata?.groupID,result.entities[0].metadata?.groupID)
        try result.validate()
    }
    func testDuplicatingNestedComponentInsideContextPreservesItsLinkedPartIdentity() throws {
        let item=SketchEntity(kind:.rectangle,origin:Vec3(0,0,0),width:1,depth:1,height:1)
        var document=try EditorOperations.group(document:ModelDocument(entities:[item]),ids:[item.id],name:"Inner",component:true)
        document=try EditorOperations.group(document:document,ids:[item.id],name:"Outer",component:true)
        let outer=try XCTUnwrap(document.editor?.groups.last?.id)
        let part=document.entities[0].metadata?.componentPartID
        var result=try EditorOperations.duplicate(document:document,ids:[item.id],count:1,delta:Vec3(2,0,0),editingGroupID:outer)
        XCTAssertEqual(result.entities[1].metadata?.componentPartID,part)
        result.entities[0].height=3
        result=try EditorOperations.synchronizeComponents(document:result,sourceID:item.id)
        XCTAssertEqual(result.entities[1].height,3)
    }
}
