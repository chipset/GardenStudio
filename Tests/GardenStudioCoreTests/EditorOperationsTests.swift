import XCTest
@testable import GardenStudioCore

final class EditorOperationsTests: XCTestCase {
    func box(_ x: Double = 0) -> GardenEntity { GardenEntity(kind: .rectangle, origin: Vec3(x,0,0), width: 2, depth: 2, height: 2) }
    func testOriginalJSONDecodesWithoutEditorMetadata() throws {
        let source = """
        {"name":"Old","entities":[{"id":"00000000-0000-0000-0000-000000000001","name":"Box","kind":"rectangle","origin":{"x":0,"y":0,"z":0},"width":2,"depth":2,"height":1,"colorHex":"#AABBCC","rotation":0}]}
        """
        let document = try JSONDecoder().decode(ModelDocument.self, from: Data(source.utf8))
        XCTAssertNil(document.editor)
        XCTAssertNil(document.entities[0].metadata)
        try document.validate()
    }
    func testLockedEntitiesSurviveEveryTransform() throws {
        var entity = box(); entity.metadata = EntityMetadata(isLocked: true)
        let original = ModelDocument(entities: [entity])
        let ids: Set<UUID> = [entity.id]
        XCTAssertEqual(try EditorOperations.translate(document: original, ids: ids, delta: Vec3(1,2,3)), original)
        XCTAssertEqual(try EditorOperations.rotate(document: original, ids: ids, radians: 1), original)
        XCTAssertEqual(try EditorOperations.scale(document: original, ids: ids, factors: Vec3(2,2,2)), original)
        XCTAssertEqual(try EditorOperations.mirror(document: original, ids: ids, axis: "x"), original)
        XCTAssertEqual(try EditorOperations.duplicate(document: original, ids: ids, count: 2, delta: Vec3(1,0,0)), original)
    }
    func testCollectiveRotationUsesSelectionCenter() throws {
        let a = box(-2), b = box(2)
        let result = try EditorOperations.rotate(document: ModelDocument(entities: [a,b]), ids: [a.id,b.id], radians: .pi / 2)
        XCTAssertEqual(result.entities[0].origin.x, 0, accuracy: 1e-8)
        XCTAssertEqual(result.entities[0].origin.z, 2, accuracy: 1e-8)
        XCTAssertEqual(result.entities[1].origin.z, -2, accuracy: 1e-8)
    }
    func testScaleBakesWorldGeometryAndKeepsCenter() throws {
        var a = box(); a.rotation = .pi / 4
        let result = try EditorOperations.scale(document: ModelDocument(entities:[a]), ids:[a.id], factors:Vec3(2,3,1))
        let mesh = try result.entities[0].triangulatedMesh()
        XCTAssertEqual(mesh.vertices.map(\.y).max()!, 4, accuracy: 1e-8)
        XCTAssertEqual(mesh.vertices.map(\.y).min()!, -2, accuracy: 1e-8)
        XCTAssertEqual(result.entities[0].kind, .mesh)
    }
    func testMirroringReversesTriangleWinding() throws {
        let a = box()
        let originalMesh = try a.triangulatedMesh()
        let result = try EditorOperations.mirror(document: ModelDocument(entities:[a]), ids:[a.id], axis:"x")
        let mesh = try result.entities[0].triangulatedMesh()
        XCTAssertEqual(mesh.triangles[0],originalMesh.triangles[0])
        XCTAssertEqual(mesh.triangles[1],originalMesh.triangles[2])
        XCTAssertEqual(mesh.triangles[2],originalMesh.triangles[1])
        XCTAssertEqual(mesh.vertices[0].x,-originalMesh.vertices[0].x,accuracy:1e-8)
    }
    func testMovingSolidMeshVertexPreservesFacesUVsAndPlacement()throws {
        let primitive=box(),base=try primitive.triangulatedMesh()
        var mesh=base
        mesh.textureCoordinates=mesh.vertices.map{TextureCoordinate(u:$0.x,v:$0.z)}
        var solid=primitive;solid.kind = .mesh;solid.mesh=mesh;solid.profile=nil;solid.profileExtrusion=nil
        let original=ModelDocument(entities:[solid]),target=base.vertices[0],delta=Vec3(0.2,0.3,-0.1)
        let result=try EditorOperations.moveVertex(document:original,ids:[solid.id],at:target,delta:delta,tolerance:1e-8)
        let changed=try XCTUnwrap(result.entities.first).triangulatedMesh()
        XCTAssertEqual(changed.vertices[0],Vec3(target.x+delta.x,target.y+delta.y,target.z+delta.z))
        XCTAssertEqual(changed.triangles,base.triangles)
        XCTAssertEqual(result.entities[0].mesh?.textureCoordinates,mesh.textureCoordinates)
        XCTAssertEqual(result.entities[0].origin,solid.origin)
        XCTAssertNoThrow(try result.validate())
    }
    func testArrayDuplicatesCumulativeOffsetsAndUniqueIDs() throws {
        let a = box()
        let result = try EditorOperations.duplicate(document:ModelDocument(entities:[a]),ids:[a.id],count:3,delta:Vec3(3,0,0))
        XCTAssertEqual(result.entities.map { $0.origin.x },[0,3,6,9])
        XCTAssertEqual(Set(result.entities.map(\.id)).count,4)
    }
    func testNestedGroupsExpandSelectionAndExplodeOneLevel() throws {
        let a = box(-2), b = box(2), c = box(6)
        var result = try EditorOperations.group(document:ModelDocument(entities:[a,b,c]),ids:[a.id,b.id],name:"Inner",component:false)
        let inner = result.editor!.groups[0].id
        result = try EditorOperations.group(document:result,ids:[a.id,c.id],name:"Outer",component:false)
        let outer = result.editor!.groups.last!.id
        XCTAssertEqual(result.editor!.groups.first!.parentID,outer)
        XCTAssertEqual(result.effectiveSelection([a.id]),[a.id,b.id,c.id])
        result = try EditorOperations.explode(document:result,ids:[a.id])
        XCTAssertEqual(result.editor!.groups.map(\.id),[inner])
        XCTAssertEqual(result.entities[0].metadata?.groupID,inner)
        XCTAssertNil(result.entities[2].metadata?.groupID)
    }
    func testLinkedComponentSyncPreservesInstancePlacement() throws {
        let a = box()
        var doc = try EditorOperations.group(document:ModelDocument(entities:[a]),ids:[a.id],name:"Component",component:true)
        doc = try EditorOperations.duplicate(document:doc,ids:[a.id],count:1,delta:Vec3(10,0,0))
        doc.entities[0].height = 5
        doc = try EditorOperations.synchronizeComponents(document:doc,sourceID:a.id)
        XCTAssertEqual(doc.entities[1].height,5)
        XCTAssertEqual(doc.entities[1].origin.x,10,accuracy:1e-8)
        XCTAssertNotEqual(doc.entities[0].metadata?.groupID,doc.entities[1].metadata?.groupID)
    }
    func testLayerVisibilityAndLockingAreInherited() throws {
        let a = box()
        var doc = try EditorOperations.createLayer(document:ModelDocument(entities:[a]),name:"Walls")
        let layerID = doc.editor!.layers[0].id
        doc = try EditorOperations.assignLayer(document:doc,ids:[a.id],layerID:layerID)
        doc.editor!.layers[0].isVisible = false
        XCTAssertFalse(doc.entities[0].isVisible(in:doc))
        doc = try EditorOperations.setLocked(document:doc,ids:[a.id],locked:true)
        XCTAssertFalse(doc.entities[0].isEditable(in:doc))
        doc = try EditorOperations.setLocked(document:doc,ids:[a.id],locked:false)
        XCTAssertTrue(doc.entities[0].isEditable(in:doc))
    }
    func testOrganizationValidationRejectsCyclesAndMissingReferences() throws {
        let a = box(), id = UUID()
        let editor = EditorState(groups:[ModelGroup(id:id,name:"Loop",parentID:id)])
        XCTAssertThrowsError(try ModelDocument(entities:[a],editor:editor).validate())
        var bad = a; bad.metadata = EntityMetadata(layerID:UUID())
        XCTAssertThrowsError(try ModelDocument(entities:[bad]).validate())
    }
    func testInvalidTransformsAreRejected() throws {
        let a = box(), doc = ModelDocument(entities:[box()])
        XCTAssertThrowsError(try EditorOperations.scale(document:doc,ids:[a.id],factors:Vec3(0,1,1)))
        XCTAssertThrowsError(try EditorOperations.translate(document:doc,ids:[a.id],delta:Vec3(.infinity,0,0)))
        XCTAssertThrowsError(try EditorOperations.duplicate(document:doc,ids:[a.id],count:100_000,delta:Vec3(1,0,0)))
        XCTAssertThrowsError(try EditorOperations.mirror(document:doc,ids:[a.id],axis:"q"))
    }
    func testComponentSyncRespectsRotatedInstanceFrame() throws {
        let a = box()
        var doc = try EditorOperations.group(document:ModelDocument(entities:[a]),ids:[a.id],name:"Component",component:true)
        doc = try EditorOperations.duplicate(document:doc,ids:[a.id],count:1,delta:Vec3(10,0,0))
        let secondID = doc.entities[1].id
        doc = try EditorOperations.rotate(document:doc,ids:[secondID],radians:.pi/2)
        doc.entities[0].width = 4
        doc = try EditorOperations.synchronizeComponents(document:doc,sourceID:a.id)
        XCTAssertEqual(doc.entities[1].width,4)
        XCTAssertEqual(doc.entities[1].rotation,.pi/2,accuracy:1e-8)
        XCTAssertEqual(doc.entities[1].origin.x,10,accuracy:1e-8)
    }
    func testNestedGroupArrayKeepsRemappedHierarchy() throws {
        let a = box(-2), b = box(2), c = box(6)
        var doc = try EditorOperations.group(document:ModelDocument(entities:[a,b,c]),ids:[a.id,b.id],name:"Inner",component:false)
        doc = try EditorOperations.group(document:doc,ids:[a.id,c.id],name:"Outer",component:false)
        doc = try EditorOperations.duplicate(document:doc,ids:[a.id],count:1,delta:Vec3(0,0,10))
        XCTAssertEqual(doc.editor!.groups.count,4)
        XCTAssertEqual(doc.entities.count,6)
        XCTAssertEqual(doc.effectiveSelection([doc.entities[3].id]),Set(doc.entities[3...5].map(\.id)))
        XCTAssertEqual(doc.entities[3].origin.z,10,accuracy:1e-8)
        try doc.validate()
    }

