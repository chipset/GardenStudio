import XCTest
@testable import GardenStudioCore

final class ModelingAuditRegressionTests:XCTestCase {
    private func componentFace() throws -> (ModelDocument, GardenEntity) {
        let face=try GeometryTools.face(points:[Vec3(-1,0,-1),Vec3(-1,0,1),Vec3(1,0,1),Vec3(1,0,-1)])
        let doc=try EditorOperations.group(document:ModelDocument(entities:[face]),ids:[face.id],name:"Component",component:true)
        return (doc,doc.entities[0])
    }
    func testSweepCreatesIndependentComponentPartInsteadOfAliasingItsSource() throws {
        let (original,face)=try componentFace()
        let swept=try GeometryTools.sweep(profile:face,path:[Vec3(0,0,0),Vec3(0,2,0)])
        XCTAssertNotEqual(swept.id,face.id)
        XCTAssertEqual(swept.metadata?.groupID,face.metadata?.groupID)
        XCTAssertNotEqual(swept.metadata?.componentPartID,face.metadata?.componentPartID)
        var doc=try EditorOperations.duplicate(document:original,ids:[face.id],count:1,delta:Vec3(10,0,0))
        let counterpart=doc.entities[1]
        doc.entities.append(swept)
        let result=try EditorOperations.synchronizeComponents(document:doc,sourceID:swept.id)
        XCTAssertEqual(result.entities[1],counterpart)
    }
    func testSplitCreatesDistinctComponentPartIdentities() throws {
        let (_,face)=try componentFace()
        let pieces=try GeometryTools.split(entity:face,lineStart:Vec3(0,0,-2),lineEnd:Vec3(0,0,2))
        let parts=pieces.compactMap{$0.metadata?.componentPartID}
        XCTAssertEqual(parts.count,2)
        XCTAssertEqual(Set(parts).count,2)
        XCTAssertFalse(parts.contains(try XCTUnwrap(face.metadata?.componentPartID)))
        XCTAssertTrue(pieces.allSatisfy{$0.metadata?.groupID==face.metadata?.groupID})
    }
    func testSplittingAComponentLineGivesTheAdditionalPieceItsOwnPart() throws {
        let line=GardenEntity(kind:.line,origin:Vec3(0,0,0),width:2,depth:0)
        let doc=try EditorOperations.group(document:ModelDocument(entities:[line]),ids:[line.id],name:"Wire component",component:true)
        let group=try XCTUnwrap(doc.entities[0].metadata?.groupID)
        let originalPart=try XCTUnwrap(doc.entities[0].metadata?.componentPartID)
        let result=try GeometryTools.connectLine(document:doc,start:Vec3(1,0,0),end:Vec3(1,0,1),editingGroupID:group)
        let parts=result.entities.compactMap{$0.metadata?.componentPartID}
        XCTAssertEqual(parts.count,2)
        XCTAssertEqual(Set(parts).count,2)
        XCTAssertEqual(result.entities.first{$0.id==line.id}?.metadata?.componentPartID,originalPart)
    }
    func testShowAllCanRevealLockedHiddenGeometryWithoutUnlockingIt() throws {
        var entity=GardenEntity(kind:.rectangle,origin:Vec3(0,0,0),width:1,depth:1)
        entity.metadata=EntityMetadata(isHidden:true,isLocked:true)
        let doc=ModelDocument(entities:[entity])
        let result=try EditorOperations.setHidden(document:doc,ids:[entity.id],hidden:false)
        XCTAssertFalse(try XCTUnwrap(result.entities[0].metadata).isHidden)
        XCTAssertTrue(try XCTUnwrap(result.entities[0].metadata).isLocked)
    }
}
