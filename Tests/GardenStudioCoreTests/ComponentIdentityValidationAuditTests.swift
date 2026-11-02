import XCTest
@testable import GardenStudioCore

final class ComponentIdentityValidationAuditTests:XCTestCase {
    private func part(_ group:UUID,_ part:UUID,x:Double=0)->GardenEntity {
        GardenEntity(kind:.rectangle,origin:Vec3(x,0,0),width:1,depth:1,metadata:EntityMetadata(groupID:group,componentPartID:part))
    }
    func testDuplicatePartIdentityWithinOneInstanceCannotEnterAnEditableDocument() {
        let component=UUID(),identity=UUID()
        let first=ModelGroup(name:"First",componentID:component),peer=ModelGroup(name:"Peer",componentID:component)
        let a=part(first.id,identity),b=part(first.id,identity,x:2),linked=part(peer.id,identity,x:10)
        let malformed=ModelDocument(entities:[a,b,linked],editor:EditorState(groups:[first,peer]))
        XCTAssertThrowsError(try malformed.validate())
        XCTAssertThrowsError(try EditorOperations.synchronizeComponents(document:malformed,sourceID:a.id))
    }
    func testOrdinarySubgroupsDoNotAllowDuplicatePartsInsideTheSameInstance() {
        let root=ModelGroup(name:"Component",componentID:UUID())
        let child=ModelGroup(name:"Subgroup",parentID:root.id)
        let identity=UUID()
        let malformed=ModelDocument(entities:[part(root.id,identity),part(child.id,identity,x:2)],editor:EditorState(groups:[root,child]))
        XCTAssertThrowsError(try malformed.validate())
    }
    func testLinkedInstancesAndNestedIndependentComponentsRetainValidPartLinks() throws {
        let component=UUID(),identity=UUID()
        let first=ModelGroup(name:"First",componentID:component),peer=ModelGroup(name:"Peer",componentID:component)
        let nested=ModelGroup(name:"Nested independent component",parentID:first.id,componentID:UUID())
        var a=part(first.id,identity)
        let b=part(peer.id,identity,x:10),c=part(nested.id,identity,x:2)
        var document=ModelDocument(entities:[a,b,c],editor:EditorState(groups:[first,peer,nested]))
        try document.validate()
        a.colorHex="#AA3300";document.entities[0]=a
        let updated=try EditorOperations.synchronizeComponents(document:document,sourceID:a.id)
        XCTAssertEqual(updated.entities[1].colorHex,"#AA3300")
        XCTAssertEqual(updated.entities[2],c)
    }
}
