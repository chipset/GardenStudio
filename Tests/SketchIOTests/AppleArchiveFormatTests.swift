import XCTest
import AppKit
import SketchCore
@testable import SketchIO

final class AppleArchiveFormatTests: XCTestCase {
    func testKMZRoundTripContainsKMLAndGeometry() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".kmz")
        defer { try? FileManager.default.removeItem(at: url) }
        let entity = SketchEntity(name: "Asymmetric", kind: .rectangle, origin: Vec3(2,3,4), width: 5, depth: 7, height: 11)
        try KMZFormat.write(ModelDocument(entities: [entity]), to: url)
        let result = try KMZFormat.read(url: url)
        let mesh = try XCTUnwrap(result.entities.first?.mesh)
        XCTAssertEqual(mesh.vertices.map(\.x).min()!, -0.5, accuracy: 0.001)
        XCTAssertEqual(mesh.vertices.map(\.y).max()!, 14, accuracy: 0.001)
        XCTAssertEqual(mesh.vertices.map(\.z).max()!, 7.5, accuracy: 0.001)
        XCTAssertTrue(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("doc.kml"))
    }
    func testAppleUSDARoundTripActualGeometry() throws {
        guard AppleAssetFormat.supportedExportExtensions.contains("usda") else { throw XCTSkip("Native USDA exporter unavailable") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".usda")
        defer { try? FileManager.default.removeItem(at: url) }
        try AppleAssetFormat.write(ModelDocument(entities: [SketchEntity(name: "Box", kind: .rectangle, origin: Vec3(2,3,4), width: 5, depth: 7, height: 11, colorHex: "#E04020")]), to: url)
        let result = try AppleAssetFormat.read(url: url)
        XCTAssertEqual(result.entities.first?.colorHex, "#E04020")
        XCTAssertNotNil(result.entities.first?.mesh?.textureCoordinates)
        XCTAssertEqual(result.entities.compactMap(\.mesh).flatMap(\.vertices).map(\.y).max()!, 14, accuracy: 0.01)
    }
    func testRejectsNonArchiveAndUnsupportedAppleExtension() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".kmz")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("broken".utf8).write(to: url)
        XCTAssertThrowsError(try KMZFormat.read(url: url))
        XCTAssertThrowsError(try AppleAssetFormat.read(url: url))
    }
    func testArchiveTraversalRejectedBeforeExtraction() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".kmz")
        defer { try? FileManager.default.removeItem(at: url) }
        try KMZFormat.write(ModelDocument(entities: [SketchEntity(name: "Box", kind: .rectangle, origin: Vec3(0,0,0), width: 1, depth: 1, height: 1)]), to: url)
        var data = try Data(contentsOf: url)
        let needle = Data("doc.kml".utf8)
        while let range = data.range(of: needle) { data.replaceSubrange(range, with: Data("../evil".utf8)) }
        try data.write(to: url)
        XCTAssertThrowsError(try KMZFormat.read(url: url))
    }
    func testUSDAUnitsAndZUpAndNodeTranslation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".usda")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = """
        #usda 1.0
        (metersPerUnit = 0.01
        upAxis = "Z")
        def Xform "Root" {
            double3 xformOp:translate = (200, 300, 400)
            uniform token[] xformOpOrder = ["xformOp:translate"]
            def Mesh "Triangle" {
                point3f[] points = [(0,0,0),(100,0,0),(0,100,0)]
                int[] faceVertexCounts = [3]
                int[] faceVertexIndices = [0,1,2]
                uniform token subdivisionScheme = "none"
            }
        }
        """
        try source.write(to: url, atomically: true, encoding: .utf8)
        let vertices = try AppleAssetFormat.read(url:url).entities.compactMap(\.mesh).flatMap(\.vertices)
        XCTAssertEqual(vertices.map(\.x).min()!, 2, accuracy: 0.001)
        XCTAssertEqual(vertices.map(\.y).max()!, 4, accuracy: 0.001)
        XCTAssertEqual(vertices.map(\.z).min()!, -4, accuracy: 0.001)
    }
    func testUSDExternalCompositionRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".usda")
        defer { try? FileManager.default.removeItem(at:url) }
        try "#usda 1.0\n( subLayers = [@https://example.com/model.usda@] )".write(to:url,atomically:true,encoding:.utf8)
        XCTAssertThrowsError(try AppleAssetFormat.read(url:url))
    }
    func testAllAdvertisedAppleExportsRoundTripBounds() throws {
        for ext in AppleAssetFormat.supportedExportExtensions {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            defer { try? FileManager.default.removeItem(at:url) }
            let original = ModelDocument(entities:[SketchEntity(name:"Box",kind:.rectangle,origin:Vec3(2,3,4),width:5,depth:7,height:11)])
            try AppleAssetFormat.write(original,to:url)
            let vertices = try AppleAssetFormat.read(url:url).entities.compactMap(\.mesh).flatMap(\.vertices)
            XCTAssertEqual(vertices.map(\.x).min()!,-0.5,accuracy:0.01,ext)
            XCTAssertEqual(vertices.map(\.y).max()!,14,accuracy:0.01,ext)
            XCTAssertEqual(vertices.map(\.z).max()!,7.5,accuracy:0.01,ext)
        }
    }

    func testUSDZImportStoredNativePackage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let usda=directory.appendingPathComponent("model.usda"), usdz=directory.appendingPathComponent("model.usdz")
        try AppleAssetFormat.write(ModelDocument(entities:[SketchEntity(name:"Box",kind:.rectangle,origin:Vec3(2,3,4),width:5,depth:7,height:11)]),to:usda)
        let process=Process(); process.executableURL=URL(fileURLWithPath:"/usr/bin/usdzip"); process.currentDirectoryURL=directory
        process.arguments=["model.usdz","model.usda"]; process.standardOutput=FileHandle.nullDevice; process.standardError=FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus,0)
        let vertices = try AppleAssetFormat.read(url:usdz).entities.compactMap(\.mesh).flatMap(\.vertices)
        XCTAssertEqual(vertices.map(\.x).min()!,-0.5,accuracy:0.01)
        XCTAssertEqual(vertices.map(\.y).max()!,14,accuracy:0.01)
        XCTAssertFalse(AppleAssetFormat.supportedExportExtensions.contains("usdz"))
        XCTAssertFalse(AppleAssetFormat.supportedImportExtensions.contains("abc"))
    }

    func testKMZPackagesAndReadsTextureSidecars() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".kmz")
        defer { try? FileManager.default.removeItem(at:url) }
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1,pixelsHigh:1,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:4,bitsPerPixel:32)!
        bitmap.setColor(.red,atX:0,y:0)
        let data=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        let mesh=MeshData(vertices:[Vec3(0,0,0),Vec3(2,0,0),Vec3(0,3,0)],triangles:[0,1,2],textureCoordinates:[TextureCoordinate(u:0.1,v:0.2),TextureCoordinate(u:0.8,v:0.1),TextureCoordinate(u:0.3,v:0.7)])
        let entity=SketchEntity(name:"Textured",kind:.mesh,origin:Vec3(0,0,0),width:2,depth:0,height:3,colorHex:"#FF0000",mesh:mesh,surface:SurfaceMaterial(colorHex:"#FF0000",textureData:data))
        try KMZFormat.write(ModelDocument(entities:[entity]),to:url)
        XCTAssertTrue(String(decoding:try Data(contentsOf:url),as:UTF8.self).contains("model-textures/"))
        let result=try KMZFormat.read(url:url)
        XCTAssertNotNil(result.entities.first?.surface?.textureData)
        XCTAssertEqual(result.entities.first?.mesh?.textureCoordinates?.count,3)
    }

    func testArchiveSymbolicLinkAndExcessiveExpansionRejected() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".kmz")
        defer { try? FileManager.default.removeItem(at:url) }
        try KMZFormat.write(ModelDocument(entities:[SketchEntity(name:"Box",kind:.rectangle,origin:Vec3(0,0,0),width:1,depth:1,height:1)]),to:url)
        let original=try Data(contentsOf:url)
        let offset=try XCTUnwrap(original.range(of:Data([0x50,0x4b,0x01,0x02]))).lowerBound
        var symlink=original; symlink[offset+40]=0xff; symlink[offset+41]=0xa1
        XCTAssertThrowsError(try KMZFormat.validateArchive(symlink))
        var expanded=original
        for p in (offset+24)..<(offset+28) { expanded[p]=0xff }
        XCTAssertThrowsError(try KMZFormat.validateArchive(expanded))
    }
    func testAppleTextureExportRejectedInsteadOfDroppingImages() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".usda")
        defer { try? FileManager.default.removeItem(at:url) }
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1,pixelsHigh:1,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:4,bitsPerPixel:32)!
        bitmap.setColor(.red,atX:0,y:0)
        let data=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        let mesh=MeshData(vertices:[Vec3(0,0,0),Vec3(2,0,0),Vec3(0,3,0)],triangles:[0,1,2],textureCoordinates:[TextureCoordinate(u:0.1,v:0.2),TextureCoordinate(u:0.8,v:0.1),TextureCoordinate(u:0.3,v:0.7)])
        let entity=SketchEntity(name:"Textured",kind:.mesh,origin:Vec3(0,0,0),width:2,depth:0,height:3,colorHex:"#FF0000",mesh:mesh,surface:SurfaceMaterial(colorHex:"#FF0000",textureData:data))
        XCTAssertThrowsError(try AppleAssetFormat.write(ModelDocument(entities:[entity]),to:url))
    }

    private func usdFixture(indices: String = "0,1,2", counts: String = "3", points: String = "(0,0,0),(2,0,0),(0,3,0)", extra: String = "", prefix: String = "") -> String {
        """
        #usda 1.0
        \(prefix)
        ( metersPerUnit = 1
          upAxis = "Y" )
        def Mesh "First" {
          point3f[] points = [\(points)]
          int[] faceVertexCounts = [\(counts)]
          int[] faceVertexIndices = [\(indices)]
          uniform token subdivisionScheme = "none"
          \(extra)
        }
        def Mesh "Second" {
          point3f[] points = [(0,0,0),(2,0,0),(0,3,0)]
          int[] faceVertexCounts = [3]
          int[] faceVertexIndices = [0,1,2]
          uniform token subdivisionScheme = "none"
        }
        """
    }
    private func readUSD(_ text: String) throws -> ModelDocument {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".usda")
        defer { try? FileManager.default.removeItem(at:url) }
        try text.write(to:url,atomically:true,encoding:.utf8)
        return try AppleAssetFormat.read(url:url)
    }
    func testUSDMetadataCommentsCannotOverrideStageUnits() throws {
        let doc=try readUSD(usdFixture(prefix:"# metersPerUnit = 100\n# upAxis = \"Z\""))
        let vertices=doc.entities.compactMap(\.mesh).flatMap(\.vertices)
        XCTAssertEqual(vertices.map(\.x).max()!,2,accuracy:0.0001)
        XCTAssertEqual(vertices.map(\.y).max()!,3,accuracy:0.0001)
    }
    func testUSDMetadataStringsAndNestedDictionariesCannotOverrideStageUnits() throws {
        let text = usdFixture().replacingOccurrences(of: "( metersPerUnit = 1", with: "( customLayerData = {\n string hint = \"metersPerUnit = 100 upAxis = Z\"\n double metersPerUnit = 200\n }\n metersPerUnit = 1")
        let vertices = try readUSD(text).entities.compactMap(\.mesh).flatMap(\.vertices)
        XCTAssertEqual(vertices.map(\.x).max()!,2,accuracy:0.0001)
        XCTAssertEqual(vertices.map(\.y).max()!,3,accuracy:0.0001)
    }
    func testUSDMalformedFirstMeshRejectsEntireStage() throws {
        for indices in ["0,1,999", "0,1,-1"] { XCTAssertThrowsError(try readUSD(usdFixture(indices:indices))) }
        XCTAssertThrowsError(try readUSD(usdFixture(counts:"4")))
        XCTAssertThrowsError(try readUSD(usdFixture(points:"(0,0,0),(nan,0,0),(0,3,0)")))
        for indices in ["0,1,999","0,1,-1"] {
            XCTAssertThrowsError(try readUSD(usdFixture(extra:"texCoord2f[] primvars:st = [(0,0),(1,0),(0,1)] (interpolation = \"vertex\")\n int[] primvars:st:indices = [\(indices)]")))
        }
    }
    func testKMZNonidentityLocalScaleOrOrientationRejected() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        try ColladaFormat.write(ModelDocument(entities:[SketchEntity(name:"Box",kind:.rectangle,origin:Vec3(0,0,0),width:2,depth:3,height:1)]),to:directory.appendingPathComponent("model.dae"))
        for transform in ["<Scale><x>2</x><y>3</y><z>4</z></Scale>","<Orientation><heading>45</heading></Orientation>"] {
            try "<kml><Model>\(transform)<Link><href>model.dae</href></Link></Model></kml>".write(to:directory.appendingPathComponent("doc.kml"),atomically:true,encoding:.utf8)
            let package=directory.appendingPathComponent(UUID().uuidString+".kmz")
            let p=Process(); p.executableURL=URL(fileURLWithPath:"/usr/bin/zip");p.currentDirectoryURL=directory;p.arguments=["-q",package.path,"doc.kml","model.dae"];try p.run();p.waitUntilExit()
            XCTAssertThrowsError(try KMZFormat.read(url:package))
        }
    }

}