    func testEditingContextSelectsDirectPartsAndNestedGroups() throws {
        let a=box(-2), b=box(2), c=box(6), outside=box(10)
        var doc=try EditorOperations.group(document:ModelDocument(entities:[a,b,c,outside]),ids:[a.id,b.id],name:"Inner",component:false)
        let inner=doc.editor!.groups[0].id
        doc=try EditorOperations.group(document:doc,ids:[a.id,c.id],name:"Outer",component:false)
        let outer=doc.editor!.groups.last!.id
        XCTAssertEqual(doc.effectiveSelection([a.id],editingGroupID:outer),[a.id,b.id])
        XCTAssertEqual(doc.effectiveSelection([c.id],editingGroupID:outer),[c.id])
        XCTAssertEqual(doc.effectiveSelection([a.id],editingGroupID:inner),[a.id])
        XCTAssertEqual(doc.effectiveSelection([outside.id],editingGroupID:outer),[])
        let moved=try EditorOperations.translate(document:doc,ids:[a.id],delta:Vec3(1,0,0),editingGroupID:inner)
        XCTAssertEqual(moved.entities[0].origin.x,-1,accuracy:1e-8)
        XCTAssertEqual(moved.entities[1],doc.entities[1])
        XCTAssertEqual(moved.entities[2],doc.entities[2])
    }
    func testSignedProfileExtrusionRemainsValid() throws {
        let face=try GeometryTools.face(points:[Vec3(0,0,0),Vec3(2,0,0),Vec3(2,0,2),Vec3(0,0,2)])
        let solid=try GeometryTools.extrude(entity:face,distance:-2)
        XCTAssertEqual(solid.profileExtrusion,-2)
        try ModelDocument(entities:[solid]).validate()
    }

