import XCTest
import CoreGraphics
import ImageIO
import GardenStudioCore
@testable import GardenStudioIO

final class ExchangeCatalogTests: XCTestCase {
    func testCatalogReportsDirectionsAndEncodingModes() throws {
        let ids = Set(ExchangeCatalog.formats.map(\.id))
        XCTAssertTrue(Set(["project","dae","kmz","obj","stl-binary","stl-ascii","ply-ascii","ply-binary","off","dxf-profiles","dxf-mesh","svg","pdf","eps","ai","gltf","glb","png","jpg"]).isSubset(of:ids))
        XCTAssertTrue(try XCTUnwrap(ExchangeCatalog.format(id:"usdz")).canExport)
        XCTAssertTrue(ExchangeCatalog.importExtensions.contains("obj"))
        XCTAssertTrue(ExchangeCatalog.importExtensions.contains("json"))
    }
    func testProjectCatalogRoundTripPreservesEditableState() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:directory)}
        var doc=ModelDocument.demo
        doc.editor=EditorState(snapStep:0.0001,units:"mm")
        doc.presentation=PresentationState()
        let url=directory.appendingPathComponent("Project.json")
        try ExchangeCatalog.write(doc,to:url,formatID:"project")
        XCTAssertEqual(try ExchangeCatalog.read(url:url),doc)
    }
    func testSelectionAndVisibilityExportsDoNotModifyOriginal() throws {
        var a=GardenEntity(kind:.rectangle,origin:Vec3(0,0,0),width:1,depth:1)
        a.metadata=EntityMetadata(isHidden:true)
        let b=GardenEntity(kind:.circle,origin:Vec3(2,0,0),width:1,depth:1)
        let doc=ModelDocument(entities:[a,b])
        let visible=try ExchangeCatalog.prepareExport(doc,options:ExchangeExportOptions(scope:.visible))
        XCTAssertEqual(visible.entities.map(\.id),[b.id])
        let selected=try ExchangeCatalog.prepareExport(doc,options:ExchangeExportOptions(scope:.selection,selectedIDs:[a.id]))
        XCTAssertEqual(selected.entities.map(\.id),[a.id])
        XCTAssertEqual(doc.entities.count,2)
        XCTAssertThrowsError(try ExchangeCatalog.prepareExport(doc,options:ExchangeExportOptions(scope:.selection)))
    }
    func testProjectExportHonorsMaterialChoiceAndSubsetSettings() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:directory)}
        var doc=ModelDocument.demo
        doc.name="My Model"
        doc.editor=EditorState(snapStep:0.0254,units:"in")
        doc.presentation=PresentationState(camera:CameraState(target:Vec3(1,2,3),distance:7))
        doc.entities[0].surface=SurfaceMaterial(name:"Paint",colorHex:"#FF0000")
        let full=directory.appendingPathComponent("full.json")
        try ExchangeCatalog.write(doc,to:full,formatID:"project",options:ExchangeExportOptions(includeMaterials:false))
        let withoutPaint=try ExchangeCatalog.read(url:full)
        XCTAssertNil(withoutPaint.entities[0].surface)
        let subset=directory.appendingPathComponent("subset.json")
        try ExchangeCatalog.write(doc,to:subset,formatID:"project",options:ExchangeExportOptions(scope:.selection,selectedIDs:[doc.entities[0].id]))
        let restored=try ExchangeCatalog.read(url:subset)
        XCTAssertEqual(restored.name,doc.name)
        XCTAssertEqual(restored.editor?.units,"in")
        XCTAssertEqual(restored.editor?.snapStep,0.0254)
        XCTAssertEqual(restored.presentation,doc.presentation)
        XCTAssertEqual(restored.entities.count,1)
        let empty=directory.appendingPathComponent("empty.json")
        try ExchangeCatalog.write(ModelDocument(),to:empty,formatID:"project")
        XCTAssertTrue(try ExchangeCatalog.read(url:empty).entities.isEmpty)
    }

    func testEveryAdvertisedImageWriterUsesARealEncoder() throws {
        let context=try XCTUnwrap(CGContext(data:nil,width:32,height:16,bitsPerComponent:8,bytesPerRow:128,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red:0.8,green:0.2,blue:0.1,alpha:1));context.fill(CGRect(x:0,y:0,width:32,height:16))
        let image=try XCTUnwrap(context.makeImage())
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:directory)}
        for format in ExchangeCatalog.exportFormats where format.category == .image {
            let file=directory.appendingPathComponent("view."+format.fileExtension)
            do{
                try ExchangeCatalog.write(ModelDocument(),to:file,formatID:format.id,viewImage:image)
                XCTAssertGreaterThan(try Data(contentsOf:file).count,0,format.id)
                if format.fileExtension != "pdf" {
                    XCTAssertNotNil(CGImageSourceCreateWithURL(file as CFURL,nil),format.id)
                }
            }catch{XCTFail("Advertised image writer \(format.id) failed: \(error)")}
        }
    }

    func testNativeManufacturingSceneArchiveAndModelDirectionsAreRegistered() throws {
        for id in ["3mf","amf","wrl","x3d"] {
            let format=try XCTUnwrap(ExchangeCatalog.format(id:id));XCTAssertEqual(format.category,.mesh);XCTAssertTrue(format.canImport);XCTAssertTrue(format.canExport)
        }
        XCTAssertNil(ExchangeCatalog.format(id:"assimp-x3d"))
        XCTAssertEqual(ExchangeCatalog.formats.filter{$0.fileExtension=="x3d"}.count,1)
        XCTAssertTrue(ExchangeCatalog.importExtensions.contains("vrml"))
        let skp=try XCTUnwrap(ExchangeCatalog.format(id:"skp"));XCTAssertEqual(skp.category,.mesh)
        XCTAssertEqual(skp.canImport,NativeModelFormat.isAvailable);XCTAssertEqual(skp.canExport,NativeModelFormat.isAvailable)
        XCTAssertEqual(ExchangeCatalog.importExtensions.contains("skp"),NativeModelFormat.isAvailable)
        let material=try XCTUnwrap(ExchangeCatalog.format(id:"skm-material"));XCTAssertFalse(material.canImport);XCTAssertFalse(material.canExport);XCTAssertEqual(material.category,.bridge)
        XCTAssertTrue(material.detail.contains("Materials"))
        let fallback=try XCTUnwrap(ExchangeCatalog.format(id:"sketchup-bridge"));XCTAssertFalse(fallback.canImport);XCTAssertFalse(fallback.canExport);XCTAssertTrue(fallback.detail.contains("Ruby"))
    }
    func testNativeManufacturingAndSceneModesDispatchActualGeometryRoundtrips() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:dir)}
        let entity=GardenEntity(name:"Native",kind:.mesh,origin:Vec3(2,3,4),width:2,depth:3,height:4,colorHex:"#AA3300",mesh:MeshData(vertices:[Vec3(1,2,3),Vec3(3,2,3),Vec3(1,6,6)],triangles:[0,1,2]))
        let document=ModelDocument(entities:[entity]),expected=try entity.triangulatedMesh().vertices
        for id in ["3mf","amf","wrl","x3d","usdz"] {
            let format=try XCTUnwrap(ExchangeCatalog.format(id:id));guard format.canExport,format.canImport else {continue}
            let url=dir.appendingPathComponent("model."+format.fileExtension)
            try ExchangeCatalog.write(document,to:url,formatID:id)
            let read=try ExchangeCatalog.read(url:url),vertices=read.entities.compactMap(\.mesh).flatMap(\.vertices)
            XCTAssertEqual(read.entities.compactMap(\.mesh).reduce(0){$0+$1.triangles.count},3,id)
            for p in expected {XCTAssertTrue(vertices.contains{abs($0.x-p.x)<1e-5 && abs($0.y-p.y)<1e-5 && abs($0.z-p.z)<1e-5},"\(id) lost \(p)")}
            if id=="wrl" {let alias=dir.appendingPathComponent("alias.vrml");try Data(contentsOf:url).write(to:alias);XCTAssertFalse(try ExchangeCatalog.read(url:alias).entities.isEmpty)}
        }
    }

}
