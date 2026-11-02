import XCTest
@testable import SketchCore
final class RotationCompositionAudit8Tests:XCTestCase {
    func testOrdinaryRotationStillAppliesAfterLargeStoredRotation() throws {
        let item=SketchEntity(kind:.rectangle,origin:Vec3(0,0,0),width:2,depth:1,height:0.3,rotation:1e50)
        let before=try item.triangulatedMesh().vertices
        let delta=Double.pi/4
        let result=try EditorOperations.rotate(document:ModelDocument(entities:[item]),ids:[item.id],radians:delta)
        let actual=try result.entities[0].triangulatedMesh().vertices
        for (a,p) in zip(actual,before) {
            XCTAssertEqual(a.x,cos(delta)*p.x+sin(delta)*p.z,accuracy:1e-8)
            XCTAssertEqual(a.y,p.y,accuracy:1e-8)
            XCTAssertEqual(a.z,-sin(delta)*p.x+cos(delta)*p.z,accuracy:1e-8)
        }
    }
    func testLinkedComponentOrientationComposesLargeSourceFramePhase() throws {
        let definition=UUID(),part=UUID()
        let first=ModelGroup(name:"Source",componentID:definition,rotation:1e50)
        let second=ModelGroup(name:"Target",componentID:definition,rotation:0.3)
        let source=SketchEntity(kind:.rectangle,origin:Vec3(0,0,0),width:2,depth:1,height:0.3,rotation:1e50,metadata:EntityMetadata(groupID:first.id,componentPartID:part))
        let target=SketchEntity(kind:.rectangle,origin:Vec3(0,0,0),width:2,depth:1,height:0.3,rotation:0.3,metadata:EntityMetadata(groupID:second.id,componentPartID:part))
        let document=ModelDocument(entities:[source,target],editor:EditorState(groups:[first,second]))
        let rotated=try EditorOperations.rotate(document:document,ids:[source.id],radians:0.2,editingGroupID:first.id)
        let synced=try EditorOperations.synchronizeComponents(document:rotated,sourceID:source.id)
        let actual=try synced.entities[1].triangulatedMesh().vertices
        let expected=try SketchEntity(kind:.rectangle,origin:Vec3(0,0,0),width:2,depth:1,height:0.3,rotation:0.5).triangulatedMesh().vertices
        for (a,b) in zip(actual,expected) {
            XCTAssertEqual(a.x,b.x,accuracy:1e-8);XCTAssertEqual(a.z,b.z,accuracy:1e-8)
        }
    }
}
