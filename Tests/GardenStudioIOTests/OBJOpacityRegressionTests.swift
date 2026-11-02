import XCTest
import GardenStudioCore
@testable import GardenStudioIO

final class OBJOpacityRegressionTests:XCTestCase {
    private func fixture(_ material:String)throws->(URL,URL) {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let url=directory.appendingPathComponent("model.obj")
        try "mtllib paint.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nusemtl Paint\nf 1 2 3\n".write(to:url,atomically:true,encoding:.utf8)
        try ("newmtl Paint\nKd 0.5 0.25 0.125\n"+material+"\n").write(to:directory.appendingPathComponent("paint.mtl"),atomically:true,encoding:.utf8)
        return (directory,url)
    }
    func testRejectsOpacityThatWouldBecomeOpaque()throws {
        for statement in ["d 0.25","d 0","Tr 0.75","map_d alpha.png","d -halo 0.5"] {
            let (directory,url)=try fixture(statement);defer{try? FileManager.default.removeItem(at:directory)}
            XCTAssertThrowsError(try OBJFormat.read(url:url),"Unsupported opacity: \(statement)")
        }
    }
    func testExplicitOpaqueMaterialRemainsCompatible()throws {
        for statement in ["d 1","Tr 0","d 1.0\nTr 0.0"] {
            let (directory,url)=try fixture(statement);defer{try? FileManager.default.removeItem(at:directory)}
            let document=try OBJFormat.read(url:url)
            XCTAssertEqual(document.entities.count,1)
            XCTAssertEqual(document.entities[0].surface?.faceOverrides.first?.colorHex,"#804020")
        }
    }
    func testMalformedOpacityRejectsInsteadOfBeingIgnored()throws {
        for statement in ["d NaN","d 2","Tr -0.5","d one","d 1 0"] {
            let (directory,url)=try fixture(statement);defer{try? FileManager.default.removeItem(at:directory)}
            XCTAssertThrowsError(try OBJFormat.read(url:url))
        }
    }
}
