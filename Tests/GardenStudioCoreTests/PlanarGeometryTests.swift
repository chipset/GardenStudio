import XCTest
@testable import GardenStudioCore

final class PlanarGeometryTests: XCTestCase {
    let square = [Vec3(0,0,0),Vec3(4,0,0),Vec3(4,0,4),Vec3(0,0,4)]
    func testConcaveFaceHasRealAreaAndProfile() throws {
        let face = try GeometryTools.face(points: [Vec3(0,0,0),Vec3(3,0,0),Vec3(3,0,1),Vec3(1,0,1),Vec3(1,0,3),Vec3(0,0,3)])
        XCTAssertEqual(area(try face.triangulatedMesh()),5,accuracy:1e-7)
        XCTAssertEqual(face.profile?.outer.count,6)
        try ModelDocument(entities:[face]).validate()
    }
    func testHoleTriangulationAndExtrusionAreWatertight() throws {
        let face = try GeometryTools.face(points:square, holes:[[Vec3(1,0,1),Vec3(1,0,3),Vec3(3,0,3),Vec3(3,0,1)]])
        XCTAssertEqual(area(try face.triangulatedMesh()),12,accuracy:1e-7)
        let solid = try GeometryTools.extrude(entity:face,distance:2)
        XCTAssertEqual(abs(volume(try solid.triangulatedMesh())),24,accuracy:1e-6)
        XCTAssertTrue(isClosed(try solid.triangulatedMesh()))
        let smaller = try GeometryTools.extrude(entity:solid,distance:1)
        XCTAssertEqual(abs(volume(try smaller.triangulatedMesh())),12,accuracy:1e-6)
    }
    func testExtrusionOnArbitraryPlanePreservesNormalAndTransform() throws {
        var face = try GeometryTools.face(points:[Vec3(0,0,0),Vec3(2,0,0),Vec3(2,3,0),Vec3(0,3,0)])
        face.origin = Vec3(5,2,9); face.rotation = .pi/2
        let solid = try GeometryTools.extrude(entity:face,distance:4)
        XCTAssertEqual(abs(volume(try solid.triangulatedMesh())),24,accuracy:1e-6)
        let n = try GeometryTools.normal(of:face)
        XCTAssertEqual(abs(n.x),1,accuracy:1e-7)
        XCTAssertTrue(isClosed(try solid.triangulatedMesh()))
    }
    func testInvalidProfilesAreRejected() throws {
        XCTAssertThrowsError(try GeometryTools.face(points:[Vec3(0,0,0),Vec3(3,0,3),Vec3(3,0,0),Vec3(0,0,3)]))
        XCTAssertThrowsError(try GeometryTools.face(points:[Vec3(0,0,0),Vec3(3,0,0),Vec3(3,1,3),Vec3(0,0,3)]))
        XCTAssertThrowsError(try GeometryTools.face(points:square,holes:[[Vec3(3,0,3),Vec3(5,0,3),Vec3(5,0,5),Vec3(3,0,5)]]))
        XCTAssertThrowsError(try GeometryTools.face(points:[Vec3(0,0,0),Vec3(.nan,0,0),Vec3(1,0,1)]))
    }
    func testOffsetAndHoleOperations() throws {
        let face = try GeometryTools.face(points:square)
        XCTAssertEqual(area(try GeometryTools.offset(entity:face,distance:1).triangulatedMesh()),36,accuracy:1e-6)
        XCTAssertEqual(area(try GeometryTools.offset(entity:face,distance:-1).triangulatedMesh()),4,accuracy:1e-6)
        XCTAssertThrowsError(try GeometryTools.offset(entity:face,distance:-3))
        let hole = try GeometryTools.addHole(entity:face,points:[Vec3(1,0,1),Vec3(3,0,1),Vec3(3,0,3),Vec3(1,0,3)])
        XCTAssertEqual(area(try hole.triangulatedMesh()),12,accuracy:1e-6)
    }
    func testSplitFaceAndRejectUnsupportedHoleCrossing() throws {
        let face = try GeometryTools.face(points:square)
        let parts = try GeometryTools.split(entity:face,lineStart:Vec3(2,0,-1),lineEnd:Vec3(2,0,5))
        XCTAssertEqual(parts.count,2)
        XCTAssertEqual(try parts.reduce(0) { $0 + area(try $1.triangulatedMesh()) },16,accuracy:1e-6)
        XCTAssertNotEqual(parts[0].id,parts[1].id)
        let hole = try GeometryTools.addHole(entity:face,points:[Vec3(1,0,1),Vec3(3,0,1),Vec3(3,0,3),Vec3(1,0,3)])
        XCTAssertThrowsError(try GeometryTools.split(entity:hole,lineStart:Vec3(2,0,-1),lineEnd:Vec3(2,0,5)))
    }
    func testWirePolygonArcAndFollowMe() throws {
        let polygon = try GeometryTools.polygon(center:Vec3(0,0,0),radius:1,sides:6,normal:Vec3(0,1,0))
        XCTAssertEqual(polygon.profile?.outer.count,6)
        let arc = try GeometryTools.arc(center:Vec3(0,0,0),start:Vec3(1,0,0),end:Vec3(0,0,1),segments:8)
        XCTAssertEqual(arc.mesh?.lineIndices.count,16)
        XCTAssertEqual(arc.mesh?.vertices.first,Vec3(1,0,0))
        let points = [Vec3(0,0,0),Vec3(1,0,0),Vec3(1,0,1),Vec3(0,0,1)]
        let wire = GardenEntity(kind:.mesh,origin:Vec3(0,0,0),width:1,depth:1,mesh:MeshData(vertices:points,lineIndices:[0,1,1,2,2,3,3,0]))
        XCTAssertEqual(area(try GeometryTools.faceFromWire(entity:wire).triangulatedMesh()),1,accuracy:1e-6)
        let profile = try GeometryTools.face(points:[Vec3(-1,-1,0),Vec3(1,-1,0),Vec3(1,1,0),Vec3(-1,1,0)])
        let solid = try GeometryTools.sweep(profile:profile,path:[Vec3(0,0,0),Vec3(0,0,3),Vec3(0,3,3)])
        XCTAssertTrue(isClosed(try solid.triangulatedMesh()))
        XCTAssertEqual(volume(try solid.triangulatedMesh()),24,accuracy:1e-6)
        try ModelDocument(entities:[solid]).validate()
    }
    func testMultipleHolesConcaveBoundaryAndNegativeExtrusion() throws {
        let outer=[Vec3(0,0,0),Vec3(8,0,0),Vec3(8,0,3),Vec3(6,0,3),Vec3(6,0,6),Vec3(0,0,6)]
        let holes=[[Vec3(1,0,1),Vec3(2,0,1),Vec3(2,0,2),Vec3(1,0,2)],[Vec3(3,0,3),Vec3(5,0,3),Vec3(5,0,5),Vec3(3,0,5)]]
        let face=try GeometryTools.face(points:outer,holes:holes)
        XCTAssertEqual(area(try face.triangulatedMesh()),37,accuracy:1e-6)
        let solid=try GeometryTools.extrude(entity:face,distance:-2)
        XCTAssertEqual(volume(try solid.triangulatedMesh()),74,accuracy:1e-6)
        XCTAssertTrue(isClosed(try solid.triangulatedMesh()))
        let expanded=try GeometryTools.offset(entity:face,distance:0.2)
        XCTAssertGreaterThan(area(try expanded.triangulatedMesh()),37)
    }
    func testPrimitiveTopologyEditsRetainHeightAndMetadata() throws {
        var entity=GardenEntity(name:"Box",kind:.rectangle,origin:Vec3(2,0,2),width:4,depth:4,height:3)
        entity.metadata=EntityMetadata(isHidden:true,groupID:UUID())
        entity.surface=SurfaceMaterial(name:"Paint",colorHex:"#123456",faceOverrides:[FaceSurface(triangleIndices:[0],colorHex:"#654321")])
        let result=try GeometryTools.offset(entity:entity,distance:1)
        XCTAssertEqual(abs(volume(try result.triangulatedMesh())),108,accuracy:1e-6)
        XCTAssertEqual(result.id,entity.id)
        XCTAssertEqual(result.metadata,entity.metadata)
        XCTAssertEqual(result.surface?.colorHex,"#123456")
        XCTAssertTrue(result.surface?.faceOverrides.isEmpty == true)
        let hole=try GeometryTools.addHole(entity:entity,points:[Vec3(1,0,1),Vec3(3,0,1),Vec3(3,0,3),Vec3(1,0,3)])
        XCTAssertEqual(abs(volume(try hole.triangulatedMesh())),36,accuracy:1e-6)
        let topHole=try GeometryTools.addHole(entity:entity,points:[Vec3(1,3,1),Vec3(3,3,1),Vec3(3,3,3),Vec3(1,3,3)])
        XCTAssertEqual(abs(volume(try topHole.triangulatedMesh())),36,accuracy:1e-6)
        let pieces=try GeometryTools.split(entity:entity,lineStart:Vec3(2,0,-1),lineEnd:Vec3(2,0,5))
        XCTAssertEqual(try pieces.reduce(0){$0+abs(volume(try $1.triangulatedMesh()))},48,accuracy:1e-6)
    }
    func testWireValidationAndPathReversalNeverCrash() throws {
        let invalid=GardenEntity(kind:.mesh,origin:Vec3(0,0,0),width:1,depth:1,mesh:MeshData(vertices:[Vec3(0,0,0),Vec3(1,0,0)],lineIndices:[0,1,1,0]))
        XCTAssertThrowsError(try GeometryTools.faceFromWire(entity:invalid))
        let profile=try GeometryTools.face(points:[Vec3(-1,-1,0),Vec3(1,-1,0),Vec3(1,1,0),Vec3(-1,1,0)])
        XCTAssertThrowsError(try GeometryTools.sweep(profile:profile,path:[Vec3(0,0,0),Vec3(0,0,2),Vec3(0,0,0)]))
        XCTAssertThrowsError(try GeometryTools.sweep(profile:profile,path:[Vec3(0,0,0),Vec3(0,0,0)]))
        XCTAssertThrowsError(try GeometryTools.arc(center:Vec3(0,0,0),start:Vec3(1,0,0),end:Vec3(-1,0,0)))
        XCTAssertThrowsError(try GeometryTools.sweep(profile:profile,path:[Vec3(0,0,0),Vec3(0,0,4),Vec3(4,0,4),Vec3(4,0,0),Vec3(-1,0,3)]))
        XCTAssertThrowsError(try GeometryTools.sweep(profile:profile,path:[Vec3(0,0,0),Vec3(0,0,0.5),Vec3(0,0.5,0.5)]))
    }
    func testAdjacentLineLoopsCreateFacesAfterExistingCyclesAndBranches() throws {
        for withBranches in [false, true] {
            var document = ModelDocument()
            let square = [Vec3(0,0,0),Vec3(2,0,0),Vec3(2,0,2),Vec3(0,0,2)]
            for i in square.indices {
                document = try GeometryTools.connectLine(document: document, start: square[i], end: square[(i+1)%4])
            }
            if withBranches {
                document = try GeometryTools.connectLine(document: document, start: Vec3(2,0,2), end: Vec3(3,0,1))
                document = try GeometryTools.connectLine(document: document, start: Vec3(2,0,0), end: Vec3(2,2,0))
            }
            for x in [2.0,4.0] {
                for (start,end) in [(Vec3(x,0,0),Vec3(x+2,0,0)),
                                    (Vec3(x+2,0,0),Vec3(x+2,0,2)),
                                    (Vec3(x+2,0,2),Vec3(x,0,2))] {
                    document = try GeometryTools.connectLine(document: document, start: start, end: end)
                }
            }
            let faces = document.entities.filter { $0.profile != nil }
            XCTAssertEqual(faces.count,3)
            XCTAssertEqual(try faces.reduce(0) { $0 + area(try $1.triangulatedMesh()) },12,accuracy:1e-6)
            for face in faces { XCTAssertEqual(area(try face.triangulatedMesh()),4,accuracy:1e-6) }
        }
    }
    func testCreateFaceRejectsExistingSurfacesWithoutFlatteningSolids() throws {
        let face = try GeometryTools.face(points:square)
        let solid = try GeometryTools.extrude(entity:face,distance:3)
        let snapshot = solid
        XCTAssertThrowsError(try GeometryTools.faceFromWire(entity:face))
        XCTAssertThrowsError(try GeometryTools.faceFromWire(entity:solid))
        XCTAssertEqual(solid,snapshot)
        XCTAssertEqual(abs(volume(try solid.triangulatedMesh())),48,accuracy:1e-6)
    }
    func testClosingExistingBoundaryDoesNotDuplicateFaceAndDegenerateLoopsStayWires() throws {
        var document=ModelDocument(entities:[try GeometryTools.face(points:square)])
        for i in square.indices {
            document=try GeometryTools.connectLine(document:document,start:square[i],end:square[(i+1)%square.count])
        }
        XCTAssertEqual(document.entities.filter{$0.profile != nil}.count,1)
        var wire=ModelDocument()
        for (a,b) in [(Vec3(0,0,0),Vec3(1,0,0)),(Vec3(1,0,0),Vec3(2,0,0)),(Vec3(2,0,0),Vec3(0,0,0))] {
            wire=try GeometryTools.connectLine(document:wire,start:a,end:b)
        }
        XCTAssertTrue(wire.entities.allSatisfy{$0.profile == nil})
    }
    func testAdjacentLoopsOnVerticalPlaneIgnoreNonplanarShortcuts() throws {
        var document=ModelDocument()
        let first=[Vec3(0,0,5),Vec3(2,0,5),Vec3(2,2,5),Vec3(0,2,5)]
        for i in first.indices {document=try GeometryTools.connectLine(document:document,start:first[i],end:first[(i+1)%4])}
        // A shorter graph path outside the face's plane must not suppress the planar loop.
        for (a,b) in [(Vec3(2,0,5),Vec3(3,1,6)),(Vec3(3,1,6),Vec3(4,2,5)),
                      (Vec3(2,0,5),Vec3(4,0,5)),(Vec3(4,0,5),Vec3(4,2,5)),
                      (Vec3(4,2,5),Vec3(2,2,5))] {
            document=try GeometryTools.connectLine(document:document,start:a,end:b)
        }
        let planarFaces=document.entities.filter { entity in
            guard let profile=entity.profile else{return false}
            return profile.outer.allSatisfy{abs($0.z-5)<1e-6}
        }
        XCTAssertEqual(planarFaces.count,2)
        XCTAssertEqual(try planarFaces.reduce(0){$0+area(try $1.triangulatedMesh())},8,accuracy:1e-6)
    }
    func testConnectedLineLoopAutomaticallyCreatesOneFaceAndDiagonalSplitsIt() throws {
        var document=ModelDocument()
        let points=[Vec3(0,0,0),Vec3(4,0,0),Vec3(4,0,4),Vec3(0,0,4)]
        for i in points.indices {document=try GeometryTools.connectLine(document:document,start:points[i],end:points[(i+1)%points.count])}
        XCTAssertEqual(document.entities.filter{$0.kind == .line}.count,4)
        XCTAssertEqual(document.entities.filter{$0.profile != nil}.count,1)
        XCTAssertEqual(area(try document.entities.first(where:{$0.profile != nil})!.triangulatedMesh()),16,accuracy:1e-6)
        document=try GeometryTools.connectLine(document:document,start:points[0],end:points[2])
        XCTAssertEqual(document.entities.filter{$0.kind == .line}.count,5)
        let faces=document.entities.filter{$0.profile != nil}
        XCTAssertEqual(faces.count,2)
        XCTAssertEqual(try faces.reduce(0){$0+area(try $1.triangulatedMesh())},16,accuracy:1e-6)
    }
    func testAutomaticTopologyLeavesHiddenProfilesAndLinesUnchanged() throws {
        for layerHidden in [false,true] {
            let layer=ModelLayer(name:"Invisible",isVisible:false)
            let metadata=EntityMetadata(isHidden:!layerHidden,layerID:layerHidden ? layer.id:nil)
            let editor=layerHidden ? EditorState(layers:[layer]):nil
            var face=try GeometryTools.face(points:square);face.metadata=metadata
            let cut=try GeometryTools.connectLine(document:ModelDocument(entities:[face],editor:editor),start:Vec3(2,0,-1),end:Vec3(2,0,5))
            XCTAssertEqual(cut.entities.first(where:{$0.id==face.id}),face)
            XCTAssertEqual(cut.entities.count,2)
            let line=GardenEntity(kind:.line,origin:Vec3(0,0,0),width:4,depth:0,metadata:metadata)
            let start=Vec3(2,0,0.0000005)
            let drawn=try GeometryTools.connectLine(document:ModelDocument(entities:[line],editor:editor),start:start,end:Vec3(2,0,2))
            XCTAssertEqual(drawn.entities.first(where:{$0.id==line.id}),line)
            XCTAssertEqual(drawn.entities.count,2)
            XCTAssertEqual(drawn.entities.last?.origin,start)
        }
    }
    func testHiddenProfilesDoNotReceiveHolesOrSuppressVisibleFaces() throws {
        for layerHidden in [false,true] {
            let layer=ModelLayer(name:"Invisible",isVisible:false)
            var face=try GeometryTools.face(points:square)
            face.metadata=EntityMetadata(isHidden:!layerHidden,layerID:layerHidden ? layer.id:nil)
            let editor=layerHidden ? EditorState(layers:[layer]):nil
            for outline in [square,[Vec3(1,0,1),Vec3(3,0,1),Vec3(3,0,3),Vec3(1,0,3)]] {
                var document=ModelDocument(entities:[face],editor:editor)
                for i in outline.indices {
                    document=try GeometryTools.connectLine(document:document,start:outline[i],end:outline[(i+1)%outline.count])
                }
                XCTAssertEqual(document.entities.first(where:{$0.id==face.id}),face)
                XCTAssertEqual(document.entities.filter{$0.profile != nil && $0.isVisible(in:document)}.count,1)
            }
        }
    }
    func testConnectedLineCutsAPlanarFaceAndRespectsGroupContext() throws {
        let face=try GeometryTools.face(points:square)
        var document=try GeometryTools.connectLine(document:ModelDocument(entities:[face]),start:Vec3(2,0,-1),end:Vec3(2,0,5))
        XCTAssertEqual(document.entities.filter{$0.profile != nil}.count,2)
        XCTAssertEqual(document.entities.filter{$0.kind == .line}.count,1)
        let group=ModelGroup(name:"Group")
        var grouped=face;grouped.metadata=EntityMetadata(groupID:group.id)
        document=ModelDocument(entities:[grouped],editor:EditorState(groups:[group]))
        let outside=try GeometryTools.connectLine(document:document,start:Vec3(2,0,-1),end:Vec3(2,0,5))
        XCTAssertEqual(outside.entities.filter{$0.profile != nil}.count,1)
        let inside=try GeometryTools.connectLine(document:document,start:Vec3(2,0,-1),end:Vec3(2,0,5),editingGroupID:group.id)
        XCTAssertEqual(inside.entities.filter{$0.profile != nil}.count,2)
        XCTAssertTrue(inside.entities.allSatisfy{$0.metadata?.groupID == group.id})
    }
    func testLineClosureSnapsEndpointsAndRejectsDuplicate() throws {
        var document=ModelDocument()
        document=try GeometryTools.connectLine(document:document,start:Vec3(0,0,0),end:Vec3(2,0,0))
        document=try GeometryTools.connectLine(document:document,start:Vec3(2,0,0),end:Vec3(1,0,2))
        document=try GeometryTools.connectLine(document:document,start:Vec3(1,0,2),end:Vec3(0.0000001,0,0))
        XCTAssertEqual(document.entities.filter{$0.profile != nil}.count,1)
        XCTAssertThrowsError(try GeometryTools.connectLine(document:document,start:Vec3(0,0,0),end:Vec3(2,0,0)))
    }
    func testLineEndpointsConnectToEdgeInteriorsAndNestedLoopsPartitionFace() throws {
        let base=GardenEntity(kind:.line,origin:Vec3(0,0,0),width:4,depth:0)
        var document=ModelDocument(entities:[base])
        document=try GeometryTools.connectLine(document:document,start:Vec3(2,0,0),end:Vec3(2,0,2))
        document=try GeometryTools.connectLine(document:document,start:Vec3(2,0,2),end:Vec3(4,0,2))
        document=try GeometryTools.connectLine(document:document,start:Vec3(4,0,2),end:Vec3(4,0,0))
        XCTAssertEqual(document.entities.filter{$0.profile != nil}.count,1)
        XCTAssertEqual(area(try document.entities.first(where:{$0.profile != nil})!.triangulatedMesh()),4,accuracy:1e-6)
        document=ModelDocument(entities:[try GeometryTools.face(points:square)])
        let inner=[Vec3(1,0,1),Vec3(3,0,1),Vec3(3,0,3),Vec3(1,0,3)]
        for i in inner.indices {document=try GeometryTools.connectLine(document:document,start:inner[i],end:inner[(i+1)%inner.count])}
        let faces=document.entities.filter{$0.profile != nil}
        XCTAssertEqual(faces.count,2)
        XCTAssertEqual(faces.filter{$0.profile?.holes.count==1}.count,1)
        XCTAssertEqual(try faces.reduce(0){$0+area(try $1.triangulatedMesh())},16,accuracy:1e-6)
    }
    func testEnclosingLoopPartitionsExistingFacesRegardlessOfDrawingOrder() throws {
        let inner=[Vec3(1,0,1),Vec3(2,0,1),Vec3(2,0,2),Vec3(1,0,2)]
        for outlines in [[inner,square],[square,inner]] {
            var document=ModelDocument()
            for outline in outlines {document=try closeLoop(outline,in:document)}
            let faces=document.entities.filter{$0.profile != nil}
            XCTAssertEqual(faces.count,2)
            XCTAssertEqual(faces.compactMap{$0.profile?.holes.count}.sorted(),[0,1])
            XCTAssertEqual(try faces.reduce(0){$0+area(try $1.triangulatedMesh())},16,accuracy:1e-6)
        }
    }
    func testEnclosingLoopPreservesMultipleInteriorFaces() throws {
        let first=try GeometryTools.face(points:[Vec3(0.5,0,0.5),Vec3(1.5,0,0.5),Vec3(1.5,0,1.5),Vec3(0.5,0,1.5)],colorHex:"#AA1122")
        let second=try GeometryTools.face(points:[Vec3(2.5,0,2.5),Vec3(3.5,0,2.5),Vec3(3.5,0,3.5),Vec3(2.5,0,3.5)])
        let document=try closeLoop(square,in:ModelDocument(entities:[first,second]))
        XCTAssertEqual(document.entities.first{$0.id==first.id},first)
        XCTAssertEqual(document.entities.first{$0.id==second.id},second)
        let faces=document.entities.filter{$0.profile != nil}
        XCTAssertEqual(faces.last?.profile?.holes.count,2)
        XCTAssertEqual(try faces.reduce(0){$0+area(try $1.triangulatedMesh())},16,accuracy:1e-6)
    }
    func testEnclosingLoopDoesNotCreateNestedDuplicateHoles() throws {
        let middle=[Vec3(1,0,1),Vec3(3,0,1),Vec3(3,0,3),Vec3(1,0,3)]
        let hole=[Vec3(1.5,0,1.5),Vec3(2.5,0,1.5),Vec3(2.5,0,2.5),Vec3(1.5,0,2.5)]
        let ring=try GeometryTools.face(points:middle,holes:[hole])
        let island=try GeometryTools.face(points:hole)
        for existing in [[ring],[ring,island]] {
            let document=try closeLoop(square,in:ModelDocument(entities:existing))
            for face in existing {XCTAssertEqual(document.entities.first{$0.id==face.id},face)}
            XCTAssertEqual(document.entities.last?.profile?.holes.count,1)
            XCTAssertEqual(try document.entities.filter{$0.profile != nil}.reduce(0){$0+area(try $1.triangulatedMesh())},existing.count==1 ? 15:16,accuracy:1e-6)
        }
    }
    func testEnclosingLoopRespectsVisibilityLocksAndEditingContext() throws {
        let group=ModelGroup(name:"Inside")
        let inner=[Vec3(1,0,1),Vec3(2,0,1),Vec3(2,0,2),Vec3(1,0,2)]
        for hidden in [false,true] {
            var existing=try GeometryTools.face(points:inner,colorHex:"#AA1122")
            existing.metadata=EntityMetadata(isHidden:hidden,isLocked:true,groupID:group.id)
            let source=ModelDocument(entities:[existing],editor:EditorState(groups:[group]))
            let outside=try closeLoop(square,in:source)
            XCTAssertEqual(outside.entities.last?.profile?.holes.count,0)
            let inside=try closeLoop(square,in:source,context:group.id)
            XCTAssertEqual(inside.entities.first{$0.id==existing.id},existing)
            XCTAssertEqual(inside.entities.last?.profile?.holes.count,hidden ? 0:1)
            XCTAssertEqual(inside.entities.last?.metadata?.groupID,group.id)
        }
    }
    func testEnclosingTouchingInteriorRegionsRejectsAtomically() throws {
        let first=try GeometryTools.face(points:[Vec3(1,0,1),Vec3(2,0,1),Vec3(2,0,2),Vec3(1,0,2)])
        let second=try GeometryTools.face(points:[Vec3(2,0,1),Vec3(3,0,1),Vec3(3,0,2),Vec3(2,0,2)])
        var document=ModelDocument(entities:[first,second])
        for i in 0..<3 {document=try GeometryTools.connectLine(document:document,start:square[i],end:square[i+1])}
        let before=document
        XCTAssertThrowsError(try GeometryTools.connectLine(document:document,start:square[3],end:square[0]))
        XCTAssertEqual(document,before)
    }
    private func closeLoop(_ outline:[Vec3],in document:ModelDocument,context:UUID?=nil) throws -> ModelDocument {
        var result=document
        for i in outline.indices {result=try GeometryTools.connectLine(document:result,start:outline[i],end:outline[(i+1)%outline.count],editingGroupID:context)}
        return result
    }
    private func area(_ mesh:MeshData)->Double { stride(from:0,to:mesh.triangles.count,by:3).reduce(0) { sum,i in let a=mesh.vertices[mesh.triangles[i]],b=mesh.vertices[mesh.triangles[i+1]],c=mesh.vertices[mesh.triangles[i+2]];let x=(b.y-a.y)*(c.z-a.z)-(b.z-a.z)*(c.y-a.y),y=(b.z-a.z)*(c.x-a.x)-(b.x-a.x)*(c.z-a.z),z=(b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x);return sum+sqrt(x*x+y*y+z*z)/2 } }
    private func volume(_ mesh:MeshData)->Double { stride(from:0,to:mesh.triangles.count,by:3).reduce(0) { sum,i in let a=mesh.vertices[mesh.triangles[i]],b=mesh.vertices[mesh.triangles[i+1]],c=mesh.vertices[mesh.triangles[i+2]];return sum+(a.x*(b.y*c.z-b.z*c.y)+a.y*(b.z*c.x-b.x*c.z)+a.z*(b.x*c.y-b.y*c.x))/6 } }
    private func isClosed(_ mesh:MeshData)->Bool { var edges:[String:Int]=[:]; for i in stride(from:0,to:mesh.triangles.count,by:3) {let a=mesh.triangles[i],b=mesh.triangles[i+1],c=mesh.triangles[i+2];for pair in [(a,b),(b,c),(c,a)] {let key="\(min(pair.0,pair.1)),\(max(pair.0,pair.1))";edges[key,default:0]+=1} };return edges.values.allSatisfy{$0==2} }
}
