import XCTest
@testable import GardenStudioCore

final class ComponentTopologyAuditTests:XCTestCase {
    private func fixture()throws->ModelDocument {
        let part=GardenEntity(name:"Source",kind:.rectangle,origin:Vec3(0,0,0),width:1,depth:1,height:1)
        var document=try EditorOperations.group(document:ModelDocument(entities:[part]),ids:[part.id],name:"Linked",component:true)
        document=try EditorOperations.duplicate(document:document,ids:[part.id],count:1,delta:Vec3(4,0,3))
        return document
    }
    private func componentGroups(_ document:ModelDocument)throws->[ModelGroup] {
        let components=(document.editor?.groups ?? []).filter{$0.componentID != nil}
        XCTAssertEqual(components.count,2)
        XCTAssertEqual(Set(components.map(\.componentID)).count,1)
        return components
    }
    private func addedLine(in document:ModelDocument,group:ModelGroup,name:String)->GardenEntity {
        GardenEntity(name:name,kind:.line,origin:group.origin,width:2,depth:0,height:0,colorHex:"#AA3300",metadata:EntityMetadata(groupID:group.id))
    }
    func testAddingAComponentPartCreatesOnePeerWithoutChangingItsTransform()throws {
        let document=try fixture(),roots=try componentGroups(document)
        let originalPeer=try XCTUnwrap(document.entities.first{$0.metadata?.groupID==roots[1].id})
        var changed=document;let newLine=addedLine(in:document,group:roots[0],name:"New edge");changed.entities.append(newLine)
        let result=try EditorOperations.synchronizeComponentTopology(original:document,proposed:changed,editingGroupID:roots[0].id)
        let source=try XCTUnwrap(result.entities.first{$0.id==newLine.id})
        let peers=result.entities.filter{$0.name=="New edge"}
        XCTAssertEqual(peers.count,2)
        let peer=try XCTUnwrap(peers.first{$0.id != source.id})
        XCTAssertEqual(peer.metadata?.componentPartID,source.metadata?.componentPartID)
        XCTAssertEqual(peer.origin,Vec3(roots[1].origin.x+source.origin.x-roots[0].origin.x,roots[1].origin.y+source.origin.y-roots[0].origin.y,roots[1].origin.z+source.origin.z-roots[0].origin.z))
        XCTAssertEqual(peer.width,2)
        XCTAssertEqual(result.entities.first{$0.id==originalPeer.id},originalPeer)
        XCTAssertNoThrow(try result.validate())
    }
    func testDeletingAPartInsideOneInstanceRemovesOnlyItsLinkedPeer()throws {
        let document=try fixture(),roots=try componentGroups(document)
        let source=try XCTUnwrap(document.entities.first{$0.metadata?.groupID==roots[0].id})
        let part=try XCTUnwrap(source.metadata?.componentPartID)
        var changed=document;changed.entities.removeAll{$0.id==source.id}
        let result=try EditorOperations.synchronizeComponentTopology(original:document,proposed:changed,editingGroupID:roots[0].id)
        XCTAssertFalse(result.entities.contains{$0.metadata?.componentPartID==part})
        XCTAssertEqual(result.entities.count,0)
        XCTAssertNoThrow(try result.validate())
    }
    func testNewNestedGroupsAndPartsAppearInMatchingPeerStructure()throws {
        let document=try fixture(),roots=try componentGroups(document)
        let source=document.entities.first{$0.metadata?.groupID==roots[0].id}!
        let grouped=try EditorOperations.group(document:document,ids:[source.id],name:"Edge detail",component:false,editingGroupID:roots[0].id)
        let synchronized=try EditorOperations.synchronizeComponentTopology(original:document,proposed:grouped,editingGroupID:roots[0].id)
        let groups=synchronized.editor?.groups.filter{$0.name=="Edge detail"} ?? []
        XCTAssertEqual(groups.count,2)
        let sourceGroup=try XCTUnwrap(synchronized.entities.first{$0.id==source.id}?.metadata?.groupID)
        let sourcePathGroup=try XCTUnwrap(groups.first{$0.id==sourceGroup})
        var newGeometry=synchronized
        let line=addedLine(in:synchronized,group:sourcePathGroup,name:"Nested edge");newGeometry.entities.append(line)
        let result=try EditorOperations.synchronizeComponentTopology(original:synchronized,proposed:newGeometry,editingGroupID:sourcePathGroup.id)
        let nested=result.entities.filter{$0.name=="Nested edge"}
        XCTAssertEqual(nested.count,2)
        XCTAssertEqual(Set(nested.compactMap{$0.metadata?.groupID}).count,2)
        XCTAssertTrue(nested.contains{$0.metadata?.groupID==sourcePathGroup.id})
        XCTAssertTrue(nested.allSatisfy{item in groups.contains(where:{$0.id==item.metadata?.groupID})})
        XCTAssertNoThrow(try result.validate())
    }
    func testSameNamedNestedGroupsMatchByLinkedContentsRatherThanRandomUUIDOrder()throws {
        let definition=UUID(),sourceRoot=UUID(uuidString:"00000000-0000-0000-0000-000000000001")!,peerRoot=UUID(uuidString:"00000000-0000-0000-0000-000000000002")!
        let sourceFirst=UUID(uuidString:"00000000-0000-0000-0000-000000000020")!,sourceSecond=UUID(uuidString:"00000000-0000-0000-0000-000000000030")!
        let peerFirst=UUID(uuidString:"00000000-0000-0000-0000-000000000040")!,peerSecond=UUID(uuidString:"00000000-0000-0000-0000-000000000010")!
        let partA=UUID(),partB=UUID()
        let groups=[ModelGroup(id:sourceRoot,name:"Linked",componentID:definition),ModelGroup(id:peerRoot,name:"Linked",componentID:definition,origin:Vec3(10,0,0)),
                    ModelGroup(id:sourceFirst,name:"Detail",parentID:sourceRoot),ModelGroup(id:sourceSecond,name:"Detail",parentID:sourceRoot),
                    ModelGroup(id:peerFirst,name:"Detail",parentID:peerRoot),ModelGroup(id:peerSecond,name:"Detail",parentID:peerRoot)]
        let a=GardenEntity(name:"A",kind:.line,origin:Vec3(0,0,0),width:1,depth:0,metadata:EntityMetadata(groupID:sourceFirst,componentPartID:partA))
        let b=GardenEntity(name:"B",kind:.line,origin:Vec3(0,0,2),width:1,depth:0,metadata:EntityMetadata(groupID:sourceSecond,componentPartID:partB))
        let peerA=GardenEntity(name:"A",kind:.line,origin:Vec3(10,0,0),width:1,depth:0,metadata:EntityMetadata(groupID:peerFirst,componentPartID:partA))
        let peerB=GardenEntity(name:"B",kind:.line,origin:Vec3(10,0,2),width:1,depth:0,metadata:EntityMetadata(groupID:peerSecond,componentPartID:partB))
        let original=ModelDocument(entities:[a,b,peerA,peerB],editor:EditorState(groups:groups))
        var proposed=original
        let addition=addedLine(in:original,group:groups.first{$0.id==sourceSecond}!,name:"New in B")
        proposed.entities.append(addition)
        let result=try EditorOperations.synchronizeComponentTopology(original:original,proposed:proposed,editingGroupID:sourceRoot)
        let copied=try XCTUnwrap(result.entities.first{$0.name=="New in B" && $0.id != addition.id})
        XCTAssertEqual(copied.metadata?.groupID,peerSecond)
        XCTAssertNoThrow(try result.validate())
    }
    func testOrdinaryEditsWithoutComponentRemainIndependent()throws {
        let source=GardenEntity(kind:.rectangle,origin:Vec3(0,0,0),width:1,depth:1)
        var changed=ModelDocument(entities:[source]);let new=GardenEntity(kind:.line,origin:Vec3(0,0,0),width:1,depth:0)
        changed.entities.append(new)
        let result=try EditorOperations.synchronizeComponentTopology(original:ModelDocument(entities:[source]),proposed:changed,editingGroupID:nil)
        XCTAssertEqual(result,changed)
    }
}
