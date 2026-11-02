import XCTest
import GardenStudioCore
import SceneKit
import ImageIO
import CoreGraphics
@testable import GardenStudioIO

final class GLTFFormatTests: XCTestCase {
    func testSelfContainedRoundTripPreservesMetersColorsAndUVs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mesh = MeshData(vertices: [Vec3(0,0,0),Vec3(2,0,0),Vec3(0,3,1)], triangles: [0,1,2], textureCoordinates: [TextureCoordinate(u:0,v:0),TextureCoordinate(u:1,v:0),TextureCoordinate(u:0,v:1)])
        let png=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let entity = GardenEntity(name:"Triangle",kind:.mesh,origin:Vec3(4,5,6),width:2,depth:1,height:3,colorHex:"#123456",mesh:mesh,surface:SurfaceMaterial(colorHex:"#123456",textureData:png))
        for binary in [false,true] {
            let url = root.appendingPathComponent(binary ? "model.glb" : "model.gltf")
            try GLTFFormat.write(ModelDocument(entities:[entity]),to:url,binary:binary)
            let read = try GLTFFormat.read(url:url)
            XCTAssertEqual(read.entities[0].mesh?.vertices, try entity.triangulatedMesh().vertices)
            XCTAssertEqual(read.entities[0].colorHex,"#123456")
            XCTAssertEqual(read.entities[0].mesh?.textureCoordinates,mesh.textureCoordinates)
        }
    }
    func testRejectsExternalResourcesAndMalformedGLB() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let url = root.appendingPathComponent("bad.gltf")
        for uri in ["../outside.bin","https://example.com/data.bin","file:///etc/passwd"] {
            try Data("{\"asset\":{\"version\":\"2.0\"},\"buffers\":[{\"uri\":\"\(uri)\",\"byteLength\":12}]}".utf8).write(to:url)
            XCTAssertThrowsError(try GLTFFormat.read(url:url))
        }
        try Data([0x67,0x6c,0x54,0x46,2,0,0,0,12,0,0,0]).write(to:url)
        XCTAssertThrowsError(try GLTFFormat.read(url:url))
    }
    func testTextureAndFaceColorRoundTrip() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".glb")
        defer {if FileManager.default.fileExists(atPath:url.path) {try? FileManager.default.removeItem(at:url)}}
        let png=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let mesh=MeshData(vertices:[Vec3(0,0,0),Vec3(2,0,0),Vec3(0,3,1),Vec3(2,3,1)],triangles:[0,1,2,1,3,2],textureCoordinates:[TextureCoordinate(u:0,v:0),TextureCoordinate(u:1,v:0),TextureCoordinate(u:0,v:1),TextureCoordinate(u:1,v:1)])
        let surface=SurfaceMaterial(colorHex:"#FFFFFF",textureData:png,faceOverrides:[FaceSurface(triangleIndices:[1],colorHex:"#FF0000")])
        let entity=GardenEntity(kind:.mesh,origin:Vec3(0,0,0),width:2,depth:1,height:3,mesh:mesh,surface:surface)
        try GLTFFormat.write(ModelDocument(entities:[entity]),to:url,binary:true)
        let read=try GLTFFormat.read(url:url)
        XCTAssertEqual(read.entities.count,2)
        XCTAssertTrue(read.entities.contains{$0.surface?.textureData==png})
        XCTAssertTrue(read.entities.contains{$0.colorHex=="#FF0000"})
        XCTAssertEqual(read.entities.reduce(0){$0+($1.mesh?.triangles.count ?? 0)},6)
    }
    func testTexturedRotatedBoxBakesLocalProjectionAndFaceTransforms() throws {
        let png=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let surface=SurfaceMaterial(colorHex:"#FFFFFF",textureData:png,textureScale:0.5,textureRotation:0.3,
            faceOverrides:[FaceSurface(triangleIndices:[1],colorHex:"#FF0000",textureData:png,textureScale:1.25,textureRotation:-0.2)])
        let entity=GardenEntity(name:"Painted box",kind:.rectangle,origin:Vec3(4,5,6),width:2,depth:3,height:4,rotation:0.7,surface:surface)
        var localEntity=entity;localEntity.origin=Vec3(0,0,0);localEntity.rotation=0
        let local=try localEntity.triangulatedMesh(), world=try entity.triangulatedMesh()
        for binary in [false,true] {
            let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+(binary ? ".glb":".gltf"))
            defer {if FileManager.default.fileExists(atPath:url.path) {try? FileManager.default.removeItem(at:url)}}
            try GLTFFormat.write(ModelDocument(entities:[entity]),to:url,binary:binary)
            let read=try GLTFFormat.read(url:url)
            XCTAssertEqual(read.entities.reduce(0){$0+($1.mesh?.triangles.count ?? 0)},36)
            for part in read.entities {
                let mesh=try XCTUnwrap(part.mesh), uv=try XCTUnwrap(mesh.textureCoordinates)
                let override=part.colorHex=="#FF0000"
                let sourceTriangles=override ? [1] : Array(0..<12).filter{$0 != 1}
                XCTAssertEqual(mesh.triangles.count,sourceTriangles.count*3)
                XCTAssertEqual(part.surface?.textureData,png)
                XCTAssertEqual(part.surface?.textureScale,1)
                XCTAssertEqual(part.surface?.textureRotation,0)
                let scale=override ? 1.25:0.5, rotation=override ? -0.2:0.3
                let transform=SCNMatrix4Mult(SCNMatrix4MakeRotation(rotation,0,0,1),SCNMatrix4MakeScale(1/scale,1/scale,1))
                for (faceIndex,sourceTriangle) in sourceTriangles.enumerated() {
                    let a=local.vertices[local.triangles[sourceTriangle*3]], b=local.vertices[local.triangles[sourceTriangle*3+1]], c=local.vertices[local.triangles[sourceTriangle*3+2]]
                    let nx=(b.y-a.y)*(c.z-a.z)-(b.z-a.z)*(c.y-a.y)
                    let ny=(b.z-a.z)*(c.x-a.x)-(b.x-a.x)*(c.z-a.z)
                    let nz=(b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)
                    for corner in 0..<3 {
                        let sourceIndex=local.triangles[sourceTriangle*3+corner], outputIndex=mesh.triangles[faceIndex*3+corner]
                        let p=local.vertices[sourceIndex], position=mesh.vertices[outputIndex], expectedPosition=world.vertices[sourceIndex]
                        let raw=abs(nx)>=abs(ny) && abs(nx)>=abs(nz) ? (p.z,p.y) : abs(ny)>=abs(nz) ? (p.x,p.z):(p.x,p.y)
                        let expectedU=Double(transform.m11)*raw.0+Double(transform.m21)*raw.1
                        let expectedV=Double(transform.m12)*raw.0+Double(transform.m22)*raw.1
                        XCTAssertEqual(uv[outputIndex].u,expectedU,accuracy:1e-5)
                        XCTAssertEqual(uv[outputIndex].v,expectedV,accuracy:1e-5)
                        XCTAssertEqual(position.x,expectedPosition.x,accuracy:1e-5)
                        XCTAssertEqual(position.y,expectedPosition.y,accuracy:1e-5)
                        XCTAssertEqual(position.z,expectedPosition.z,accuracy:1e-5)
                    }
                }
            }
            // Shared vertices survive where projection and material UVs agree;
            // seams duplicate only their distinct source-index/UV combinations.
            XCTAssertTrue(read.entities.allSatisfy{($0.mesh?.vertices.count ?? 0)<36})
        }
    }
    func testTextureSeamExpansionEnforcesVertexLimit() throws {
        let png=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        var vertices:[Vec3]=[], triangles:[Int]=[]
        for quad in 1...50_000 {
            let offset=vertices.count,x=Double(quad)
            vertices += [Vec3(x,0,0),Vec3(x,1,0),Vec3(x,0,1),Vec3(x+1,0,0)]
            triangles += [offset,offset+1,offset+2,offset,offset+2,offset+3]
        }
        let mesh=MeshData(vertices:vertices,triangles:triangles)
        let entity=GardenEntity(kind:.mesh,origin:Vec3(0,0,0),width:50_001,depth:1,height:1,mesh:mesh,surface:SurfaceMaterial(textureData:png))
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".glb")
        defer {if FileManager.default.fileExists(atPath:url.path) {try? FileManager.default.removeItem(at:url)}}
        XCTAssertThrowsError(try GLTFFormat.write(ModelDocument(entities:[entity]),to:url,binary:true)) {error in
            XCTAssertTrue(error.localizedDescription.contains("250,000"),error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
    }
    private func pixelPNG(_ pixel:[UInt8]) throws -> Data {
        let provider=try XCTUnwrap(CGDataProvider(data:Data(pixel) as CFData))
        let image=try XCTUnwrap(CGImage(width:1,height:1,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        let result=NSMutableData()
        let destination=try XCTUnwrap(CGImageDestinationCreateWithData(result,"public.png" as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return result as Data
    }
    private func decodedPixel(_ data:Data) throws -> [Int] {
        let source=try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil)),image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
        var pixel=[UInt8](repeating:0,count:4)
        let context=try XCTUnwrap(CGContext(data:&pixel,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image,in:CGRect(x:0,y:0,width:1,height:1))
        let alpha=Int(pixel[3])
        return (0..<3).map{alpha==0 ? 0:Int((Double(pixel[$0])*255/Double(alpha)).rounded())}+[alpha]
    }
    func testTexturedExportUsesWhiteFactorAndPreservesFallbackAndAlpha() throws {
        let png=try pixelPNG([128,64,32,128])
        let entity=GardenEntity(kind:.rectangle,origin:Vec3(0,0,0),width:2,depth:3,colorHex:"#E7DCC8",surface:SurfaceMaterial(colorHex:"#E7DCC8",textureData:png))
        for binary in [false,true] {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+(binary ? ".glb":".gltf"))
        defer {if FileManager.default.fileExists(atPath:url.path) {try? FileManager.default.removeItem(at:url)}}
        try GLTFFormat.write(ModelDocument(entities:[entity]),to:url,binary:binary)
        let encoded=try Data(contentsOf:url)
        let json:Data
        if binary {
            let count=(0..<4).reduce(0){$0 | (Int(encoded[12+$1]) << (8*$1))}
            json=encoded.subdata(in:20..<(20+count))
        } else {json=encoded}
        let root=try XCTUnwrap(JSONSerialization.jsonObject(with:json) as? [String:Any])
        let materials=try XCTUnwrap(root["materials"] as? [[String:Any]])
        let pbr=try XCTUnwrap(materials[0]["pbrMetallicRoughness"] as? [String:Any])
        XCTAssertEqual(pbr["baseColorFactor"] as? [Double],[1,1,1,1])
        XCTAssertEqual(materials[0]["alphaMode"] as? String,"BLEND")
        let read=try GLTFFormat.read(url:url)
        XCTAssertEqual(read.entities.first?.surface?.colorHex,"#E7DCC8")
        let retained=try XCTUnwrap(read.entities.first?.surface?.textureData)
        XCTAssertEqual(retained,png)
        XCTAssertEqual(try decodedPixel(retained),[128,64,32,128])
        }
    }
    func testExternalTextureFactorsAndAlphaModesBakeStandardPixelAppearance() throws {
        let png=try pixelPNG([128,64,32,128])
        let mesh=MeshData(vertices:[Vec3(0,0,0),Vec3(2,0,0),Vec3(0,3,1)],triangles:[0,1,2],textureCoordinates:[TextureCoordinate(u:0,v:0),TextureCoordinate(u:1,v:0),TextureCoordinate(u:0,v:1)])
        let entity=GardenEntity(kind:.mesh,origin:Vec3(0,0,0),width:2,depth:1,height:3,mesh:mesh)
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".gltf")
        defer {if FileManager.default.fileExists(atPath:url.path) {try? FileManager.default.removeItem(at:url)}}
        try GLTFFormat.write(ModelDocument(entities:[entity]),to:url)
        var root=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
        root["images"]=[["uri":"data:image/png;base64,"+png.base64EncodedString()]];root["textures"]=[["source":0]]
        for (mode,cutoff,expected) in [("BLEND",0.5,[92,30,32,64]),("OPAQUE",0.5,[92,30,32,255]),("MASK",0.5,[0,0,0,0]),("MASK",0.2,[92,30,32,255])] {
            root["materials"]=[["pbrMetallicRoughness":["baseColorFactor":[0.5,0.25,1,0.5],"baseColorTexture":["index":0]],"alphaMode":mode,"alphaCutoff":cutoff]]
            try JSONSerialization.data(withJSONObject:root).write(to:url)
            let read=try GLTFFormat.read(url:url),data=try XCTUnwrap(read.entities.first?.surface?.textureData)
            let pixel=try decodedPixel(data)
            for channel in 0..<4 {XCTAssertEqual(Double(pixel[channel]),Double(expected[channel]),accuracy:2,"\(mode) channel \(channel)")}
        }
        // The system decoder discards RGB under alpha zero: reject rather than
        // substitute black when OPAQUE would reveal that hidden source color.
        let transparent=try pixelPNG([128,64,32,0])
        root["images"]=[["uri":"data:image/png;base64,"+transparent.base64EncodedString()]]
        root["materials"]=[["pbrMetallicRoughness":["baseColorFactor":[1,1,1,1],"baseColorTexture":["index":0]],"alphaMode":"OPAQUE"]]
        try JSONSerialization.data(withJSONObject:root).write(to:url)
        XCTAssertThrowsError(try GLTFFormat.read(url:url)) {error in
            XCTAssertTrue(error.localizedDescription.contains("zero-alpha"),error.localizedDescription)
        }
        root["materials"]=[["pbrMetallicRoughness":["baseColorFactor":[1,1,1,0.5]],"alphaMode":"BLEND"]]
        try JSONSerialization.data(withJSONObject:root).write(to:url)
        XCTAssertThrowsError(try GLTFFormat.read(url:url)) {error in
            XCTAssertTrue(error.localizedDescription.contains("Untextured material opacity"),error.localizedDescription)
        }
    }
    func testRejectsMalformedDeclaredNormalsAndTangents() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".gltf")
        defer {if FileManager.default.fileExists(atPath:url.path) {try? FileManager.default.removeItem(at:url)}}
        for semantic in ["NORMAL","TANGENT"] {
            let width=semantic=="NORMAL" ? 3:4
            func fixture(_ mutation:String) -> [String:Any] {
                let directions:[Float]=semantic=="NORMAL" ? [0,1,0,0,1,0,0,1,0]:[1,0,0,1,1,0,0,1,1,0,0,1]
                var values:[Float]=[0,0,0,2,0,0,0,3,1]+directions
                if mutation=="nonfinite" {values[values.count-1] = .nan}
                var bytes=Data()
                for value in values {var bits=value.bitPattern.littleEndian;withUnsafeBytes(of:&bits){bytes.append(contentsOf:$0)}}
                return ["asset":["version":"2.0"],"buffers":[["byteLength":bytes.count,"uri":"data:application/octet-stream;base64,"+bytes.base64EncodedString()]],
                    "bufferViews":[["buffer":0,"byteLength":36],["buffer":0,"byteOffset":36,"byteLength":mutation=="bounds" ? 1:width*12]],
                    "accessors":[["bufferView":0,"componentType":5126,"count":3,"type":"VEC3"],["bufferView":1,"componentType":mutation=="component" ? 5123:5126,"count":mutation=="count" ? 2:3,"type":mutation=="type" ? "VEC2":semantic=="NORMAL" ? "VEC3":"VEC4"]],
                    "meshes":[["primitives":[["attributes":["POSITION":0,semantic:mutation=="reference" ? 999:1]]]]],
                    "nodes":[["mesh":0]],"scenes":[["nodes":[0]]],"scene":0]
            }
            try JSONSerialization.data(withJSONObject:fixture("valid")).write(to:url)
            XCTAssertEqual(try GLTFFormat.read(url:url).entities.first?.mesh?.triangles,[0,1,2],semantic)
            for mutation in ["reference","count","bounds","nonfinite","type","component"] {
                try JSONSerialization.data(withJSONObject:fixture(mutation)).write(to:url)
                XCTAssertThrowsError(try GLTFFormat.read(url:url),semantic+" "+mutation)
            }
        }
    }
    func testNodeTransformAndRejectsAnimation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let url = root.appendingPathComponent("transform.gltf")
        var data = Data()
        for value:Float in [0,0,0,2,0,0,0,3,1] { var bits = value.bitPattern.littleEndian; withUnsafeBytes(of:&bits) {data.append(contentsOf:$0)} }
        var json:[String:Any] = ["asset":["version":"2.0"],"buffers":[["byteLength":36,"uri":"data:application/octet-stream;base64,"+data.base64EncodedString()]],"bufferViews":[["buffer":0,"byteLength":36]],"accessors":[["bufferView":0,"componentType":5126,"count":3,"type":"VEC3"]],"meshes":[["primitives":[["attributes":["POSITION":0]]]]],"nodes":[["children":[1],"translation":[4,5,6]],["mesh":0,"scale":[2,1,1]]],"scenes":[["nodes":[0]]],"scene":0]
        try JSONSerialization.data(withJSONObject:json).write(to:url)
        XCTAssertEqual(try GLTFFormat.read(url:url).entities[0].mesh?.vertices[1],Vec3(8,5,6))
        json["nodes"] = [["mesh":0,"matrix":[-1,0,0,0,0,1,0,0,0,0,1,0,4,5,6,1]]]
        try JSONSerialization.data(withJSONObject:json).write(to:url)
        let reflected=try GLTFFormat.read(url:url)
        XCTAssertEqual(reflected.entities[0].mesh?.vertices[1],Vec3(2,5,6))
        XCTAssertEqual(reflected.entities[0].mesh?.triangles,[0,2,1])
        json["animations"] = [["channels":[]]]
        try JSONSerialization.data(withJSONObject:json).write(to:url)
        XCTAssertThrowsError(try GLTFFormat.read(url:url))
        json.removeValue(forKey:"animations")
        json["accessors"] = [["bufferView":0,"componentType":5126,"count":300,"type":"VEC3"]]
        try JSONSerialization.data(withJSONObject:json).write(to:url)
        XCTAssertThrowsError(try GLTFFormat.read(url:url))
    }
}
