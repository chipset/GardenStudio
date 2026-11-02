import XCTest
import GardenStudioCore
@testable import GardenStudioIO

final class ColladaValidationTests: XCTestCase {
    private func withBoxes(_ body: (URL, String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("boxes.dae")
        let boxes = [0.0, 3.0].enumerated().map { index, x in
            GardenEntity(name: "Box \(index)", kind: .rectangle, origin: Vec3(x, 0, 0), width: 1, depth: 1, height: 1)
        }
        try ColladaFormat.write(ModelDocument(entities: boxes), to: url)
        try body(url, String(contentsOf: url, encoding: .utf8))
    }

    private func replacingFirst(_ text: String, _ old: String, _ new: String) -> String {
        var changed = text
        if let range = changed.range(of: old) { changed.replaceSubrange(range, with: new) }
        return changed
    }

    func testMalformedReferencedGeometryCannotDisappearBesideValidObject() throws {
        try withBoxes { url, xml in
            let broken = replacingFirst(xml, "<p>0 0 1 1 2 2", "<p>999 0 1 1 2 2")
            XCTAssertNotEqual(broken, xml)
            try broken.write(to: url, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try ColladaFormat.read(url: url))
        }
    }

    func testInvalidSourcesAndPrimitiveTablesRejectWholeImport() throws {
        try withBoxes { url, xml in
            let mutations = [
                ("<p>0 0 1 1 2 2", "<p>-1 0 1 1 2 2"),
                ("<p>0 0 1 1 2 2", "<p>0 999 1 1 2 2"),
                ("source=\"#shape0-positions\"", "source=\"#missing\""),
                ("source=\"#shape0-array\" count=\"8\"", "source=\"#shape0-array\" count=\"999\""),
                ("<float_array id=\"shape0-array\" count=\"24\">", "<float_array id=\"shape0-array\" count=\"23\">"),
                ("-0.5 0 -0.5", "nan 0 -0.5"),
                ("<triangles count=\"12\"", "<triangles count=\"11\""),
                ("source=\"#shape0-array\" count=\"8\" stride=\"3\"", "source=\"#shape0-array\" count=\"8\" stride=\"0\""),
                ("source=\"#shape0-array\" count=\"8\"", "source=\"#shape0-array\" count=\"8\" offset=\"-1\""),
                ("<param name=\"X\" type=\"float\"/><param name=\"Y\" type=\"float\"/><param name=\"Z\" type=\"float\"/>", "<param name=\"POSITION\" type=\"float3\"/>"),
                ("source=\"#shape0-uv\" offset=\"1\"", "source=\"#shape0-uv\" offset=\"-1\"")
            ]
            for (old, new) in mutations {
                let broken = replacingFirst(xml, old, new)
                XCTAssertNotEqual(broken, xml, old)
                try broken.write(to: url, atomically: true, encoding: .utf8)
                XCTAssertThrowsError(try ColladaFormat.read(url: url), old)
            }
        }
    }

    func testUnusedGeometryDoesNotRequireDecoding() throws {
        try withBoxes { url, xml in
            let start = try XCTUnwrap(xml.range(of: "<geometry id=\"shape0\""))
            let end = try XCTUnwrap(xml.range(of: "</geometry>", range: start.lowerBound..<xml.endIndex))
            let unused = String(xml[start.lowerBound..<end.upperBound]).replacingOccurrences(of: "shape0", with: "unused")
            try xml.replacingOccurrences(of: "</library_geometries>", with: unused + "</library_geometries>").write(to: url, atomically: true, encoding: .utf8)
            XCTAssertEqual(try ColladaFormat.read(url: url).entities.count, 2)
        }
    }
    private func replacingPrimitive(_ xml: String, with primitive: String) throws -> String {
        let start = try XCTUnwrap(xml.range(of: "<triangles"))
        let end = try XCTUnwrap(xml.range(of: "</triangles>", range: start.lowerBound..<xml.endIndex))
        var changed = xml
        changed.replaceSubrange(start.lowerBound..<end.upperBound, with: primitive)
        return changed
    }

    func testPolygonAndStripTablesValidateBeforeNativeDecoding() throws {
        try withBoxes { url, xml in
            let vertex = "<input semantic=\"VERTEX\" source=\"#shape0-vertices\" offset=\"0\"/>"
            let cases = [
                ("triangles", "", "0 1 2"),
                ("lines", "", "0 1"),
                ("polylist", "<vcount>3</vcount>", "0 1 2"),
                ("polygons", "", "0 1 2"),
                ("tristrips", "", "0 1 2")
            ]
            for (kind, extra, indices) in cases {
                let valid = "<\(kind) count=\"1\" material=\"surface0\">\(vertex)\(extra)<p>\(indices)</p></\(kind)>"
                try replacingPrimitive(xml, with: valid).write(to: url, atomically: true, encoding: .utf8)
                XCTAssertEqual(try ColladaFormat.read(url: url).entities.count, 2, kind)
                let broken = replacingFirst(valid, "<p>0", "<p>999")
                try replacingPrimitive(xml, with: broken).write(to: url, atomically: true, encoding: .utf8)
                XCTAssertThrowsError(try ColladaFormat.read(url: url), kind)
            }
            // SceneKit silently drops these primitive types instead of reporting them.
            for kind in ["trifans", "linestrips", "points"] {
                let unsupported = "<\(kind) count=\"1\">\(vertex)<p>0 1 2</p></\(kind)>"
                try replacingPrimitive(xml, with: unsupported).write(to: url, atomically: true, encoding: .utf8)
                XCTAssertThrowsError(try ColladaFormat.read(url: url), kind)
            }
            for counts in ["2", "-3", "3 3", "4"] {
                let broken = "<polylist count=\"1\">\(vertex)<vcount>\(counts)</vcount><p>0 1 2</p></polylist>"
                try replacingPrimitive(xml, with: broken).write(to: url, atomically: true, encoding: .utf8)
                XCTAssertThrowsError(try ColladaFormat.read(url: url), counts)
            }
        }
    }

    func testNormalIndicesAreValidatedEvenWhenPositionsAreValid() throws {
        try withBoxes { url, xml in
            let input = "<input semantic=\"VERTEX\" source=\"#shape0-vertices\" offset=\"0\"/><input semantic=\"NORMAL\" source=\"#shape0-positions\" offset=\"1\"/>"
            for normal in [-1, 8, 999] {
                let broken = "<triangles count=\"1\">\(input)<p>0 \(normal) 1 0 2 0</p></triangles>"
                try replacingPrimitive(xml, with: broken).write(to: url, atomically: true, encoding: .utf8)
                XCTAssertThrowsError(try ColladaFormat.read(url: url), "normal \(normal)")
            }
        }
    }

}
