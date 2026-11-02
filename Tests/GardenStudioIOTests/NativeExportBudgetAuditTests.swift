import XCTest
import GardenStudioCore
@testable import GardenStudioIO
final class NativeExportBudgetAuditTests:XCTestCase {
    func testNativeExportCannotReplaceDestinationWithAnUnreopenableExpandedMesh()throws {
        guard NativeModelFormat.isAvailable else {throw XCTSkip("Native SDK unavailable")}
        // A compact indexed mesh can expand beyond the reader's vertex budget
        // when each triangle is serialized as a separate native face.
        let mesh=MeshData(vertices:[Vec3(0,0,0),Vec3(1,0,0),Vec3(0,1,0)],triangles:Array(repeating:[0,1,2],count:83_334).flatMap{$0})
        let entity=GardenEntity(name:"Repeated triangles",kind:.mesh,origin:Vec3(0,0,0),width:1,depth:0,height:1,mesh:mesh)
        let doc=ModelDocument(entities:[entity]);try doc.validate()
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".skp")
        let sentinel=Data("Existing destination".utf8)
        try sentinel.write(to:file);defer{try? FileManager.default.removeItem(at:file)}
        XCTAssertThrowsError(try NativeModelFormat.write(doc,to:file)) { error in
            XCTAssertTrue(error.localizedDescription.contains("expanded-vertex"),error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf:file),sentinel)
    }
}
