import XCTest
@testable import GardenStudioCore

final class PushPullCutGeometryTests: XCTestCase {
    private func box() -> GardenEntity { GardenEntity(name:"Box",kind:.rectangle,origin:Vec3(0,0,0),width:4,depth:4,height:3) }
    private func cutter(y:Double=3) -> GardenEntity { GardenEntity(name:"Opening",kind:.rectangle,origin:Vec3(0,y,0),width:1,depth:1) }
    private func volume(_ mesh:MeshData) -> Double {
        abs(stride(from:0,to:mesh.triangles.count,by:3).reduce(0.0) { value,i in
            let a=mesh.vertices[mesh.triangles[i]],b=mesh.vertices[mesh.triangles[i+1]],c=mesh.vertices[mesh.triangles[i+2]]
            return value+(a.x*(b.y*c.z-b.z*c.y)+a.y*(b.z*c.x-b.x*c.z)+a.z*(b.x*c.y-b.y*c.x))/6
        })
    }
    private func assertClosed(_ entity:GardenEntity,file:StaticString=#filePath,line:UInt=#line) throws {
        let mesh=try entity.triangulatedMesh(); var edges:[String:Int]=[:]
        for i in stride(from:0,to:mesh.triangles.count,by:3) {
            let t=Array(mesh.triangles[i..<i+3])
            for (a,b) in [(t[0],t[1]),(t[1],t[2]),(t[2],t[0])] { edges["\(min(a,b)):\(max(a,b))",default:0]+=1 }
        }
        XCTAssertTrue(edges.values.allSatisfy{$0==2},"Cut mesh must be watertight",file:file,line:line)
    }
    func testThroughCutRemovesBottomAndPreservesHostIdentity() throws {
        var host=box();host.surface=SurfaceMaterial(name:"Paint",colorHex:"#AA3300")
        let profile=cutter(),source=ModelDocument(entities:[host,profile])
        let next=try GeometryTools.pushPull(document:source,profileID:profile.id,distance:-3)
        XCTAssertEqual(next.entities.count,1);let cut=try XCTUnwrap(next.entities.first)
        XCTAssertEqual(cut.id,host.id);XCTAssertEqual(cut.name,host.name);XCTAssertEqual(cut.surface?.colorHex,"#AA3300")
        XCTAssertEqual(volume(try cut.triangulatedMesh()),45,accuracy:1e-8);try assertClosed(cut)
        XCTAssertEqual(cut.profile?.holes.count,1)
    }
    func testPocketHasFloorAtEnteredDepth() throws {
        let profile=cutter(),source=ModelDocument(entities:[box(),profile])
        let next=try GeometryTools.pushPull(document:source,profileID:profile.id,distance:-1)
        let cut=try XCTUnwrap(next.entities.first),mesh=try cut.triangulatedMesh()
        XCTAssertEqual(next.entities.count,1);XCTAssertEqual(volume(mesh),47,accuracy:1e-8);try assertClosed(cut)
        XCTAssertTrue(mesh.vertices.contains{abs($0.y-2)<1e-9 && abs($0.x)==0.5})
        XCTAssertNil(cut.profile,"A pocket is no longer a uniform profile extrusion")
    }
    func testBeyondThicknessClampsToThroughHole() throws {
        let profile=cutter(),next=try GeometryTools.pushPull(document:ModelDocument(entities:[box(),profile]),profileID:profile.id,distance:-30)
        let cut=try XCTUnwrap(next.entities.first)
        XCTAssertEqual(volume(try cut.triangulatedMesh()),45,accuracy:1e-8);try assertClosed(cut)
    }
    func testBottomEntryAndSideOfExtrudedBox() throws {
        let bottom=cutter(y:0),under=try GeometryTools.pushPull(document:ModelDocument(entities:[box(),bottom]),profileID:bottom.id,distance:3)
        XCTAssertEqual(volume(try under.entities[0].triangulatedMesh()),45,accuracy:1e-8);try assertClosed(under.entities[0])
        let host=try GeometryTools.extrude(entity:box(),distance:3)
        let side=try GeometryTools.face(points:[Vec3(-0.5,1,2),Vec3(0.5,1,2),Vec3(0.5,2,2),Vec3(-0.5,2,2)])
        let next=try GeometryTools.pushPull(document:ModelDocument(entities:[host,side]),profileID:side.id,distance:-4)
        XCTAssertEqual(next.entities.count,1);XCTAssertEqual(volume(try next.entities[0].triangulatedMesh()),44,accuracy:1e-8);try assertClosed(next.entities[0])
    }
    func testOutwardAndUnattachedProfilesStillExtrude() throws {
        let profile=cutter(),source=ModelDocument(entities:[box(),profile])
        let next=try GeometryTools.pushPull(document:source,profileID:profile.id,distance:1)
        XCTAssertEqual(next.entities.count,2);XCTAssertEqual(next.entities[0],source.entities[0])
        XCTAssertEqual(volume(try next.entities[1].triangulatedMesh()),1,accuracy:1e-8)
        let alone=try GeometryTools.pushPull(document:ModelDocument(entities:[profile]),profileID:profile.id,distance:-1)
        XCTAssertEqual(volume(try alone.entities[0].triangulatedMesh()),1,accuracy:1e-8)
    }
    func testOverlappingHostsRejectInsteadOfChoosingArbitrarily() throws {
        let first=box();var second=first;second.id=UUID();let profile=cutter()
        XCTAssertThrowsError(try GeometryTools.pushPull(document:ModelDocument(entities:[first,second,profile]),profileID:profile.id,distance:-3))
    }
    func testInwardCutOnUnsupportedMeshRejectsInsteadOfAddingOverlappingSolid() throws {
        var host=try GeometryTools.extrude(entity:box(),distance:3)
        host.profile=nil;host.profileExtrusion=nil
        let profile=cutter(),source=ModelDocument(entities:[host,profile])
        XCTAssertThrowsError(try GeometryTools.pushPull(document:source,profileID:profile.id,distance:-1))
    }
    func testHiddenAndOtherGroupSolidsAreNeverCut() throws {
        let group=ModelGroup(name:"Other")
        for metadata in [EntityMetadata(isHidden:true),EntityMetadata(groupID:group.id)] {
            var host=box();host.metadata=metadata
            let profile=cutter(),source=ModelDocument(entities:[host,profile],editor:EditorState(groups:[group]))
            let next=try GeometryTools.pushPull(document:source,profileID:profile.id,distance:-3)
            XCTAssertEqual(next.entities.count,2);XCTAssertEqual(next.entities[0],host)
        }
    }
    func testCircleCanCutASecondThroughHoleInRetainedSolid() throws {
        let first=cutter(),source=ModelDocument(entities:[box(),first])
        var next=try GeometryTools.pushPull(document:source,profileID:first.id,distance:-3)
        let second=GardenEntity(kind:.circle,origin:Vec3(1,3,1),width:0.5,depth:0.5)
        next.entities.append(second)
        let result=try GeometryTools.pushPull(document:next,profileID:second.id,distance:-3)
        XCTAssertEqual(result.entities.count,1);XCTAssertEqual(result.entities[0].profile?.holes.count,2)
        XCTAssertLessThan(volume(try result.entities[0].triangulatedMesh()),45)
        try assertClosed(result.entities[0])
    }
    func testNativeCylinderSideRejectsUnsupportedCut() throws {
        let host=GardenEntity(kind:.circle,origin:Vec3(0,0,0),width:4,depth:4,height:3)
        let mesh=try host.triangulatedMesh()
        let side=try XCTUnwrap(stride(from:0,to:mesh.triangles.count,by:3).first { i in
            let y=(0..<3).map{mesh.vertices[mesh.triangles[i+$0]].y}
            return (y.max()! - y.min()!)>1
        })
        let triangle=(0..<3).map{mesh.vertices[mesh.triangles[side+$0]]}
        let center=Vec3(triangle.map(\.x).reduce(0,+)/3,triangle.map(\.y).reduce(0,+)/3,triangle.map(\.z).reduce(0,+)/3)
        let outline=triangle.map{Vec3(center.x+($0.x-center.x)*0.25,center.y+($0.y-center.y)*0.25,center.z+($0.z-center.z)*0.25)}
        let profile=try GeometryTools.face(points:outline)
        XCTAssertThrowsError(try GeometryTools.pushPull(document:ModelDocument(entities:[host,profile]),profileID:profile.id,distance:-0.1))
    }
    func testNegativeExtrusionAndRotatedBlockRemainWatertight() throws {
        let negative=try GeometryTools.extrude(entity:box(),distance:-3),bottom=cutter(y:0)
        let first=try GeometryTools.pushPull(document:ModelDocument(entities:[negative,bottom]),profileID:bottom.id,distance:-3)
        XCTAssertEqual(volume(try first.entities[0].triangulatedMesh()),45,accuracy:1e-8);try assertClosed(first.entities[0])
        var host=box();host.origin=Vec3(5,1,4);host.rotation=0.7
        var profile=cutter(y:4);profile.origin.x=5;profile.origin.z=4;profile.rotation=0.7
        let second=try GeometryTools.pushPull(document:ModelDocument(entities:[host,profile]),profileID:profile.id,distance:-3)
        XCTAssertEqual(volume(try second.entities[0].triangulatedMesh()),45,accuracy:1e-8);try assertClosed(second.entities[0])
    }
}
