import XCTest
import SketchCore
@testable import SketchIO

final class GLTFNumericTypeAuditTests:XCTestCase {
    private func fixture(at url:URL)throws->[String:Any] {
        let mesh=MeshData(vertices:[Vec3(0,0,0),Vec3(1,0,0),Vec3(0,1,0)],triangles:[0,1,2])
        let entity=SketchEntity(kind:.mesh,origin:Vec3(0,0,0),width:1,depth:0,height:1,mesh:mesh)
        try GLTFFormat.write(ModelDocument(entities:[entity]),to:url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
    }
    func testBooleanIndicesAndTransformComponentsCannotBecomeNumbers()throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".gltf")
        defer{try? FileManager.default.removeItem(at:url)}
        let original=try fixture(at:url)
        var cases:[[String:Any]]=[]
        var root=original;root["scene"]=false;cases.append(root)
        root=original;var nodes=try XCTUnwrap(root["nodes"] as? [[String:Any]])
        nodes[0]["mesh"]=false;root["nodes"]=nodes;cases.append(root)
        root=original;nodes=try XCTUnwrap(root["nodes"] as? [[String:Any]])
        nodes[0]["translation"]=[true,0,0] as [Any];root["nodes"]=nodes;cases.append(root)
        for (i,root) in cases.enumerated() {
            try JSONSerialization.data(withJSONObject:root).write(to:url)
            XCTAssertThrowsError(try GLTFFormat.read(url:url),"Invalid numeric fixture \(i) was accepted")
        }
    }
    func testMalformedOptionalMaterialNumbersDoNotSilentlyDefault()throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".gltf")
        defer{try? FileManager.default.removeItem(at:url)}
        let original=try fixture(at:url)
        for value in [[true,0,0,1] as [Any],"red"] as [Any] {
            var root=original;var materials=try XCTUnwrap(root["materials"] as? [[String:Any]])
            var pbr=try XCTUnwrap(materials[0]["pbrMetallicRoughness"] as? [String:Any])
            pbr["baseColorFactor"]=value;materials[0]["pbrMetallicRoughness"]=pbr;root["materials"]=materials
            try JSONSerialization.data(withJSONObject:root).write(to:url)
            XCTAssertThrowsError(try GLTFFormat.read(url:url))
        }
        for value:Any in [true,"half"] {
            var root=original;var materials=try XCTUnwrap(root["materials"] as? [[String:Any]])
            materials[0]["alphaCutoff"]=value;root["materials"]=materials
            try JSONSerialization.data(withJSONObject:root).write(to:url)
            XCTAssertThrowsError(try GLTFFormat.read(url:url))
        }
    }
    func testNumericNormalizationFlagCannotBecomeBoolean()throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".gltf")
        defer{try? FileManager.default.removeItem(at:url)}
        var root=try fixture(at:url),accessors=try XCTUnwrap(root["accessors"] as? [[String:Any]])
        accessors[0]["normalized"]=0;root["accessors"]=accessors
        try JSONSerialization.data(withJSONObject:root).write(to:url)
        XCTAssertThrowsError(try GLTFFormat.read(url:url))
    }
    func testOrdinaryNumbersAndBooleanFlagsRemainSupported()throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".gltf")
        defer{try? FileManager.default.removeItem(at:url)}
        var root=try fixture(at:url),nodes=try XCTUnwrap(root["nodes"] as? [[String:Any]])
        nodes[0]["translation"]=[1,2,3];root["nodes"]=nodes
        var accessors=try XCTUnwrap(root["accessors"] as? [[String:Any]])
        accessors[0]["normalized"]=false;root["accessors"]=accessors
        try JSONSerialization.data(withJSONObject:root).write(to:url)
        let document=try GLTFFormat.read(url:url)
        XCTAssertEqual(document.entities[0].mesh?.vertices.first,Vec3(1,2,3))
    }
}