    func testGroupAndDuplicateWithinEditingContextKeepMembership() throws {
        let a=box(-2), b=box(2)
        var doc=try EditorOperations.group(document:ModelDocument(entities:[a,b]),ids:[a.id,b.id],name:"Outer",component:false)
        let outer=doc.editor!.groups[0].id
        doc=try EditorOperations.duplicate(document:doc,ids:[a.id],count:1,delta:Vec3(0,0,4),editingGroupID:outer)
        let copy=doc.entities.last!
        XCTAssertEqual(copy.metadata?.groupID,outer)
        doc=try EditorOperations.group(document:doc,ids:[a.id,copy.id],name:"Inner",component:false,editingGroupID:outer)
        let inner=doc.editor!.groups.last!.id
        XCTAssertEqual(doc.editor!.groups.last!.parentID,outer)
        XCTAssertEqual(doc.entities[0].metadata?.groupID,inner)
        XCTAssertEqual(doc.entities[1].metadata?.groupID,outer)
        doc=try EditorOperations.explode(document:doc,ids:[a.id],editingGroupID:outer)
        XCTAssertEqual(doc.entities[0].metadata?.groupID,outer)
        XCTAssertEqual(doc.entities.last!.metadata?.groupID,outer)
        XCTAssertEqual(doc.editor!.groups.count,1)
        try doc.validate()
    }

