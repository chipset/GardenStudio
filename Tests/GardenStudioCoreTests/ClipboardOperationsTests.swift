import XCTest
@testable import GardenStudioCore

final class ClipboardOperationsTests: XCTestCase {
    func box(_ x: Double = 0) -> GardenEntity { GardenEntity(kind: .rectangle, origin: Vec3(x,0,0), width:1, depth:1) }
    func testPartialGroupCopyDetachesButFullHierarchyAndLayersRemap() throws {
        let root=ModelGroup(name:"Root"),child=ModelGroup(name:"Child"),layer=ModelLayer(name:"Walls")
        var nested=child;nested.parentID=root.id
        var a=box(),b=box(2)
        let part=UUID(),component=UUID()
        var componentGroup=nested;componentGroup.componentID=component
        a.metadata=EntityMetadata(layerID:layer.id,groupID:componentGroup.id,componentPartID:part)
        b.metadata=EntityMetadata(groupID:root.id)
        let source=ModelDocument(entities:[a,b],editor:EditorState(layers:[layer],groups:[root,componentGroup]))
        let partial=try ClipboardOperations.copy(document:source,ids:[b.id])
        XCTAssertNil(partial.entities.first?.metadata?.groupID)
        let inside=try ClipboardOperations.copy(document:source,ids:[a.id,b.id],editingGroupID:root.id)
        XCTAssertEqual(inside.editor?.groups.count,1)
        XCTAssertNil(inside.editor?.groups.first?.parentID)
        XCTAssertNil(inside.entities.first(where:{$0.id==b.id})?.metadata?.groupID)
        let full=try ClipboardOperations.copy(document:source,ids:[a.id,b.id])
        let result=try ClipboardOperations.paste(payload:full,into:source)
        try result.validate()
        XCTAssertEqual(result.entities.count,4)
        let pasted=Array(result.entities.suffix(2))
        XCTAssertTrue(Set(pasted.map(\.id)).isDisjoint(with:[a.id,b.id]))
        let copiedA=try XCTUnwrap(pasted.first(where:{$0.origin==a.origin}))
        XCTAssertNotEqual(copiedA.metadata?.layerID,layer.id)
        XCTAssertNotEqual(copiedA.metadata?.groupID,componentGroup.id)
        XCTAssertNotEqual(copiedA.metadata?.componentPartID,part)
        let pastedGroup=try XCTUnwrap(result.editor?.groups.first(where:{$0.id==copiedA.metadata?.groupID}))
        XCTAssertNotEqual(pastedGroup.componentID,component)
        XCTAssertNotNil(pastedGroup.parentID)
    }
    func testContextCutFilteringAndPasteParent() throws {
        let group=ModelGroup(name:"Inside")
        var a=box(),locked=box(2),outside=box(4)
        a.metadata=EntityMetadata(groupID:group.id)
        locked.metadata=EntityMetadata(isLocked:true,groupID:group.id)
        outside.metadata=EntityMetadata()
        let source=ModelDocument(entities:[a,locked,outside],editor:EditorState(groups:[group]))
        let copied=try ClipboardOperations.copy(document:source,ids:[a.id,locked.id,outside.id],editingGroupID:group.id,editableOnly:true)
        XCTAssertEqual(copied.entities.map(\.id),[a.id])
        XCTAssertNil(copied.entities[0].metadata?.groupID)
        let result=try ClipboardOperations.paste(payload:copied,into:source,editingGroupID:group.id)
        XCTAssertEqual(result.entities.last?.metadata?.groupID,group.id)
        XCTAssertThrowsError(try ClipboardOperations.paste(payload:copied,into:source,editingGroupID:UUID()))
    }
    func testReversedEdgesOrderAndBranchRejection() throws {
        let a=GardenEntity(kind:.line,origin:Vec3(2,0,0),width:-2,depth:0)
        let b=GardenEntity(kind:.line,origin:Vec3(2,0,3),width:0,depth:-3)
        let route=try GeometryPath.orderedOpenPath(entities:[b,a])
        XCTAssertEqual(route.count,3)
        XCTAssertEqual(Set(route.map{"\($0.x),\($0.z)"}),["0.0,0.0","2.0,0.0","2.0,3.0"])
        let branch=GardenEntity(kind:.line,origin:Vec3(2,0,0),width:1,depth:0)
        XCTAssertThrowsError(try GeometryPath.orderedOpenPath(entities:[a,b,branch]))
        XCTAssertThrowsError(try GeometryPath.orderedOpenPath(entities:[a,GardenEntity(kind:.line,origin:Vec3(9,0,0),width:1,depth:0)]))
        let close=GardenEntity(kind:.line,origin:Vec3(2,0,3),width:-2,depth:-3)
        XCTAssertThrowsError(try GeometryPath.orderedOpenPath(entities:[a,b,close]))
        XCTAssertThrowsError(try GeometryPath.orderedOpenPath(entities:[a,a]))
    }
    func testPastedComponentInstancesKeepInternalLinksWithoutLinkingToSource() throws {
        let component=UUID(),part=UUID()
        let first=ModelGroup(name:"First",componentID:component),second=ModelGroup(name:"Second",componentID:component)
        var a=box(),b=box(3)
        a.metadata=EntityMetadata(groupID:first.id,componentPartID:part)
        b.metadata=EntityMetadata(groupID:second.id,componentPartID:part)
        let original=ModelDocument(entities:[a,b],editor:EditorState(groups:[first,second]))
        let payload=try ClipboardOperations.copy(document:original,ids:[a.id,b.id])
        let pasted=try ClipboardOperations.paste(payload:payload,into:original)
        let groups=Array(pasted.editor!.groups.suffix(2)),entities=Array(pasted.entities.suffix(2))
        XCTAssertEqual(groups[0].componentID,groups[1].componentID)
        XCTAssertNotEqual(groups[0].componentID,component)
        XCTAssertEqual(entities[0].metadata?.componentPartID,entities[1].metadata?.componentPartID)
        XCTAssertNotEqual(entities[0].metadata?.componentPartID,part)
        let again=try ClipboardOperations.paste(payload:payload,into:pasted)
        XCTAssertTrue(Set(again.entities.suffix(2).map(\.id)).isDisjoint(with:Set(pasted.entities.map(\.id))))
    }

}
