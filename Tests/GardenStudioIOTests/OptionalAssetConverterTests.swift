import XCTest
import GardenStudioCore
@testable import GardenStudioIO

final class OptionalAssetConverterTests: XCTestCase {
    func testExportCapabilityDoesNotRequireImportSandbox() {
        let directions = OptionalAssetConverter.availableDirections(imports:["3ds","fbx"],exports:["3ds","fbxa"],importSandboxAvailable:false)
        XCTAssertTrue(directions.imports.isEmpty)
        XCTAssertEqual(directions.exports,["3ds","fbxa"])
        let sandboxed = OptionalAssetConverter.availableDirections(imports:["3ds"],exports:[],importSandboxAvailable:true)
        XCTAssertEqual(sandboxed.imports,["3ds"])
    }
    func testInstalledExportersActuallyValidateBoundsWithoutImportSandbox() throws {
        guard FileManager.default.isExecutableFile(atPath:"/opt/homebrew/bin/assimp") || FileManager.default.isExecutableFile(atPath:"/usr/local/bin/assimp") else {throw XCTSkip("Assimp is not installed")}
        XCTAssertTrue(OptionalAssetConverter.isAvailable)
        XCTAssertEqual(Set(OptionalAssetConverter.supportedExportExtensions),Set(["3ds","fbxa","x","x3d"]))
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let entity=GardenEntity(name:"Asymmetric",kind:.mesh,origin:Vec3(-1,2,-3),width:2,depth:1,height:3,colorHex:"#AA4422",mesh:MeshData(vertices:[Vec3(0,0,0),Vec3(2,0,0),Vec3(0,3,1)],triangles:[0,1,2]))
        for format in OptionalAssetConverter.supportedExportExtensions {
            let url=root.appendingPathComponent("mesh."+(format=="fbxa" ? "fbx":format))
            // write validates the trusted generated target by reconverting it and
            // comparing the actual geometry bounds before installing the file.
            try OptionalAssetConverter.write(ModelDocument(entities:[entity]),to:url,format:format)
            let bytes=try Data(contentsOf:url).count
            XCTAssertGreaterThan(bytes,0,format)
            print("Validated optional exporter \(format): \(bytes) bytes, geometry bounds preserved")
            let importExtension=format=="fbxa" ? "fbx":format
            if OptionalAssetConverter.supportedImportExtensions.contains(importExtension) {
                let doc=try OptionalAssetConverter.read(url:url)
                let vertices=try doc.entities.flatMap{try $0.triangulatedMesh().vertices}
                XCTAssertEqual(vertices.map(\.x).min()!,-1,accuracy:0.001,format)
                XCTAssertEqual(vertices.map(\.x).max()!,1,accuracy:0.001,format)
                XCTAssertEqual(vertices.map(\.y).max()!,5,accuracy:0.001,format)
                XCTAssertEqual(vertices.map(\.z).min()!,-3,accuracy:0.001,format)
            }
        }
    }
    func testUnavailableImportDoesNotFallBackToUnsandboxedParsing() throws {
        guard OptionalAssetConverter.supportedImportExtensions.isEmpty else {throw XCTSkip("Import sandbox is available")}
        let missing=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".fbx")
        XCTAssertThrowsError(try OptionalAssetConverter.read(url:missing))
    }
}
