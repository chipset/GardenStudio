import XCTest
import GardenStudioCore
@testable import GardenStudioIO

final class WoodworkAuditRegressionTests:XCTestCase {
    private func directory() throws -> URL {
        guard WoodworkFormat.isAvailable else {throw XCTSkip("Woodwork helper unavailable")}
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("woodwork-audit-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        return url
    }
    func testDuplicatedNativeItemsRejectAggregateGeometryBeforeWorkerEncoding() throws {
        let directory=try directory();defer{try? FileManager.default.removeItem(at:directory)}
        let source=directory.appendingPathComponent("circle.woodwork"),destination=directory.appendingPathComponent("keep.woodwork")
        let circle=GardenEntity(kind:.circle,origin:Vec3(0,0,0),width:0.2,depth:0.2,height:0.02)
        try WoodworkFormat.write(ModelDocument(entities:[circle]),to:source)
        let imported=try WoodworkFormat.read(url:source)
        let part=try XCTUnwrap(imported.entities.first),mesh=try XCTUnwrap(part.mesh)
        let count=250_000/mesh.vertices.count+1
        let copies=(0..<count).map { index -> GardenEntity in
            var copy=part;copy.id=UUID();copy.name="Part \(index)";return copy
        }
        let previous=Data("Existing destination".utf8);try previous.write(to:destination)
        XCTAssertThrowsError(try WoodworkFormat.write(ModelDocument(entities:copies),to:destination)) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("Woodwork items exceed the expanded geometry limit"),error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf:destination),previous)
    }
    func testNativeLongMaterialNameCanRoundTripWithoutLosingItsOriginalValue() throws {
        let directory=try directory();defer{try? FileManager.default.removeItem(at:directory)}
        let source=directory.appendingPathComponent("long-name.woodwork"),output=directory.appendingPathComponent("returned.woodwork")
        let material=String(repeating:"Wood",count:70)
        let board:[String:Any]=["id":UUID().uuidString,"name":"Board","material":material,"width":6.0,"thickness":0.75,"length":12.0,"x":0.0,"y":0.0,"z":0.0,"rotation":0.0]
        try JSONSerialization.data(withJSONObject:["schemaVersion":9,"title":"Native long label","boards":[board]]).write(to:source)
        let imported=try WoodworkFormat.read(url:source)
        var model=try JSONDecoder().decode(ModelDocument.self,from:JSONEncoder().encode(imported))
        XCTAssertEqual(model.entities.count,1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(model.entities[0].surface?.name).count,200)
        try WoodworkFormat.write(model,to:output)
        let result=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:output)) as? [String:Any])
        let boards=try XCTUnwrap(result["boards"] as? [[String:Any]])
        XCTAssertEqual(boards[0]["material"] as? String,material)
        model.entities[0].surface?.name="Maple"
        try WoodworkFormat.write(model,to:output)
        let edited=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:output)) as? [String:Any])
        XCTAssertEqual((edited["boards"] as? [[String:Any]])?[0]["material"] as? String,"Maple")
    }
}
