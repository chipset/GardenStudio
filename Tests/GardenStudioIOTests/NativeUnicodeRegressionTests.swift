import XCTest
import GardenStudioCore
import CoreGraphics
import ImageIO
@testable import GardenStudioIO

final class NativeUnicodeRegressionTests:XCTestCase {
    func testNativeMaterialAcceptsValidComposedCharacterNames() throws {
        guard NativeModelFormat.isAvailable else {throw XCTSkip("Native SDK unavailable")}
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".skm")
        defer{try? FileManager.default.removeItem(at:url)}
        let name=String(repeating:"🪵",count:150)
        let paint=SurfaceMaterial(name:name,colorHex:"#A27650")
        try paint.validate()
        try NativeModelFormat.writeMaterial(paint,to:url)
        XCTAssertEqual(try NativeModelFormat.readMaterial(url:url).name,name)
    }
    func testTexturedMeshLooseLinesRetainTheirOwnFallbackColor() throws {
        guard NativeModelFormat.isAvailable else {throw XCTSkip("Native SDK unavailable")}
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".skp")
        defer{try? FileManager.default.removeItem(at:url)}
        let context=try XCTUnwrap(CGContext(data:nil,width:2,height:2,bitsPerComponent:8,bytesPerRow:8,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1));context.fill(CGRect(x:0,y:0,width:2,height:2))
        let image=try XCTUnwrap(context.makeImage()), data=NSMutableData()
        let encoder=try XCTUnwrap(CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil))
        CGImageDestinationAddImage(encoder,image,nil);XCTAssertTrue(CGImageDestinationFinalize(encoder))
        let mesh=MeshData(vertices:[Vec3(0,0,0),Vec3(1,0,0),Vec3(0,1,0),Vec3(2,0,0),Vec3(3,0,0)],triangles:[0,1,2],lineIndices:[3,4])
        let entity=GardenEntity(name:"Textured with line",kind:.mesh,origin:Vec3(0,0,0),width:3,depth:0,height:1,mesh:mesh,surface:SurfaceMaterial(name:"Paint",colorHex:"#AB3412",textureData:data as Data))
        try NativeModelFormat.write(ModelDocument(entities:[entity]),to:url)
        let result=try NativeModelFormat.read(url:url)
        let line=try XCTUnwrap(result.entities.first{!($0.mesh?.lineIndices.isEmpty ?? true)})
        XCTAssertEqual(line.colorHex,"#AB3412")
        XCTAssertNil(line.surface?.textureData)
        XCTAssertEqual(result.entities.flatMap{$0.mesh?.triangles ?? []}.count,3)
        XCTAssertNotNil(result.entities.first{!($0.mesh?.triangles.isEmpty ?? true)}?.surface?.textureData)
    }
    func testNativeMaterialRoundTripsLongUTF8ComposedNames() throws {
        guard NativeModelFormat.isAvailable else {throw XCTSkip("Native SDK unavailable")}
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".skm")
        defer{try? FileManager.default.removeItem(at:url)}
        let name=String(repeating:"👨‍👩‍👧‍👦",count:200)
        XCTAssertEqual(name.count,200)
        XCTAssertGreaterThan(name.utf8.count,4096)
        let paint=SurfaceMaterial(name:name,colorHex:"#A27650")
        try paint.validate()
        try NativeModelFormat.writeMaterial(paint,to:url)
        XCTAssertEqual(try NativeModelFormat.readMaterial(url:url).name,name)
    }
    func testNativeInputLimitIsNotBypassedByCachedURLMetadata() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".skp")
        defer{try? FileManager.default.removeItem(at:url)}
        try Data("small".utf8).write(to:url)
        _ = try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey])
        let handle=try FileHandle(forWritingTo:url)
        try handle.truncate(atOffset:100_000_001);try handle.close()
        XCTAssertThrowsError(try NativeModelFormat.read(url:url)) { error in
            XCTAssertTrue(error.localizedDescription.contains("between 1 byte and 100 MB"),error.localizedDescription)
        }
    }
    func testNativeGeometryNameDoesNotSplitUnicodeCharacter() throws {
        guard NativeModelFormat.isAvailable else {throw XCTSkip("Native SDK unavailable")}
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".skp")
        defer{try? FileManager.default.removeItem(at:url)}
        let name="x"+String(repeating:"🪵",count:150)
        let entity=GardenEntity(name:name,kind:.rectangle,origin:Vec3(0,0,0),width:2,depth:3,height:1)
        try NativeModelFormat.write(ModelDocument(entities:[entity]),to:url)
        let restored=try NativeModelFormat.read(url:url)
        XCTAssertEqual(restored.entities.first?.name,name)
    }
}
