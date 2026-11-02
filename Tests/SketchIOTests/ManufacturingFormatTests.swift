import XCTest
import Foundation
import SketchCore
@testable import SketchIO

final class ManufacturingFormatTests: XCTestCase {
    private func folder() throws -> URL { let u=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at:u,withIntermediateDirectories:true); return u }
    private func triangle() -> ModelDocument { ModelDocument(entities:[SketchEntity(name:"Part",kind:.mesh,origin:Vec3(2,3,4),width:2,depth:3,height:4,colorHex:"#AA3300",mesh:MeshData(vertices:[Vec3(1,2,3),Vec3(3,2,3),Vec3(1,6,6)],triangles:[0,1,2]),surface:SurfaceMaterial(colorHex:"#AA3300"))]) }
    private let geometry="<mesh><vertices><vertex x=\"1\" y=\"2\" z=\"3\"/><vertex x=\"4\" y=\"2\" z=\"3\"/><vertex x=\"1\" y=\"6\" z=\"3\"/></vertices><triangles><triangle v1=\"0\" v2=\"1\" v3=\"2\"/></triangles></mesh>"
    private func package(_ model:String,to url:URL) throws {
        let rel="<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Target=\"/3D/3dmodel.model\" Id=\"rel0\" Type=\"http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel\"/></Relationships>"
        let types="<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"model\" ContentType=\"application/vnd.ms-package.3dmanufacturing-3dmodel+xml\"/></Types>"
        try AssetArchive.writeStored(files:["[Content_Types].xml":Data(types.utf8),"_rels/.rels":Data(rel.utf8),"3D/3dmodel.model":Data(model.utf8)],to:url)
    }
    func testManufacturingRoundtripsPhysicalGeometryAndColorAndIndependentReader() throws {
        let dir=try folder(); defer {try? FileManager.default.removeItem(at:dir)}
        let doc=triangle(), expected=try doc.entities[0].triangulatedMesh().vertices
        for ext in ["3mf","amf"] {
            let url=dir.appendingPathComponent("part.\(ext)"); let read:ModelDocument
            if ext=="3mf" {try ThreeMFFormat.write(doc,to:url);read=try ThreeMFFormat.read(url:url)} else {try AMFFormat.write(doc,to:url);read=try AMFFormat.read(url:url)}
            XCTAssertEqual(read.entities.first?.mesh?.vertices,expected)
            XCTAssertEqual(read.entities.first?.mesh?.triangles,[0,1,2])
            XCTAssertEqual(read.entities.first?.surface?.faceOverrides.first?.colorHex,"#AA3300")
            if ext=="3mf" {let model=try AssetArchive.withExtracted(url:url){try String(contentsOf:$0.appendingPathComponent("3D/3dmodel.model"))};XCTAssertTrue(model.contains("displaycolor=\"#AA3300FF\""),model)}
            if let exe=["/opt/homebrew/bin/assimp","/usr/local/bin/assimp"].first(where:{FileManager.default.isExecutableFile(atPath:$0)}) {
                let p=Process(), out=Pipe();p.executableURL=URL(fileURLWithPath:exe);p.arguments=["info",url.path];p.standardOutput=out;p.standardError=out;try p.run();let log=String(data:out.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? "";p.waitUntilExit();XCTAssertEqual(p.terminationStatus,0,log)
            }
        }
    }
    func testThreeMFNestedComponentsApplyRowMatricesAndMirroredWinding() throws {
        let dir=try folder();defer{try? FileManager.default.removeItem(at:dir)};let url=dir.appendingPathComponent("nested.3mf")
        let xml="<model xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\" unit=\"centimeter\"><resources><object id=\"1\">\(geometry)</object><object id=\"2\"><components><component objectid=\"1\" transform=\"-1 0 0 0 1 0 0 0 1 10 20 30\"/></components></object><object id=\"3\"><components><component objectid=\"2\" transform=\"1 0 0 0 1 0 0 0 1 100 0 0\"/></components></object></resources><build><item objectid=\"3\" transform=\"1 0 0 0 1 0 0 0 1 0 200 0\"/></build></model>"
        try package(xml,to:url);let mesh=try XCTUnwrap(ThreeMFFormat.read(url:url).entities.first?.mesh)
        XCTAssertEqual(mesh.vertices[0].x,1.09,accuracy:1e-9);XCTAssertEqual(mesh.vertices[0].y,0.33,accuracy:1e-9);XCTAssertEqual(mesh.vertices[0].z,-2.22,accuracy:1e-9)
        XCTAssertEqual(mesh.triangles,[0,2,1])
    }
    func testThreeMFRejectsInvalidUnusedMeshExtensionsAndCycles() throws {
        let dir=try folder();defer{try? FileManager.default.removeItem(at:dir)};let url=dir.appendingPathComponent("bad.3mf")
        let bad=geometry.replacingOccurrences(of:"v3=\"2\"",with:"v3=\"99\"")
        for resources in ["<object id=\"1\">\(geometry)</object><object id=\"2\">\(bad)</object>","<object id=\"1\"><components><component objectid=\"1\"/></components></object>","<object id=\"1\">\(geometry)</object><texture2d id=\"2\"/>"] {
            try package("<model xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\"><resources>\(resources)</resources><build><item objectid=\"1\"/></build></model>",to:url)
            XCTAssertThrowsError(try ThreeMFFormat.read(url:url))
        }
    }
    func testAMFConstellationsAndMaterialsUseUnitsRotationAndHierarchy() throws {
        let dir=try folder();defer{try? FileManager.default.removeItem(at:dir)};let url=dir.appendingPathComponent("nested.amf")
        let xml="<amf unit=\"inch\" version=\"1.1\"><material id=\"9\"><color><r>1</r><g>0</g><b>0</b></color></material><object id=\"1\"><mesh><vertices><vertex><coordinates><x>1</x><y>2</y><z>3</z></coordinates></vertex><vertex><coordinates><x>4</x><y>2</y><z>3</z></coordinates></vertex><vertex><coordinates><x>1</x><y>6</y><z>3</z></coordinates></vertex></vertices><volume materialid=\"9\"><triangle><v1>0</v1><v2>1</v2><v3>2</v3></triangle></volume></mesh></object><constellation id=\"2\"><instance objectid=\"1\"><deltax>10</deltax><rz>90</rz></instance></constellation><constellation id=\"3\"><instance objectid=\"2\"><deltaz>20</deltaz></instance></constellation></amf>"
        try xml.write(to:url,atomically:true,encoding:.utf8);let doc=try AMFFormat.read(url:url), mesh=try XCTUnwrap(doc.entities.first?.mesh)
        XCTAssertEqual(doc.entities.count,1);XCTAssertEqual(mesh.vertices[0].x,8*0.0254,accuracy:1e-9);XCTAssertEqual(mesh.vertices[0].y,23*0.0254,accuracy:1e-9);XCTAssertEqual(mesh.vertices[0].z,-0.0254,accuracy:1e-9)
        XCTAssertEqual(doc.entities.first?.surface?.faceOverrides.first?.colorHex,"#FF0000")
    }
    func testAMFRejectsBadSiblingCurvedOrTexturedGeometryAndEntityDeclarations() throws {
        let dir=try folder();defer{try? FileManager.default.removeItem(at:dir)};let url=dir.appendingPathComponent("bad.amf")
        for xml in ["<amf><object id=\"1\"><mesh><vertices/><volume><triangle><v1>0</v1><v2>1</v2><v3>2</v3></triangle></volume></mesh></object></amf>","<amf><texture id=\"1\"/></amf>","<!DOCTYPE amf [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><amf>&x;</amf>"] {
            try xml.write(to:url,atomically:true,encoding:.utf8);XCTAssertThrowsError(try AMFFormat.read(url:url))
        }
    }
    func testManufacturingPerFaceColorsUnitsOverridesAndCompressedAMF() throws {
        let dir=try folder();defer{try? FileManager.default.removeItem(at:dir)}
        let entity=SketchEntity(kind:.mesh,origin:Vec3(0,0,0),width:2,depth:3,height:4,colorHex:"#112233",mesh:MeshData(vertices:[Vec3(1,2,3),Vec3(3,2,3),Vec3(1,6,6),Vec3(3,6,6)],triangles:[0,1,2,1,3,2]),surface:SurfaceMaterial(colorHex:"#112233",faceOverrides:[FaceSurface(triangleIndices:[1],colorHex:"#445566")]))
        for ext in ["3mf","amf"] {
            let url=dir.appendingPathComponent("faces.\(ext)");let normal:ModelDocument,overridden:ModelDocument
            if ext=="3mf" {try ThreeMFFormat.write(ModelDocument(entities:[entity]),to:url);normal=try ThreeMFFormat.read(url:url);overridden=try ThreeMFFormat.read(url:url,metersPerUnit:1,zUp:false)}
            else {try AMFFormat.write(ModelDocument(entities:[entity]),to:url);normal=try AMFFormat.read(url:url);overridden=try AMFFormat.read(url:url,metersPerUnit:1,zUp:false)}
            XCTAssertEqual(Set(normal.entities[0].surface?.faceOverrides.map(\.colorHex) ?? []),Set(["#112233","#445566"]))
            XCTAssertEqual(overridden.entities[0].mesh?.vertices.first,Vec3(1000,-3000,2000))
            if ext=="amf" {let zipped=dir.appendingPathComponent("compressed.amf");try AssetArchive.writeStored(files:["part.amf":Data(contentsOf:url)],to:zipped);XCTAssertEqual(try AMFFormat.read(url:zipped).entities[0].mesh,normal.entities[0].mesh)}
        }
        var textured=entity;textured.surface?.textureData=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        XCTAssertThrowsError(try ThreeMFFormat.write(ModelDocument(entities:[textured]),to:dir.appendingPathComponent("texture.3mf")))
        XCTAssertThrowsError(try AMFFormat.write(ModelDocument(entities:[textured]),to:dir.appendingPathComponent("texture.amf")))
    }
    func testAMFInvalidSiblingConstellationCycleAndCurveCannotBeSilentlyDropped() throws {
        let dir=try folder();defer{try? FileManager.default.removeItem(at:dir)};let url=dir.appendingPathComponent("siblings.amf")
        try AMFFormat.write(triangle(),to:url);let valid=try String(contentsOf:url)
        let bad="<object id=\"99\"><mesh><vertices><vertex><coordinates><x>NaN</x><y>0</y><z>0</z></coordinates></vertex></vertices><volume><triangle><v1>0</v1><v2>1</v2><v3>2</v3></triangle></volume></mesh></object>"
        for extra in [bad,"<constellation id=\"50\"><instance objectid=\"50\"/></constellation>","<object id=\"99\"><mesh><vertices/><edge/></mesh></object>"] {
            try valid.replacingOccurrences(of:"</amf>",with:extra+"</amf>").write(to:url,atomically:true,encoding:.utf8)
            XCTAssertThrowsError(try AMFFormat.read(url:url))
        }
    }
    func testThreeMFRejectsSlicerPartsAndMissingOPCContentTypes() throws {
        let dir=try folder();defer{try? FileManager.default.removeItem(at:dir)};let url=dir.appendingPathComponent("parts.3mf")
        try ThreeMFFormat.write(triangle(),to:url)
        let entries=try AssetArchive.withExtracted(url:url) { root -> [String:Data] in
            var result:[String:Data]=[:]
            for name in ["[Content_Types].xml","_rels/.rels","3D/3dmodel.model"] {result[name]=try Data(contentsOf:root.appendingPathComponent(name))};return result
        }
        var missing=entries;missing["[Content_Types].xml"]=nil
        try AssetArchive.writeStored(files:missing,to:url);XCTAssertThrowsError(try ThreeMFFormat.read(url:url))
        var slicer=entries;slicer["Metadata/model_settings.config"]=Data("<settings/>".utf8)
        try AssetArchive.writeStored(files:slicer,to:url);XCTAssertThrowsError(try ThreeMFFormat.read(url:url))
    }

    func testManufacturingArchiveTraversalRejectsBeforeExtraction() throws {
        let dir=try folder();defer{try? FileManager.default.removeItem(at:dir)};let url=dir.appendingPathComponent("escape.3mf")
        try AssetArchive.writeStored(files:["aa/escape.model":Data("x".utf8)],to:url)
        var raw=try Data(contentsOf:url);let safe=Data("aa/escape.model".utf8),unsafe=Data("../escape.model".utf8)
        while let range=raw.range(of:safe) {raw.replaceSubrange(range,with:unsafe)}
        try raw.write(to:url)
        XCTAssertThrowsError(try ThreeMFFormat.read(url:url)) {error in XCTAssertTrue(error.localizedDescription.contains("unsafe"),error.localizedDescription)}
        let amf=dir.appendingPathComponent("escape.amf");try raw.write(to:amf)
        XCTAssertThrowsError(try AMFFormat.read(url:amf)) {error in XCTAssertTrue(error.localizedDescription.contains("unsafe"),error.localizedDescription)}
        XCTAssertFalse(FileManager.default.fileExists(atPath:dir.appendingPathComponent("escape.model").path))
    }

}