    func testWholeComponentScaleAndMirrorCreateUniqueDefinitions() throws {
        for reflect in [false,true] {
            let a=box()
            var doc=try EditorOperations.group(document:ModelDocument(entities:[a]),ids:[a.id],name:"Component",component:true)
            doc=try EditorOperations.duplicate(document:doc,ids:[a.id],count:1,delta:Vec3(10,0,0))
            let secondID=doc.entities[1].id
            let originalDefinition=doc.editor!.groups[0].componentID
            doc = reflect ? try EditorOperations.mirror(document:doc,ids:[secondID],axis:"x") : try EditorOperations.scale(document:doc,ids:[secondID],factors:Vec3(2,2,2))
            XCTAssertEqual(doc.editor!.groups[0].componentID,originalDefinition)
            XCTAssertNotEqual(doc.editor!.groups[1].componentID,originalDefinition)
            let transformed=doc.entities[1]
            doc.entities[0].height=5
            doc=try EditorOperations.synchronizeComponents(document:doc,sourceID:a.id)
            XCTAssertEqual(doc.entities[1],transformed)
        }
    }
    func testPartScaleInsideComponentRetainsLinkedDefinition() throws {
        let a=box()
        var doc=try EditorOperations.group(document:ModelDocument(entities:[a]),ids:[a.id],name:"Component",component:true)
        let groupID=doc.editor!.groups[0].id, definition=doc.editor!.groups[0].componentID
        doc=try EditorOperations.duplicate(document:doc,ids:[a.id],count:1,delta:Vec3(10,0,0))
        doc=try EditorOperations.scale(document:doc,ids:[a.id],factors:Vec3(2,2,2),editingGroupID:groupID)
        XCTAssertEqual(doc.editor!.groups[0].componentID,definition)
        doc=try EditorOperations.synchronizeComponents(document:doc,sourceID:a.id)
        XCTAssertEqual(doc.entities[1].mesh,doc.entities[0].mesh)
        XCTAssertEqual(doc.entities[1].origin.x-doc.entities[0].origin.x,10,accuracy:1e-8)
    }

