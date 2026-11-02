import XCTest
import GardenStudioCore
import CoreGraphics
import ImageIO
@testable import GardenStudioIO

final class GLTFAuditRegressionTests:XCTestCase {
    private func directory()throws->URL {
        let result=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:result,withIntermediateDirectories:true)
        return result
    }
    private func fixture(at url:URL,textured:Bool=false)throws->[String:Any] {
        let mesh=MeshData(vertices:[Vec3(0,0,0),Vec3(1,0,0),Vec3(0,1,0)],triangles:[0,1,2],textureCoordinates:[.init(u:0,v:0),.init(u:2,v:0),.init(u:0,v:2)])
        let context=try XCTUnwrap(CGContext(data:nil,width:2,height:2,bitsPerComponent:8,bytesPerRow:8,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red:1,green:1,blue:1,alpha:1));context.fill(CGRect(x:0,y:0,width:2,height:2))
        let png=try ImageFormat.encode(XCTUnwrap(context.makeImage()),typeIdentifier:"public.png")
        let surface=SurfaceMaterial(textureData:textured ? png:nil)
        let entity=GardenEntity(kind:.mesh,origin:Vec3(0,0,0),width:1,depth:0,height:1,mesh:mesh,surface:surface)
        try GLTFFormat.write(ModelDocument(entities:[entity]),to:url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
    }
    func testRejectsRepeatedSceneNodesBeforeEmptyDAGExpansion()throws {
        let dir=try directory();defer{try? FileManager.default.removeItem(at:dir)}
        let url=dir.appendingPathComponent("dag.gltf")
        var root=try fixture(at:url)
        var nodes:[[String:Any]]=[["mesh":0]]
        for i in 1...16 {nodes.append(["children":[i+1,i+1]])}
        nodes.append([:]);root["nodes"]=nodes;root["scenes"]=[["nodes":[0,1]]]
        try JSONSerialization.data(withJSONObject:root).write(to:url)
        XCTAssertThrowsError(try GLTFFormat.read(url:url))
    }
    func testDistinctNodesCanStillInstanceTheSameMesh()throws {
        let dir=try directory();defer{try? FileManager.default.removeItem(at:dir)}
        let url=dir.appendingPathComponent("instances.gltf")
        var root=try fixture(at:url)
        root["nodes"]=[["mesh":0],["mesh":0,"translation":[3,0,0]]]
        root["scenes"]=[["nodes":[0,1]]]
        try JSONSerialization.data(withJSONObject:root).write(to:url)
        let document=try GLTFFormat.read(url:url)
        XCTAssertEqual(document.entities.count,2)
        XCTAssertEqual(document.entities[1].mesh?.vertices.first?.x,3)
    }
    func testRejectsClampedMirroredAndInvalidTextureSamplerReferences()throws {
        let dir=try directory();defer{try? FileManager.default.removeItem(at:dir)}
        let url=dir.appendingPathComponent("sampler.gltf")
        let original=try fixture(at:url,textured:true)
        for sampler in [["wrapS":33071],["wrapT":33648],["wrapS":0]] {
            var root=original
            var textures=try XCTUnwrap(root["textures"] as? [[String:Any]])
            textures[0]["sampler"]=0;root["textures"]=textures;root["samplers"]=[sampler]
            try JSONSerialization.data(withJSONObject:root).write(to:url)
            XCTAssertThrowsError(try GLTFFormat.read(url:url),"Sampler \(sampler) cannot be rendered as repeat")
        }
        var root=original;var textures=try XCTUnwrap(root["textures"] as? [[String:Any]])
        textures[0]["sampler"]=4;root["textures"]=textures
        try JSONSerialization.data(withJSONObject:root).write(to:url)
        XCTAssertThrowsError(try GLTFFormat.read(url:url))
    }
    func testDefaultAndExplicitRepeatTextureSamplerRemainSupported()throws {
        let dir=try directory();defer{try? FileManager.default.removeItem(at:dir)}
        let url=dir.appendingPathComponent("repeat.gltf")
        var root=try fixture(at:url,textured:true)
        XCTAssertNoThrow(try GLTFFormat.read(url:url))
        var textures=try XCTUnwrap(root["textures"] as? [[String:Any]])
        textures[0]["sampler"]=0;root["textures"]=textures;root["samplers"]=[["wrapS":10497,"wrapT":10497]]
        try JSONSerialization.data(withJSONObject:root).write(to:url)
        XCTAssertNoThrow(try GLTFFormat.read(url:url))
    }
}
