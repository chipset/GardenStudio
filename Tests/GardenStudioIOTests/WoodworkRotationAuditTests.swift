import XCTest
import GardenStudioCore
@testable import GardenStudioIO
final class WoodworkRotationAuditTests:XCTestCase {
    func testVeryLargeFiniteRotationKeepsCoreGeometryPhase() throws {
        guard WoodworkFormat.isAvailable else {throw XCTSkip("Woodwork helper unavailable")}
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".woodwork")
        defer{try? FileManager.default.removeItem(at:url)}
        let entity=GardenEntity(name:"Rotated stock",kind:.rectangle,origin:Vec3(2,0,3),width:2,depth:1,height:0.3,rotation:1e50)
        try WoodworkFormat.write(ModelDocument(entities:[entity]),to:url)
        let result=try WoodworkFormat.read(url:url)
        let actual=try XCTUnwrap(result.entities.first).triangulatedMesh().vertices
        let expected=try entity.triangulatedMesh().vertices
        for key in [\Vec3.x,\Vec3.y,\Vec3.z] {
            XCTAssertEqual(actual.map{$0[keyPath:key]}.min()!,expected.map{$0[keyPath:key]}.min()!,accuracy:1e-8)
            XCTAssertEqual(actual.map{$0[keyPath:key]}.max()!,expected.map{$0[keyPath:key]}.max()!,accuracy:1e-8)
        }
    }
}
