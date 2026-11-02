import XCTest
import SketchCore
@testable import SketchIO
final class SVGUnpaintedAudit9Tests:XCTestCase {
    private func file(_ body:String)throws->URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".svg")
        try ("<svg xmlns='http://www.w3.org/2000/svg' width='100mm' height='100mm' viewBox='0 0 100 100'>"+body+"</svg>").write(to:url,atomically:true,encoding:.utf8)
        addTeardownBlock{try? FileManager.default.removeItem(at:url)}
        return url
    }
    func testUnpaintedGeometryDoesNotBecomeExtraCNCCutPaths()throws {
        let source=try file("<path fill='none' stroke='#AA3300' d='M0 0 L20 0'/><path fill='none' stroke='none' d='M30 0 L50 0'/>")
        let paths=try VectorProfiles.paths(document:SVGFormat.read(url:source))
        XCTAssertEqual(paths.count,1)
        XCTAssertEqual(paths[0].colorHex,"#AA3300")
        XCTAssertLessThan(paths[0].points.map(\.x).max()!,0.03)
    }
    func testUnpaintedParentStillAllowsAnExplicitlyPaintedChild()throws {
        let source=try file("<g fill='none' stroke='none'><path d='M30 0 L50 0'/><path stroke='#00AA33' d='M0 0 L20 0'/></g>")
        let paths=try VectorProfiles.paths(document:SVGFormat.read(url:source))
        XCTAssertEqual(paths.count,1)
        XCTAssertEqual(paths[0].colorHex,"#00AA33")
    }
    func testCompletelyUnpaintedSVGHasNoImportableCutGeometry()throws {
        XCTAssertThrowsError(try SVGFormat.read(url:file("<rect width='20' height='10' fill='none' stroke='none'/>")))
    }
}
