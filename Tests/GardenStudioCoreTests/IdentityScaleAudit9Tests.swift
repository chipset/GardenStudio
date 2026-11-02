import XCTest
@testable import GardenStudioCore
final class IdentityScaleAudit9Tests:XCTestCase {
    func testIdentityScalePreservesEditablePrimitiveAndProfileGeometry() throws {
        let block=GardenEntity(name:"Editable block",kind:.rectangle,origin:Vec3(2,0,3),width:2,depth:1,height:0.2,rotation:0.4)
        let profile=try GeometryTools.face(points:[Vec3(0,0,0),Vec3(2,0,0),Vec3(2,0,1),Vec3(0,0,1)])
        let line=GardenEntity(kind:.line,origin:Vec3(0,0,2),width:2,depth:0)
        let document=ModelDocument(entities:[block,profile,line])
        let result=try EditorOperations.scale(document:document,ids:Set(document.entities.map(\.id)),factors:Vec3(1,1,1))
        XCTAssertEqual(result,document,"An identity scale must not discard primitive/profile editability or change line type")
    }
    func testIdentityScaleDoesNotMakeLinkedComponentsUnique() throws {
        let face=GardenEntity(kind:.rectangle,origin:Vec3(0,0,0),width:2,depth:1,height:0.2)
        let component=try EditorOperations.group(document:ModelDocument(entities:[face]),ids:[face.id],name:"Component",component:true)
        let linked=try EditorOperations.duplicate(document:component,ids:[face.id],count:1,delta:Vec3(4,0,0))
        let result=try EditorOperations.scale(document:linked,ids:[face.id],factors:Vec3(1,1,1))
        XCTAssertEqual(result,linked,"An identity operation must retain existing component links")
    }
}
