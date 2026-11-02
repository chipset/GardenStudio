import XCTest
import SketchCore
@testable import SketchIO
final class NativeFormatTests: XCTestCase {
    func testNativeSKPRoundTripUsesPhysicalCoordinatesAndColors() throws {
        guard NativeModelFormat.isAvailable else { throw XCTSkip("Installed native SketchUp SDK/helper unavailable") }
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:directory)}
        let source=ModelDocument(entities:[SketchEntity(name:"Asymmetric",kind:.rectangle,origin:Vec3(3,5,-7),width:2,depth:4,height:1,colorHex:"#AA3300",rotation:0.37)])
        let path=directory.appendingPathComponent("model.skp")
        try NativeModelFormat.write(source,to:path)
        XCTAssertGreaterThan(try Data(contentsOf:path).count,100)
        let restored=try NativeModelFormat.read(url:path)
        try restored.validate()
        let expected=try source.entities[0].triangulatedMesh().vertices
        let actual=try restored.entities.flatMap{try $0.triangulatedMesh().vertices}
        for key in [\Vec3.x,\Vec3.y,\Vec3.z] {
            XCTAssertEqual(try XCTUnwrap(actual.map{$0[keyPath:key]}.min()),try XCTUnwrap(expected.map{$0[keyPath:key]}.min()),accuracy:1e-6)
            XCTAssertEqual(try XCTUnwrap(actual.map{$0[keyPath:key]}.max()),try XCTUnwrap(expected.map{$0[keyPath:key]}.max()),accuracy:1e-6)
        }
        XCTAssertTrue(restored.entities.contains{$0.surface?.colorHex.uppercased()=="#AA3300" || $0.colorHex.uppercased()=="#AA3300"})
    }
    func testNativeMaterialRoundTrip() throws {
        guard NativeModelFormat.isAvailable else { throw XCTSkip("Installed native SketchUp SDK/helper unavailable") }
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".skm")
        defer{try? FileManager.default.removeItem(at:url)}
        let source=SurfaceMaterial(name:"Terracotta",colorHex:"#AA3300")
        try NativeModelFormat.writeMaterial(source,to:url)
        let restored=try NativeModelFormat.readMaterial(url:url)
        XCTAssertEqual(restored.colorHex.uppercased(),source.colorHex)
        XCTAssertEqual(restored.name,source.name)
    }
    func testInvalidNativeInputRejects() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".skp")
        defer{try? FileManager.default.removeItem(at:url)}
        try Data("invalid sketchup".utf8).write(to:url)
        XCTAssertThrowsError(try NativeModelFormat.read(url:url))
    }
}
