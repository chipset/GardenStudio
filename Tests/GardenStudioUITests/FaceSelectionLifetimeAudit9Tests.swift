import XCTest
import AppKit
import GardenStudioCore
@testable import GardenStudioUI
final class FaceSelectionLifetimeAudit9Tests:XCTestCase {
    private func entity()->GardenEntity {
        let mesh=MeshData(vertices:[Vec3(0,0,0),Vec3(1,0,0),Vec3(0,0,1),Vec3(3,0,0),Vec3(4,0,0),Vec3(3,0,1)],triangles:[0,2,1,3,5,4])
        return GardenEntity(kind:.mesh,origin:Vec3(0,0,0),width:4,depth:1,mesh:mesh)
    }
    private func view(_ first:GardenEntity,_ extra:[GardenEntity]=[])->ModelViewport {
        let view=ModelViewport(frame:NSRect(x:0,y:0,width:800,height:600));view.document=ModelDocument(entities:[first]+extra);view.selectedIDs=[first.id];view.recordFaceSelection(owner:first.id,indices:[0]);return view
    }
    func testGeometryReplacementWithSameIDInvalidatesOldFacePick() {
        let first=entity(),view=view(first)
        var replaced=first;replaced.mesh!.triangles=[3,5,4,0,2,1]
        view.document=ModelDocument(entities:[replaced])
        XCTAssertTrue(view.selectedFaceIndices.isEmpty,"The old index now names a different physical face")
        view.document=ModelDocument(entities:[first])
        XCTAssertTrue(view.selectedFaceIndices.isEmpty,"Undo must not resurrect an obsolete face pick")
    }
    func testSwitchingSelectionAwayAndBackRequiresAFreshFacePick() {
        let first=entity();var second=first;second.id=UUID();second.origin.x=10
        let view=view(first,[second]);view.selectedIDs=[second.id];view.selectedIDs=[first.id]
        XCTAssertTrue(view.selectedFaceIndices.isEmpty)
    }
    func testPaintOnlyChangesAndRigidMoveKeepTheSameFaceIndices() {
        let first=entity(),view=view(first)
        var painted=first;painted.surface=SurfaceMaterial(colorHex:"#AA3300")
        view.document=ModelDocument(entities:[painted]);XCTAssertEqual(view.selectedFaceIndices,[0])
        painted.origin=Vec3(4,2,1);painted.rotation=0.4
        view.document=ModelDocument(entities:[painted]);XCTAssertEqual(view.selectedFaceIndices,[0])
    }
    func testActualPickBeforeOwnerSelectionIsNotImmediatelyLost() {
        let first=entity();var second=first;second.id=UUID()
        let view=view(first,[second]);view.selectedIDs=[second.id]
        view.recordFaceSelection(owner:first.id,indices:[1]);view.selectedIDs=[first.id]
        XCTAssertEqual(view.selectedFaceIndices,[1])
    }
}