    func testWrappingExistingComponentPreservesItsPartLinks() throws {
        let a=box()
        var doc=try EditorOperations.group(document:ModelDocument(entities:[a]),ids:[a.id],name:"Inner",component:true)
        doc=try EditorOperations.duplicate(document:doc,ids:[a.id],count:1,delta:Vec3(10,0,0))
        let partID=doc.entities[0].metadata?.componentPartID
        doc=try EditorOperations.group(document:doc,ids:[a.id],name:"Wrapper",component:true)
        XCTAssertEqual(doc.entities[0].metadata?.componentPartID,partID)
        doc.entities[0].height=7
        doc=try EditorOperations.synchronizeComponents(document:doc,sourceID:a.id)
        XCTAssertEqual(doc.entities[1].height,7)
        XCTAssertEqual(doc.entities[1].origin.x,10,accuracy:1e-8)
    }
    func testExplodingOrdinarySubgroupPreservesEnclosingComponentLinks() throws {
        let a=box()
        var doc=try EditorOperations.group(document:ModelDocument(entities:[a]),ids:[a.id],name:"Component",component:true)
        let component=doc.editor!.groups[0].id, partID=doc.entities[0].metadata?.componentPartID
        doc=try EditorOperations.group(document:doc,ids:[a.id],name:"Ordinary",component:false,editingGroupID:component)
        doc=try EditorOperations.duplicate(document:doc,ids:[a.id],count:1,delta:Vec3(10,0,0))
        doc=try EditorOperations.explode(document:doc,ids:[a.id],editingGroupID:component)
        XCTAssertEqual(doc.entities[0].metadata?.groupID,component)
        XCTAssertEqual(doc.entities[0].metadata?.componentPartID,partID)
        doc.entities[0].height=7
        doc=try EditorOperations.synchronizeComponents(document:doc,sourceID:a.id)
        XCTAssertEqual(doc.entities[1].height,7)
    }
    func testExplodingComponentToRootClearsPartIdentity() throws {
        let a=box()
        var doc=try EditorOperations.group(document:ModelDocument(entities:[a]),ids:[a.id],name:"Component",component:true)
        doc=try EditorOperations.duplicate(document:doc,ids:[a.id],count:1,delta:Vec3(10,0,0))
        doc=try EditorOperations.explode(document:doc,ids:[a.id])
        XCTAssertNil(doc.entities[0].metadata?.componentPartID)
        doc.entities[0].height=7
        doc=try EditorOperations.synchronizeComponents(document:doc,sourceID:a.id)
        XCTAssertEqual(doc.entities[1].height,2)
    }
    func testExplodingNestedComponentsCreatesDistinctEnclosingPartIdentities() throws {
        let a=box()
        var doc=try EditorOperations.group(document:ModelDocument(entities:[a]),ids:[a.id],name:"Inner",component:true)
        doc=try EditorOperations.duplicate(document:doc,ids:[a.id],count:1,delta:Vec3(10,0,0))
        let bID=doc.entities[1].id, innerPart=doc.entities[0].metadata?.componentPartID
        doc=try EditorOperations.group(document:doc,ids:[a.id,bID],name:"Outer",component:true)
        let outer=doc.editor!.groups.last!.id
        doc=try EditorOperations.explode(document:doc,ids:[a.id],editingGroupID:outer)
        let aPart=doc.entities[0].metadata?.componentPartID
        XCTAssertNotNil(aPart)
        XCTAssertNotEqual(aPart,innerPart)
        XCTAssertEqual(doc.entities[1].metadata?.componentPartID,innerPart)
        doc=try EditorOperations.explode(document:doc,ids:[bID],editingGroupID:outer)
        XCTAssertNotNil(doc.entities[1].metadata?.componentPartID)
        XCTAssertNotEqual(doc.entities[1].metadata?.componentPartID,aPart)
        doc=try EditorOperations.duplicate(document:doc,ids:[a.id],count:1,delta:Vec3(0,0,10))
        doc.entities[0].height=7
        doc=try EditorOperations.synchronizeComponents(document:doc,sourceID:a.id)
        XCTAssertEqual(doc.entities[2].height,7)
        XCTAssertEqual(doc.entities[3].height,2)
        try doc.validate()
    }

}
