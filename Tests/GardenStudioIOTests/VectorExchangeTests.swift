import XCTest
import GardenStudioCore
@testable import GardenStudioIO

final class VectorExchangeTests: XCTestCase {
    func source(_ text: String, ext: String = "svg") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try text.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testSVGPhysicalUnitsAndNestedTransforms() throws {
        let url = try source("<svg xmlns='http://www.w3.org/2000/svg' width='100mm' height='50mm' viewBox='0 0 100 50'><g transform='translate(10 5)'><path transform='scale(2)' d='M 1 2 h 3 v 4 h -3 z' stroke='#123456' fill='none'/></g></svg>")
        let paths = try VectorProfiles.paths(document: SVGFormat.read(url: url))
        XCTAssertEqual(paths.count, 1)
        XCTAssertEqual(paths[0].points[0].x, 0.012, accuracy: 1e-10)
        XCTAssertEqual(paths[0].points[0].y, 0.009, accuracy: 1e-10)
        XCTAssertTrue(paths[0].closed)
        XCTAssertEqual(paths[0].colorHex, "#123456")
    }
    func testSVGCurvesAndArc() throws {
        let url = try source("<svg><path d='M0 0 C0 10 10 10 10 0 S20 -10 20 0 Q25 10 30 0 T40 0 A5 5 0 0 1 50 0'/></svg>")
        let paths = try VectorProfiles.paths(document: SVGFormat.read(url: url))
        XCTAssertGreaterThan(paths[0].points.count, 30)
        XCTAssertEqual(paths[0].points.last!.x, 50 * 0.0254 / 96, accuracy: 1e-10)
    }
    func testSVGRejectsUnsafeAndUnsupportedAndMalformed() throws {
        for text in ["<!DOCTYPE svg [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><svg>&x;</svg>", "<svg><script>alert(1)</script></svg>", "<svg><use href='https://example.com/a.svg'/></svg>", "<svg><text>Hello</text></svg>", "<svg><path d='M0 0 L1'/></svg>", "<svg><path d='M0 0 L1 2' filter='url(#x)'/></svg>"] {
            XCTAssertThrowsError(try SVGFormat.read(url: source(text)))
        }
    }
    func testSVGRoundTripColorsAndCoordinates() throws {
        let doc = try VectorProfiles.document(paths: [VectorPath(points:[VectorPoint(x:-0.02,y:0.03),VectorPoint(x:0.12,y:0.04),VectorPoint(x:0.07,y:0.18)],closed:true,name:"a&b",colorHex:"#112233")], name:"Test")
        let url = try source("")
        try SVGFormat.write(doc,to:url)
        let paths = try VectorProfiles.paths(document:SVGFormat.read(url:url))
        XCTAssertEqual(paths[0].points[0].x,-0.02,accuracy:1e-9)
        XCTAssertEqual(paths[0].colorHex,"#112233")
    }
    func testEPSCubicAndRoundTrip() throws {
        let url = try source("%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 100 100\nnewpath 0 0 moveto 0 72 72 72 72 0 curveto stroke\nshowpage\n%%EOF",ext:"eps")
        let doc = try EPSFormat.read(url:url)
        let paths = try VectorProfiles.paths(document:doc)
        XCTAssertGreaterThan(paths[0].points.count,10)
        XCTAssertEqual(paths[0].points.last!.x,0.0254,accuracy:1e-10)
        try EPSFormat.write(doc,to:url,illustrator:true)
        XCTAssertNoThrow(try EPSFormat.read(url:url))
        XCTAssertThrowsError(try EPSFormat.read(url:source("%!PS\n0 0 moveto (x) show",ext:"eps")))
    }
    func testHolesStaySeparateAndSurfaceMeshesReject() throws {
        let face = try GeometryTools.face(points:[Vec3(0,0,0),Vec3(0,0,2),Vec3(3,0,2),Vec3(3,0,0)],holes:[[Vec3(1,0,0.5),Vec3(2,0,0.5),Vec3(2,0,1.5),Vec3(1,0,1.5)]])
        let solid=try GeometryTools.extrude(entity:face,distance:0.02)
        let doc=ModelDocument(entities:[solid])
        XCTAssertEqual(try VectorProfiles.paths(document:doc).count,2)
        let url=try source("")
        try SVGFormat.write(doc,to:url)
        XCTAssertEqual(try SVGFormat.read(url:url).entities.count,2)
        var mesh=solid;mesh.profile=nil
        XCTAssertThrowsError(try VectorProfiles.paths(document:ModelDocument(entities:[mesh])))
    }
    func testEPSRejectsExecutablePostScriptAndIncompletePaths() throws {
        for body in ["/x { pop } def", "0 0 moveto 1 lineto stroke", "0 0 moveto 1 1 lineto", "0 0 moveto 1 1 lineto clip stroke", "nan 0 moveto", "0 0 moveto 1 2 lineto bogus"] {
            XCTAssertThrowsError(try EPSFormat.read(url:source("%!PS\n"+body,ext:"eps")))
        }
    }
    func testSVGPrimitivesAndAspectRatio() throws {
        let url=try source("<svg width='200mm' height='100mm' viewBox='0 0 100 100'><rect x='0' y='0' width='10' height='20'/><circle cx='40' cy='40' r='4'/><ellipse cx='60' cy='40' rx='8' ry='4'/><line x1='0' y1='0' x2='10' y2='20'/><polygon points='0 0 10 0 5 10'/><polyline points='0 0 10 0 5 10'/></svg>")
        let p=try VectorProfiles.paths(document:SVGFormat.read(url:url))
        XCTAssertEqual(p.count,6)
        XCTAssertEqual(p[0].points[0].x,0.05,accuracy:1e-10)
        XCTAssertEqual(p[0].points[1].x,0.06,accuracy:1e-10)
        XCTAssertFalse(p[3].closed)
        XCTAssertTrue(p[4].closed)
    }
    func testSVGUsesUniqueValidIDsAndPreservesArbitraryLabels() throws {
        let labels=["same name", "same name", "5: holes & <cut> \"quoted\"\nnext\tline"]
        let paths=labels.enumerated().map { index,name in
            VectorPath(points:[VectorPoint(x:Double(index),y:0),VectorPoint(x:Double(index)+0.1,y:0.2)],closed:false,name:name)
        }
        let document=try VectorProfiles.document(paths:paths,name:"Labels")
        let url=try source("")
        try SVGFormat.write(document,to:url)
        let first=try Data(contentsOf:url)
        let xml=try XMLDocument(contentsOf:url)
        let nodes=try xml.nodes(forXPath:"//*[local-name()='path']").compactMap {$0 as? XMLElement}
        let ids=nodes.compactMap {$0.attribute(forName:"id")?.stringValue}
        XCTAssertEqual(ids.count,3)
        XCTAssertEqual(Set(ids).count,3)
        XCTAssertTrue(ids.allSatisfy {$0.range(of:"^[A-Za-z_][A-Za-z0-9_.-]*$",options:.regularExpression) != nil})
        XCTAssertEqual(nodes.compactMap {$0.attribute(forName:"data-name")?.stringValue},labels)
        XCTAssertEqual(try VectorProfiles.paths(document:SVGFormat.read(url:url)).map(\.name),labels)
        try SVGFormat.write(document,to:url)
        XCTAssertEqual(try Data(contentsOf:url),first)
    }
    func testProjectionRejectsSurfaceAndVerticalLine() throws {
        XCTAssertThrowsError(try VectorProfiles.paths(document:ModelDocument(entities:[GardenEntity(kind:.line,origin:Vec3(0,0,0),width:0,depth:0,height:1)])))
    }
}
