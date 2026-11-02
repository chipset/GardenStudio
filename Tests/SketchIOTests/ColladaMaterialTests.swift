import XCTest
import SketchCore
@testable import SketchIO

final class ColladaMaterialTests: XCTestCase {
    private let png = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sketchmake-material-dae-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        return url
    }
    private func model() -> ModelDocument {
        var entity = SketchEntity(name:"Textured box",kind:.rectangle,origin:Vec3(1,0,2),width:2,depth:3,height:4)
        entity.surface = SurfaceMaterial(name:"Embedded tile",colorHex:"#A27650",textureData:png,textureScale:0.5,textureRotation:.pi/4)
        return ModelDocument(entities:[entity])
    }
    func testTextureSidecarAndUVRoundTrip() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at:dir) }
        let url = dir.appendingPathComponent("model.dae")
        try ColladaFormat.write(model(),to:url)
        let xml = try String(contentsOf:url)
        XCTAssertTrue(xml.contains("semantic=\"TEXCOORD\""))
        XCTAssertTrue(xml.contains("<sampler2D>"))
        XCTAssertTrue(xml.contains("<library_images>"))
        let read = try ColladaFormat.read(url:url)
        XCTAssertEqual(read.entities.count,1)
        XCTAssertEqual(read.entities[0].surface?.textureData,png)
        XCTAssertEqual(read.entities[0].surface?.textureScale ?? 0,0.5,accuracy:1e-8)
        XCTAssertEqual(read.entities[0].surface?.textureRotation ?? 0,.pi/4,accuracy:1e-8)
    }
    func testPerFaceMaterialBindingsSurviveImport() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at:dir) }
        let url = dir.appendingPathComponent("faces.dae")
        var entity = SketchEntity(name:"Two colors",kind:.rectangle,origin:Vec3(0,0,0),width:2,depth:3,height:4)
        entity.surface = SurfaceMaterial(colorHex:"#AA3300",faceOverrides:[FaceSurface(triangleIndices:[0,1],colorHex:"#0033AA",textureData:png)])
        try ColladaFormat.write(ModelDocument(entities:[entity]),to:url)
        let read = try ColladaFormat.read(url:url)
        XCTAssertEqual(read.entities.count,1)
        XCTAssertEqual(read.entities[0].mesh?.triangles.count,36)
        XCTAssertEqual(read.entities[0].surface?.colorHex,"#AA3300")
        let overrides = try XCTUnwrap(read.entities[0].surface?.faceOverrides)
        XCTAssertEqual(overrides.count,1)
        XCTAssertEqual(overrides[0].triangleIndices.count,2)
        XCTAssertEqual(overrides[0].colorHex,"#0033AA")
        XCTAssertEqual(overrides[0].textureData,png)
    }
    func testMissingTextureDoesNotSilentlyLoseAppearance() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at:dir) }
        let url = dir.appendingPathComponent("model.dae")
        try ColladaFormat.write(model(),to:url)
        let textures = try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil).filter { $0.hasDirectoryPath }
        for texture in textures { try FileManager.default.removeItem(at:texture) }
        XCTAssertThrowsError(try ColladaFormat.read(url:url))
    }
    func testNetworkAbsoluteAndTraversalTextureReferencesAreRejected() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at:dir) }
        let url = dir.appendingPathComponent("model.dae")
        try ColladaFormat.write(model(),to:url)
        let original = try String(contentsOf:url)
        for path in ["https://example.com/texture.png","/private/tmp/texture.png","../texture.png","%2e%2e/texture.png","file:///private/tmp/texture.png"] {
            let xml = original.replacingOccurrences(of:"<init_from>[^<]*\\.png</init_from>",with:"<init_from>\(path)</init_from>",options:.regularExpression)
            XCTAssertNotEqual(xml,original)
            try xml.write(to:url,atomically:true,encoding:.utf8)
            XCTAssertThrowsError(try ColladaFormat.read(url:url))
        }
    }
    func testMaterialTextureDataMustActuallyBeAnImage() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at:dir) }
        let url = dir.appendingPathComponent("model.dae")
        try ColladaFormat.write(model(),to:url)
        let files = FileManager.default.enumerator(at:dir,includingPropertiesForKeys:nil)!.allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "png" }
        XCTAssertFalse(files.isEmpty)
        for file in files { try Data("not image data".utf8).write(to:file) }
        XCTAssertThrowsError(try ColladaFormat.read(url:url))
    }
    func testSymlinkedTextureCannotEscapeImportDirectory() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at:dir) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-texture-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at:outside) }
        try png.write(to:outside)
        let url = dir.appendingPathComponent("model.dae")
        try ColladaFormat.write(model(),to:url)
        let files = FileManager.default.enumerator(at:dir,includingPropertiesForKeys:nil)!.allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "png" }
        let image = try XCTUnwrap(files.first)
        try FileManager.default.removeItem(at:image)
        try FileManager.default.createSymbolicLink(at:image,withDestinationURL:outside)
        XCTAssertThrowsError(try ColladaFormat.read(url:url))
        XCTAssertThrowsError(try ColladaFormat.write(model(),to:url))
    }
    func testDTDAndShaderCodeAreNotAdmittedToNativeImporter() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at:dir) }
        let url = dir.appendingPathComponent("model.dae")
        try ColladaFormat.write(model(),to:url)
        let original = try String(contentsOf:url)
        let dtd = original.replacingOccurrences(of:"<COLLADA ",with:"<!DOCTYPE COLLADA SYSTEM \"https://example.com/model.dtd\"><COLLADA ")
        try dtd.write(to:url,atomically:true,encoding:.utf8)
        XCTAssertThrowsError(try ColladaFormat.read(url:url))
        let shader = original.replacingOccurrences(of:"<library_images>",with:"<library_effects><effect id=\"shader\"><profile_GLSL><code>void main(){}</code></profile_GLSL></effect></library_effects><library_images>")
        try shader.write(to:url,atomically:true,encoding:.utf8)
        XCTAssertThrowsError(try ColladaFormat.read(url:url))
    }

}
