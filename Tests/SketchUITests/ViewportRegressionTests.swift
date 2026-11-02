import XCTest
import AppKit
import SceneKit
import SketchCore
@testable import SketchUI

private final class MemoryGeometryPasteboard:GeometryPasteboard {
    var values:[NSPasteboard.PasteboardType:Data]=[:]
    var acceptsWrites=true
    func data(forType type:NSPasteboard.PasteboardType)->Data?{values[type]}
    func string(forType type:NSPasteboard.PasteboardType)->String?{values[type].flatMap{String(data:$0,encoding:.utf8)}}
    func writeGeometry(data:Data,text:String,type:NSPasteboard.PasteboardType)->Bool {
        guard acceptsWrites else{return false};values=[type:data,.string:Data(text.utf8)];return true
    }
}
final class ViewportRegressionTests: XCTestCase {
    func viewport() -> ModelViewport { ModelViewport(frame:NSRect(x:0,y:0,width:800,height:600)) }
    func testMillimeterAndFlatGeometryMatchesCoreWithAndWithoutMaterial() throws {
        for kind in [ShapeKind.rectangle,.circle] {
            for height in [0.0,0.001] {
                for textured in [false,true] {
                    var entity=SketchEntity(kind:kind,origin:Vec3(0,0,0),width:0.001,depth:0.002,height:height)
                    if textured {entity.surface=SurfaceMaterial(colorHex:"#112233")}
                    let view=viewport();view.document=ModelDocument(entities:[entity])
                    let node=try XCTUnwrap(view.models.childNodes.first)
                    let bounds=node.boundingBox,mesh=try entity.triangulatedMesh()
                    for (actual,expected) in [(Double(bounds.min.x),mesh.vertices.map(\.x).min()!),(Double(bounds.max.x),mesh.vertices.map(\.x).max()!),(Double(bounds.min.y),0),(Double(bounds.max.y),height),(Double(bounds.min.z),mesh.vertices.map(\.z).min()!),(Double(bounds.max.z),mesh.vertices.map(\.z).max()!)] {
                        XCTAssertEqual(actual,expected,accuracy:1e-8,"\(kind) material \(textured) height \(height)")
                    }
                }
            }
        }
    }
    func testFollowMeUsesWholeTwoEntityElbowAndBranchIsAtomic() throws {
        let profile=try GeometryTools.face(points:[Vec3(0,-0.1,-0.1),Vec3(0,0.1,-0.1),Vec3(0,0.1,0.1),Vec3(0,-0.1,0.1)])
        var source=ModelDocument(entities:[profile])
        source=try GeometryTools.connectLine(document:source,start:Vec3(0,0,0),end:Vec3(2,0,0))
        source=try GeometryTools.connectLine(document:source,start:Vec3(2,0,3),end:Vec3(2,0,0))
        let view=viewport();view.document=source;view.selectedIDs=Set(source.entities.map(\.id))
        view.performSweepAlongSelectedPath()
        XCTAssertEqual(view.document.entities.count,source.entities.count+1)
        let output=try XCTUnwrap(view.document.entities.last?.triangulatedMesh())
        XCTAssertGreaterThan(output.vertices.map(\.z).max()!,2.9)
        var branched=source;branched.entities.append(SketchEntity(kind:.line,origin:Vec3(2,0,0),width:1,depth:0))
        view.document=branched;view.selectedIDs=Set(branched.entities.map(\.id));view.performSweepAlongSelectedPath()
        XCTAssertEqual(view.document,branched)
    }
    func testNativeClipboardResponderAndMalformedPasteAreAtomic() throws {
        let view=viewport(),board=MemoryGeometryPasteboard();view.geometryPasteboard=board
        var locked=SketchEntity(kind:.rectangle,origin:Vec3(3,0,0),width:1,depth:1);locked.metadata=EntityMetadata(isLocked:true)
        let entity=SketchEntity(kind:.rectangle,origin:Vec3(0,0,0),width:1,depth:1)
        view.document=ModelDocument(entities:[entity,locked]);view.selectedIDs=[entity.id,locked.id]
        var commits=0,history=ModelHistory();var committed=view.document
        view.onDocumentChange={next in history.record(committed);committed=next;commits+=1}
        var statuses:[String]=[];view.onStatus={statuses.append($0)}
        view.cut(nil)
        XCTAssertEqual(view.document.entities.map(\.id),[locked.id],statuses.joined(separator:" | "));XCTAssertEqual(commits,1)
        view.paste(nil)
        XCTAssertEqual(view.document.entities.count,2);XCTAssertNotEqual(view.document.entities.last?.id,entity.id);XCTAssertEqual(commits,2)
        let before=view.document
        board.values=[.string:Data("{broken".utf8)];view.paste(nil)
        XCTAssertEqual(view.document,before);XCTAssertEqual(commits,2)
        view.selectAll(nil);XCTAssertEqual(view.selectedIDs,Set(before.entities.map(\.id)))
        board.acceptsWrites=false;view.cut(nil)
        XCTAssertEqual(view.document,before);XCTAssertEqual(commits,2)
        let undone=try XCTUnwrap(history.undo(current:view.document))
        XCTAssertEqual(undone.entities.map(\.id),[locked.id])
        XCTAssertEqual(history.redo(current:undone),before)
    }
    func testSelectAllSeedsVisibleGroupsAndContextPasteDetachesPartialSelection() throws {
        let group=ModelGroup(name:"Group")
        var visible=SketchEntity(kind:.rectangle,origin:Vec3(0,0,0),width:1,depth:1)
        var hidden=visible;hidden.id=UUID();hidden.origin.x=2
        var outside=visible;outside.id=UUID();outside.origin.x=4
        visible.metadata=EntityMetadata(groupID:group.id)
        hidden.metadata=EntityMetadata(isHidden:true,groupID:group.id)
        outside.metadata=EntityMetadata(isHidden:true)
        let view=viewport();view.geometryPasteboard=MemoryGeometryPasteboard()
        view.document=ModelDocument(entities:[visible,hidden,outside],editor:EditorState(groups:[group]))
        view.selectAll(nil)
        XCTAssertEqual(view.selectedIDs,[visible.id,hidden.id])
        view.editingGroupID=group.id;view.selectedIDs=[visible.id,outside.id];view.copy(nil);view.paste(nil)
        XCTAssertEqual(view.document.entities.count,4)
        XCTAssertEqual(view.document.entities.last?.metadata?.groupID,group.id)
    }

    func testFollowMeOrientsNegativeElbowFromProfileCompatibleEnd() throws {
        let profile=try GeometryTools.face(points:[Vec3(0,-0.1,-0.1),Vec3(0,0.1,-0.1),Vec3(0,0.1,0.1),Vec3(0,-0.1,0.1)])
        let a=SketchEntity(kind:.line,origin:Vec3(0,0,0),width:-2,depth:0)
        let b=SketchEntity(kind:.line,origin:Vec3(-2,0,0),width:0,depth:3)
        let source=ModelDocument(entities:[profile,a,b]),view=viewport()
        view.document=source;view.selectedIDs=Set(source.entities.map(\.id));view.performSweepAlongSelectedPath()
        XCTAssertEqual(view.document.entities.count,4)
        let mesh=try XCTUnwrap(view.document.entities.last?.triangulatedMesh())
        XCTAssertGreaterThan(mesh.vertices.map(\.z).max()!,2.9)
    }

}
