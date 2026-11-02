import XCTest
import Foundation
import CoreGraphics
import ImageIO
import GardenStudioCore
@testable import GardenStudioIO

final class CommonMeshFormatTests: XCTestCase {
    func testOBJNegativeIndicesConcavePolygonAndMaterial() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "newmtl red\nKd 1 0 0\n".write(to: dir.appendingPathComponent("color.mtl"), atomically: true, encoding: .utf8)
        let url = dir.appendingPathComponent("test.obj")
        try "mtllib color.mtl\no Notch\nv 0 0 0\nv 2 0 0\nv 2 2 0\nv 1 1 0\nv 0 2 0\nusemtl red\nf -5 -4 -3 -2 -1\n".write(to: url, atomically: true, encoding: .utf8)
        let doc = try OBJFormat.read(url: url)
        XCTAssertEqual(doc.entities[0].mesh?.triangles.count, 9)
        XCTAssertEqual(doc.entities[0].surface?.faceOverrides.first?.colorHex, "#FF0000")
        try "mtllib ../escape.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try OBJFormat.read(url: url))
    }
    func testCommonMeshRoundtripsUnitsAxesAndColor() throws {
        let entity = GardenEntity(name: "Test", kind: .mesh, origin: Vec3(3,4,5), width: 2, depth: 3, height: 4, colorHex: "#123456", mesh: MeshData(vertices: [Vec3(1,2,3),Vec3(3,2,3),Vec3(1,6,6)], triangles: [0,1,2]))
        let doc = ModelDocument(entities: [entity])
        for ext in ["obj","ply","off"] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("mesh-\(UUID().uuidString).\(ext)")
            defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("mtl")) }
            let result: ModelDocument
            switch ext {
            case "obj": try OBJFormat.write(doc, to: url, metersPerUnit: 0.001, zUp: true); result = try OBJFormat.read(url: url, metersPerUnit: 0.001, zUp: true)
            case "ply": try PLYFormat.write(doc, to: url, binary: true, metersPerUnit: 0.001, zUp: true); result = try PLYFormat.read(url: url, metersPerUnit: 0.001, zUp: true)
            default: try OFFFormat.write(doc, to: url, metersPerUnit: 0.001, zUp: true); result = try OFFFormat.read(url: url, metersPerUnit: 0.001, zUp: true)
            }
            XCTAssertEqual(result.entities[0].mesh?.vertices, try entity.triangulatedMesh().vertices)
            XCTAssertEqual(result.entities[0].mesh?.triangles.count, 3)
            if ext != "off" { XCTAssertEqual(result.entities[0].surface?.faceOverrides.first?.colorHex,"#123456") }
        }
    }
    func testRejectMalformedMeshes() throws {
        for (ext,text) in [("off","OFF\n3 1 0\n0 0 0\n1 0 0\n0 1 0\n3 0 1 7\n"),("ply","ply\nformat ascii 1.0\nelement vertex 3\nproperty float x\nproperty float y\nproperty float z\nelement face 1\nproperty list uchar int vertex_indices\nend_header\n0 0 0\n1 0 0\n0 1 0\n3 0 1 7\n")] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
            defer { try? FileManager.default.removeItem(at: url) }
            try text.write(to: url, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try ext == "off" ? OFFFormat.read(url: url) : PLYFormat.read(url: url))
        }
    }
    func testOBJUVSeamsAndExportWithSpacedFilename() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let url = dir.appendingPathComponent("seams.obj")
        try "v 0 0 0\nv 1 0 0\nv 0 1 0\nvt 0 0\nvt 1 0\nvt 0 1\nvt 0.5 0.5\nf 1/1 2/2 3/3\nf 1/4 3/3 2/2\n".write(to:url,atomically:true,encoding:.utf8)
        let doc = try OBJFormat.read(url:url)
        XCTAssertEqual(doc.entities[0].mesh?.vertices.count,4)
        XCTAssertEqual(doc.entities[0].mesh?.textureCoordinates?.count,4)
        XCTAssertEqual(doc.entities[0].mesh?.textureCoordinates?.last,TextureCoordinate(u:0.5,v:0.5))
        let spaced = dir.appendingPathComponent("my model.obj")
        try OBJFormat.write(doc,to:spaced)
        XCTAssertEqual(try OBJFormat.read(url:spaced).entities[0].mesh?.textureCoordinates,doc.entities[0].mesh?.textureCoordinates)
    }
    func testPLYBigEndianAndVertexColors() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ply")
        defer { try? FileManager.default.removeItem(at:url) }
        var bytes = Data("ply\nformat binary_big_endian 1.0\nelement vertex 3\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nelement face 1\nproperty list uchar int vertex_indices\nend_header\n".utf8)
        for (p,c) in [(Vec3(0,0,0),[UInt8(255),0,0]),(Vec3(1,0,0),[UInt8(0),255,0]),(Vec3(0,1,0),[UInt8(0),0,255])] {
            for f in [Float(p.x),Float(p.y),Float(p.z)] { var n = f.bitPattern.bigEndian; withUnsafeBytes(of:&n) { bytes.append(contentsOf:$0) } }; bytes.append(contentsOf:c)
        }
        bytes.append(3)
        for i in 0..<3 { var n = Int32(i).bigEndian; withUnsafeBytes(of:&n) { bytes.append(contentsOf:$0) } }
        try bytes.write(to:url)
        let doc = try PLYFormat.read(url:url)
        XCTAssertEqual(doc.entities[0].mesh?.triangles.count,18)
        XCTAssertEqual(Set(doc.entities[0].surface?.faceOverrides.map(\.colorHex) ?? []),Set(["#FF0000","#00FF00","#0000FF"]))
        bytes.removeLast()
        try bytes.write(to:url)
        XCTAssertThrowsError(try PLYFormat.read(url:url))
    }

    func testOBJTextureExportProducesUVAndRejectsTraversal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        var e = GardenEntity(name:"Tile",kind:.rectangle,origin:Vec3(1,2,3),width:2,depth:4)
        // Use the same valid one-pixel fixture as the COLLADA tests.
        e.surface = SurfaceMaterial(textureData:Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!)
        let url = dir.appendingPathComponent("tile.obj")
        try OBJFormat.write(ModelDocument(entities:[e]),to:url)
        let doc = try OBJFormat.read(url:url)
        XCTAssertNotNil(doc.entities[0].mesh?.textureCoordinates)
        XCTAssertEqual(doc.entities[0].surface?.faceOverrides.first?.textureData,e.surface?.textureData)
        let mtl = dir.appendingPathComponent("tile.mtl")
        for path in ["../bad.png","https://example.com/bad.png","/tmp/bad.png"] {
            try "newmtl material_1\nKd 1 1 1\nmap_Kd \(path)\n".write(to:mtl,atomically:true,encoding:.utf8)
            XCTAssertThrowsError(try OBJFormat.read(url:url))
        }
    }

    func testExportRejectsCoordinateOverflowAndInvalidUnits() throws {
        let e = GardenEntity(kind:.mesh,origin:Vec3(0,0,0),width:1,depth:1,mesh:MeshData(vertices:[Vec3(1e200,0,0),Vec3(1e200,1,0),Vec3(1e200,0,1)],triangles:[0,1,2]))
        let doc = ModelDocument(entities:[e])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:url) }
        XCTAssertThrowsError(try OBJFormat.write(doc,to:url,metersPerUnit:1e-200,includeMaterials:false))
        XCTAssertThrowsError(try PLYFormat.write(doc,to:url,metersPerUnit:1e-200))
        XCTAssertThrowsError(try OFFFormat.write(doc,to:url,metersPerUnit:1e-200))
        XCTAssertThrowsError(try OFFFormat.write(doc,to:url,metersPerUnit:0))
    }

    func testExportedArtifactsOpenWithInstalledAssimp() throws {
        let executable = ["/opt/homebrew/bin/assimp","/usr/local/bin/assimp"].first { FileManager.default.isExecutableFile(atPath:$0) }
        guard let executable else { throw XCTSkip("Optional independent Assimp reader is not installed.") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let e = GardenEntity(kind:.mesh,origin:Vec3(0,0,0),width:1,depth:1,mesh:MeshData(vertices:[Vec3(0,0,0),Vec3(1,0,0),Vec3(0,1,0)],triangles:[0,1,2]))
        let doc = ModelDocument(entities:[e])
        for ext in ["obj","ply","off"] {
            let url = dir.appendingPathComponent("independent.\(ext)")
            switch ext { case "obj": try OBJFormat.write(doc,to:url); case "ply": try PLYFormat.write(doc,to:url,binary:true); default: try OFFFormat.write(doc,to:url) }
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath:executable); process.arguments = ["info",url.path]; process.standardOutput = output; process.standardError = output
            try process.run()
            let text = String(data:output.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? ""
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus,0,"\(ext): \(text)")
            XCTAssertTrue(text.contains("Meshes:"),text)
        }
    }


    func testOBJBottomLeftUVConvertsToCanonicalTopLeft() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let input = dir.appendingPathComponent("input.obj"), output = dir.appendingPathComponent("output.obj")
        try "v 0 0 0\nv 2 0 0\nv 0 3 0\nvt 0.1 0.2\nvt 0.7 0.3\nvt 0.4 0.9\nf 1/1 2/2 3/3\n".write(to:input,atomically:true,encoding:.utf8)
        let model = try OBJFormat.read(url:input)
        let uv = try XCTUnwrap(model.entities.first?.mesh?.textureCoordinates)
        for (actual,expected) in zip(uv,[TextureCoordinate(u:0.1,v:0.8),TextureCoordinate(u:0.7,v:0.7),TextureCoordinate(u:0.4,v:0.1)]) { XCTAssertEqual(actual.u,expected.u,accuracy:1e-9); XCTAssertEqual(actual.v,expected.v,accuracy:1e-9) }
        try OBJFormat.write(model,to:output,includeMaterials:false)
        let raw = try String(contentsOf:output).components(separatedBy:.newlines).filter { $0.hasPrefix("vt ") }
        for (line,expected) in zip(raw,[0.2,0.3,0.9]) { XCTAssertEqual(try XCTUnwrap(Double(line.split(separator:" ")[2])),expected,accuracy:1e-9) }
    }

    func testOBJUVConventionMatchesAssimpGLBAtEachWorldVertex() throws {
        let executable = ["/opt/homebrew/bin/assimp","/usr/local/bin/assimp"].first { FileManager.default.isExecutableFile(atPath:$0) }
        guard let executable else { throw XCTSkip("Optional independent Assimp converter is not installed.") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let obj = dir.appendingPathComponent("asymmetric.obj"), glb = dir.appendingPathComponent("asymmetric.glb")
        try "o UVTest\nv 0 0 0\nv 2 0 0\nv 0 3 0\nvt 0.1 0.2\nvt 0.7 0.3\nvt 0.4 0.9\nf 1/1 2/2 3/3\n".write(to:obj,atomically:true,encoding:.utf8)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath:executable); process.arguments = ["export",obj.path,glb.path,"-fglb2"]; process.standardOutput = output; process.standardError = output
        try process.run(); let log = String(data:output.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? ""; process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus,0,log)
        let nativeOBJ = try OBJFormat.read(url:obj), nativeGLB = try GLTFFormat.read(url:glb)
        let objMesh = try XCTUnwrap(nativeOBJ.entities.first?.mesh), glbMesh = try XCTUnwrap(nativeGLB.entities.first?.mesh)
        for (index,position) in objMesh.vertices.enumerated() {
            let glbIndex = try XCTUnwrap(glbMesh.vertices.firstIndex(of:position))
            let ours = try XCTUnwrap(objMesh.textureCoordinates?[index]), reference = try XCTUnwrap(glbMesh.textureCoordinates?[glbIndex])
            XCTAssertEqual(ours.u,reference.u,accuracy:1e-6)
            XCTAssertEqual(ours.v,reference.v,accuracy:1e-6)
        }
        XCTAssertEqual(try XCTUnwrap(objMesh.textureCoordinates?.first).v,0.8,accuracy:1e-9)
        let exported = dir.appendingPathComponent("roundtrip.obj")
        try OBJFormat.write(nativeOBJ,to:exported,includeMaterials:false)
        let vt = try String(contentsOf:exported).components(separatedBy:.newlines).filter { $0.hasPrefix("vt ") }
        XCTAssertEqual(try XCTUnwrap(Double(vt[0].split(separator:" ")[2])),0.2,accuracy:1e-9)
        let reread = try XCTUnwrap(OBJFormat.read(url:exported).entities.first?.mesh?.textureCoordinates)
        for (a,b) in zip(reread,try XCTUnwrap(objMesh.textureCoordinates)) { XCTAssertEqual(a.u,b.u,accuracy:1e-9); XCTAssertEqual(a.v,b.v,accuracy:1e-9) }
    }

    func testOBJImportsLineMaterialsAndRetainsMixedFaces() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        try "newmtl red\nKd 1 0 0\nnewmtl blue\nKd 0 0 1\n".write(to:dir.appendingPathComponent("paint.mtl"),atomically:true,encoding:.utf8)
        let url = dir.appendingPathComponent("lines.obj")
        try "mtllib paint.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nv 2 0 0\nusemtl red\nl 1 2 4\nusemtl blue\nl 2 3\nf 1 2 3\n".write(to:url,atomically:true,encoding:.utf8)
        let doc = try OBJFormat.read(url:url)
        XCTAssertEqual(doc.entities.compactMap(\.mesh).reduce(0) {$0+$1.lineIndices.count},6)
        XCTAssertEqual(doc.entities.compactMap(\.mesh).reduce(0) {$0+$1.triangles.count},3)
        let wires = doc.entities.filter { !($0.mesh?.lineIndices.isEmpty ?? true) }
        XCTAssertEqual(wires.count,2)
        XCTAssertEqual(Set(wires.map(\.colorHex)),Set(["#FF0000","#0000FF"]))
        let red = try XCTUnwrap(wires.first {$0.colorHex == "#FF0000"})
        XCTAssertEqual(red.mesh?.lineIndices.count,4)
        XCTAssertEqual(red.surface?.colorHex,"#FF0000")
        XCTAssertTrue(red.mesh?.triangles.isEmpty ?? false)
        let face = try XCTUnwrap(doc.entities.first { !($0.mesh?.triangles.isEmpty ?? true) })
        XCTAssertEqual(face.surface?.faceOverrides.first?.colorHex,"#0000FF")
        try "mtllib paint.mtl\nv 0 0 0\nv 1 0 0\nusemtl missing\nl 1 2\n".write(to:url,atomically:true,encoding:.utf8)
        XCTAssertThrowsError(try OBJFormat.read(url:url))
    }

    func testOBJExportsBaseLinePaintAfterFaceOverride() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let url = dir.appendingPathComponent("mixed.obj")
        let surface = SurfaceMaterial(colorHex:"#FF0000",faceOverrides:[FaceSurface(triangleIndices:[0],colorHex:"#0000FF")])
        let e = GardenEntity(kind:.mesh,origin:Vec3(2,3,4),width:1,depth:0,height:1,colorHex:"#FF0000",mesh:MeshData(vertices:[Vec3(0,0,0),Vec3(1,0,0),Vec3(0,1,0)],triangles:[0,1,2],lineIndices:[0,2]),surface:surface)
        try OBJFormat.write(ModelDocument(entities:[e]),to:url)
        let raw = try String(contentsOf:url).components(separatedBy:.newlines)
        let lineIndex = try XCTUnwrap(raw.firstIndex {$0.hasPrefix("l ")})
        XCTAssertEqual(raw[lineIndex-1],"usemtl material_1")
        let doc = try OBJFormat.read(url:url)
        let wire = try XCTUnwrap(doc.entities.first { !($0.mesh?.lineIndices.isEmpty ?? true) })
        XCTAssertEqual(wire.colorHex,"#FF0000")
        XCTAssertEqual(wire.mesh?.lineIndices.count,2)
        XCTAssertEqual(wire.mesh?.vertices,[Vec3(2,3,4),Vec3(2,4,4)])
        XCTAssertEqual(doc.entities.compactMap(\.mesh).reduce(0) {$0+$1.triangles.count},3)
        let plain = GardenEntity(kind:.line,origin:Vec3(0,0,0),width:1,depth:0,colorHex:"#00FF00")
        try OBJFormat.write(ModelDocument(entities:[plain]),to:url)
        XCTAssertEqual(try OBJFormat.read(url:url).entities.first?.colorHex,"#00FF00")
    }

    private func texturePixelPNG(_ rgba: [UInt8]) throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data:Data(rgba) as CFData))
        let image = try XCTUnwrap(CGImage(width:1,height:1,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        let result = NSMutableData(), destination = try XCTUnwrap(CGImageDestinationCreateWithData(result,"public.png" as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,nil); XCTAssertTrue(CGImageDestinationFinalize(destination)); return result as Data
    }
    private func texturePixelRGBA(_ data: Data) throws -> [Int] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil)), image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
        var pixel = [UInt8](repeating:0,count:4)
        let context = try XCTUnwrap(CGContext(data:&pixel,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image,in:CGRect(x:0,y:0,width:1,height:1))
        let alpha = Int(pixel[3]); return (0..<3).map { alpha == 0 ? 0 : Int((Double(pixel[$0])*255/Double(alpha)).rounded()) } + [alpha]
    }
    func testOBJExternalDiffuseTintBakesLinearRGBAndWhitePreservesBytes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let pixel = try texturePixelPNG([200,120,40,255]); try pixel.write(to:dir.appendingPathComponent("pixel.png"))
        let url = dir.appendingPathComponent("tint.obj"), mtl = dir.appendingPathComponent("tint.mtl")
        try "mtllib tint.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nvt 0 0\nvt 1 0\nvt 0 1\nusemtl tint\nf 1/1 2/2 3/3\n".write(to:url,atomically:true,encoding:.utf8)
        for reversed in [false,true] {
            let kd = "Kd 0.5 0.25 1\n", map = "map_Kd pixel.png\n"
            try ("newmtl tint\n" + (reversed ? map+kd : kd+map)).write(to:mtl,atomically:true,encoding:.utf8)
            let doc = try OBJFormat.read(url:url), texture = try XCTUnwrap(doc.entities.first?.surface?.faceOverrides.first?.textureData)
            // Independent sRGB→linear, multiply .5/.25/1, linear→sRGB gives 146/61/40.
            XCTAssertEqual(try texturePixelRGBA(texture),[146,61,40,255])
        }
        try "newmtl tint\nKd 1 1 1\nmap_Kd pixel.png\n".write(to:mtl,atomically:true,encoding:.utf8)
        XCTAssertEqual(try OBJFormat.read(url:url).entities.first?.surface?.faceOverrides.first?.textureData,pixel)
    }
    func testOBJTexturedExportUsesWhiteDiffuseAndRetainsFallbackColor() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let pixel = try texturePixelPNG([200,120,40,255])
        let e = GardenEntity(kind:.rectangle,origin:Vec3(0,0,0),width:1,depth:1,colorHex:"#804020",surface:SurfaceMaterial(colorHex:"#804020",textureData:pixel))
        let url = dir.appendingPathComponent("white.obj")
        try OBJFormat.write(ModelDocument(entities:[e]),to:url)
        let mtl = try String(contentsOf:dir.appendingPathComponent("white.mtl"))
        XCTAssertTrue(mtl.contains("Kd 1 1 1\n"),mtl)
        let ours = try OBJFormat.read(url:url), appearance = try XCTUnwrap(ours.entities.first?.surface?.faceOverrides.first)
        XCTAssertEqual(appearance.colorHex,"#804020"); XCTAssertEqual(appearance.textureData,pixel)
        XCTAssertEqual(try texturePixelRGBA(try XCTUnwrap(appearance.textureData)),[200,120,40,255])
        if let executable = ["/opt/homebrew/bin/assimp","/usr/local/bin/assimp"].first(where:{FileManager.default.isExecutableFile(atPath:$0)}) {
            let process = Process(), output = Pipe(), glb = dir.appendingPathComponent("white.glb")
            process.executableURL = URL(fileURLWithPath:executable); process.arguments = ["export",url.path,glb.path,"-fglb2"]; process.standardOutput = output; process.standardError = output
            try process.run(); let log = String(data:output.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? ""; process.waitUntilExit(); XCTAssertEqual(process.terminationStatus,0,log)
            let converted = try GLTFFormat.read(url:glb), texture = try XCTUnwrap(converted.entities.first?.surface?.textureData)
            XCTAssertEqual(try texturePixelRGBA(texture),[200,120,40,255])
        }
    }

}
