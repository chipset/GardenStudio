import XCTest
import GardenStudioCore
@testable import GardenStudioIO

final class ResourceIntegrityAuditTests:XCTestCase {
    private let png=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    private func folder()throws->URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        return url
    }
    private func texturedFace()->GardenEntity {
        GardenEntity(kind:.rectangle,origin:Vec3(0,0,0),width:1,depth:1,surface:SurfaceMaterial(textureData:png))
    }
    func testFailedOBJGenerationPreservesExistingBundleResources()throws {
        let directory=try folder();defer{try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("model.obj"),texture=directory.appendingPathComponent("model_material_1.png"),library=directory.appendingPathComponent("model.mtl")
        let sentinel=Data("Original model resource".utf8)
        for file in [url,texture,library] {try sentinel.write(to:file)}
        var distant=texturedFace();distant.id=UUID();distant.origin=Vec3(100,0,0)
        XCTAssertThrowsError(try OBJFormat.write(ModelDocument(entities:[texturedFace(),distant]),to:url,metersPerUnit:1e-308))
        for file in [url,texture,library] {XCTAssertEqual(try Data(contentsOf:file),sentinel,"A failed export changed \(file.lastPathComponent)")}
    }
    func testBlockedOBJDestinationDoesNotChangeExistingTexture()throws {
        let directory=try folder();defer{try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("model.obj"),texture=directory.appendingPathComponent("model_material_1.png")
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false)
        let sentinel=Data("Original image".utf8);try sentinel.write(to:texture)
        XCTAssertThrowsError(try OBJFormat.write(ModelDocument(entities:[texturedFace()]),to:url))
        XCTAssertEqual(try Data(contentsOf:texture),sentinel)
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent("model.mtl").path))
    }
    func testSuccessfulOBJReplacementKeepsBundleCoherentAndPrivate()throws {
        let directory=try folder();defer{try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("model.obj")
        try OBJFormat.write(ModelDocument(entities:[texturedFace()]),to:url)
        let files=[url,directory.appendingPathComponent("model.mtl"),directory.appendingPathComponent("model_material_1.png")]
        for file in files {try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)}
        var moved=texturedFace();moved.origin=Vec3(3,0,0);moved.surface?.colorHex="#AA3300"
        try OBJFormat.write(ModelDocument(entities:[moved]),to:url)
        let result=try OBJFormat.read(url:url)
        XCTAssertEqual(result.entities[0].surface?.faceOverrides.first?.colorHex,"#AA3300")
        XCTAssertEqual(result.entities[0].mesh?.vertices.map(\.x).min() ?? 0,2.5,accuracy:1e-8)
        for file in files {
            let mode=try XCTUnwrap(FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)
            XCTAssertEqual(mode.intValue & 0o777,0o600,"An export must not broaden access to an existing private file")
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:directory.path).contains{$0.hasPrefix(".gardenstudio-obj-")})
    }
    func testDifferentOBJNamesCannotAliasTheSameSidecars()throws {
        let directory=try folder();defer{try? FileManager.default.removeItem(at:directory)}
        let first=directory.appendingPathComponent("model!.obj"),second=directory.appendingPathComponent("model?.obj")
        var a=texturedFace();a.surface?.colorHex="#AA3300"
        var b=texturedFace();b.surface?.colorHex="#0033AA"
        try OBJFormat.write(ModelDocument(entities:[a]),to:first)
        try OBJFormat.write(ModelDocument(entities:[b]),to:second)
        XCTAssertEqual(try OBJFormat.read(url:first).entities[0].surface?.faceOverrides.first?.colorHex,"#AA3300")
        XCTAssertEqual(try OBJFormat.read(url:second).entities[0].surface?.faceOverrides.first?.colorHex,"#0033AA")
    }
    func testSVGPaintInheritanceKeepsStrokeAndFillIndependent()throws {
        let directory=try folder();defer{try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("paint.svg")
        let svg="<svg><g stroke='#0033AA' fill='#AA3300'><rect id='stroke' width='10' height='10' fill='#00AA33'/><rect id='fill' x='20' width='10' height='10' stroke='none'/></g></svg>"
        try svg.write(to:url,atomically:true,encoding:.utf8)
        let paths=try VectorProfiles.paths(document:SVGFormat.read(url:url))
        XCTAssertEqual(paths.first{$0.name=="stroke"}?.colorHex,"#0033AA")
        XCTAssertEqual(paths.first{$0.name=="fill"}?.colorHex,"#AA3300")
    }
}
