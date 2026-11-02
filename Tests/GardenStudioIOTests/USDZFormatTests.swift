import XCTest
import AppKit
import GardenStudioCore
@testable import GardenStudioIO

final class USDZFormatTests: XCTestCase {
    private func temporary(_ ext: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext) }
    func testStoredArchiveAlignsEveryPayloadAndCleansExtraction() throws {
        let url = temporary("zip"); defer { try? FileManager.default.removeItem(at: url) }
        try AssetArchive.writeStored(entries: [.init(name:"model.usda",data:Data("root".utf8)),.init(name:"textures/image.png",data:Data([1,2,3]))],to:url,alignment:64)
        let entries=try AssetArchive.entries(url:url)
        XCTAssertEqual(entries.map(\.name),["model.usda","textures/image.png"])
        XCTAssertTrue(entries.allSatisfy { $0.payloadOffset % 64 == 0 && $0.compressionMethod == 0 })
        var extracted: URL?
        try AssetArchive.withExtracted(url:url) { directory in
            extracted=directory
            XCTAssertEqual(try Data(contentsOf:directory.appendingPathComponent("model.usda")),Data("root".utf8))
            let attributes=try FileManager.default.attributesOfItem(atPath:directory.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue,0o700)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:try XCTUnwrap(extracted).path))
    }
    func testArchiveRejectsCRCTraversalAndDuplicateNames() throws {
        let url=temporary("zip");defer { try? FileManager.default.removeItem(at:url) }
        XCTAssertThrowsError(try AssetArchive.writeStored(files:["../escape":Data()],to:url))
        XCTAssertThrowsError(try AssetArchive.writeStored(entries:[.init(name:"A",data:Data()),.init(name:"a",data:Data())],to:url))
        try AssetArchive.writeStored(files:["model.usda":Data("data".utf8)],to:url)
        let info=try XCTUnwrap(AssetArchive.entries(url:url).first)
        var bytes=try Data(contentsOf:url); bytes[info.payloadOffset] ^= 1;try bytes.write(to:url)
        var called=false
        XCTAssertThrowsError(try AssetArchive.withExtracted(url:url) { _ in called=true })
        XCTAssertFalse(called)
    }
    func testUSDZNativeRoundTripAndIndependentUSDReader() throws {
        let url=temporary("usdz");defer { try? FileManager.default.removeItem(at:url) }
        let document=ModelDocument(entities:[GardenEntity(name:"Asymmetric",kind:.rectangle,origin:Vec3(2,3,4),width:5,depth:7,height:11,colorHex:"#E04020")])
        try USDZFormat.write(document,to:url)
        let entries=try AssetArchive.entries(url:url)
        XCTAssertEqual(entries.first?.name,"model.usdc")
        XCTAssertTrue(entries.allSatisfy { $0.payloadOffset % 64 == 0 })
        let result=try USDZFormat.read(url:url)
        let vertices=result.entities.compactMap(\.mesh).flatMap(\.vertices)
        XCTAssertEqual(vertices.map(\.x).min()!,-0.5,accuracy:0.001)
        XCTAssertEqual(vertices.map(\.y).max()!,14,accuracy:0.001)
        XCTAssertEqual(vertices.map(\.z).max()!,7.5,accuracy:0.001)
        XCTAssertEqual(result.entities.first?.colorHex,"#E04020")
        XCTAssertNotNil(result.entities.first?.mesh?.textureCoordinates)
        let output=temporary("usda");defer { try? FileManager.default.removeItem(at:output) }
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/usdcat");process.arguments=[url.path,"-o",output.path];process.standardError=FileHandle.nullDevice
        try process.run();process.waitUntilExit();XCTAssertEqual(process.terminationStatus,0)
        XCTAssertTrue(try String(contentsOf:output).contains("Mesh"))
        let checker=Process();checker.executableURL=URL(fileURLWithPath:"/usr/bin/usdchecker");checker.arguments=[url.path];checker.standardOutput=FileHandle.nullDevice;checker.standardError=FileHandle.nullDevice
        try checker.run();checker.waitUntilExit();XCTAssertEqual(checker.terminationStatus,0,"The generated package must pass the independent OpenUSD compliance checker.")
    }
    func testUSDZRejectsMisalignedOrNonLayerFirstPackages() throws {
        let url=temporary("usdz");defer { try? FileManager.default.removeItem(at:url) }
        try AssetArchive.writeStored(entries:[.init(name:"image.png",data:Data()),.init(name:"model.usda",data:Data("#usda 1.0".utf8))],to:url,alignment:64)
        XCTAssertThrowsError(try USDZFormat.read(url:url))
        try AssetArchive.writeStored(files:["model.usda":Data("#usda 1.0".utf8)],to:url)
        XCTAssertThrowsError(try USDZFormat.read(url:url))
    }
    func testArchiveRejectsLinkMetadataAndOversizedMemberBeforeExtraction() throws {
        let url=temporary("zip");defer { try? FileManager.default.removeItem(at:url) }
        try AssetArchive.writeStored(files:["model.usda":Data("root".utf8)],to:url,alignment:64)
        let original=try Data(contentsOf:url)
        var extra=original
        let extraOffset=30+Data("model.usda".utf8).count
        extra[extraOffset]=0x75;extra[extraOffset+1]=0x70
        try extra.write(to:url)
        XCTAssertThrowsError(try AssetArchive.withExtracted(url:url) { _ in XCTFail("Unsafe extra fields must reject before body") })
        let central=try XCTUnwrap(original.range(of:Data([0x50,0x4b,0x01,0x02]))).lowerBound
        var oversized=original
        for index in (central+24)..<(central+28) { oversized[index]=0xff }
        try oversized.write(to:url)
        XCTAssertThrowsError(try AssetArchive.entries(url:url))
        var link=original;link[central+40]=0xff;link[central+41]=0xa1
        try link.write(to:url)
        XCTAssertThrowsError(try AssetArchive.entries(url:url))
    }

    func testCompressedArchiveExtractionAndThrowingBodyCleanup() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let data=Data(repeating:65,count:10000), url=directory.appendingPathComponent("compressed.zip")
        try data.write(to:directory.appendingPathComponent("model.xml"))
        let zip=Process();zip.executableURL=URL(fileURLWithPath:"/usr/bin/zip");zip.currentDirectoryURL=directory;zip.arguments=["-q",url.path,"model.xml"];try zip.run();zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus,0)
        var extracted: URL?
        XCTAssertThrowsError(try AssetArchive.withExtracted(url:url) { root -> Void in
            extracted=root
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("model.xml")),data)
            throw NSError(domain:"Test",code:1)
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath:try XCTUnwrap(extracted).path))
    }

    func testUSDZContainedTextureLoadsAfterSecureExtraction() throws {
        let url=temporary("usdz");defer { try? FileManager.default.removeItem(at:url) }
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1,pixelsHigh:1,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:4,bitsPerPixel:32)!
        bitmap.setColor(.red,atX:0,y:0)
        let image=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        let layer="""
        #usda 1.0
        (metersPerUnit = 1
        upAxis = "Y")
        def Mesh "Triangle" (prepend apiSchemas = ["MaterialBindingAPI"]) {
          point3f[] points = [(0,0,0),(2,0,0),(0,3,0)]
          int[] faceVertexCounts = [3]
          int[] faceVertexIndices = [0,1,2]
          texCoord2f[] primvars:st = [(0,0),(1,0),(0,1)] (interpolation = "vertex")
          uniform token subdivisionScheme = "none"
          rel material:binding = </Materials/Paint>
        }
        def Scope "Materials" {
          def Material "Paint" {
            token outputs:surface.connect = </Materials/Paint/Preview.outputs:surface>
            def Shader "Preview" {
              uniform token info:id = "UsdPreviewSurface"
              color3f inputs:diffuseColor.connect = </Materials/Paint/Texture.outputs:rgb>
              token outputs:surface
            }
            def Shader "Texture" {
              uniform token info:id = "UsdUVTexture"
              asset inputs:file = @textures/paint.png@
              float2 inputs:st.connect = </Materials/Paint/TexCoords.outputs:result>
              float3 outputs:rgb
            }
            def Shader "TexCoords" {
              uniform token info:id = "UsdPrimvarReader_float2"
              token inputs:varname = "st"
              float2 outputs:result
            }
          }
        }
        """
        try AssetArchive.writeStored(entries:[.init(name:"model.usda",data:Data(layer.utf8)),.init(name:"textures/paint.png",data:image)],to:url,alignment:64)
        let result=try USDZFormat.read(url:url)
        XCTAssertNotNil(result.entities.first?.surface?.textureData)
        XCTAssertEqual(result.entities.first?.mesh?.textureCoordinates?.count,3)
    }

}
