import XCTest
@testable import GardenStudioCore

final class GardenStudioCoreTests: XCTestCase {
    func testDocumentRoundTripPreservesIdentityAndGeometry() throws {
        let entity = GardenEntity(name: "Rotated wall", kind: .rectangle, origin: Vec3(2, 1, -3), width: 4, depth: 0.2, height: 3, colorHex: "#AABBCC", rotation: .pi / 4)
        let document = ModelDocument(entities: [entity], name: "House")
        let decoded = try JSONDecoder().decode(ModelDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded, document)
    }

    func testHistoryUndoRedoAndDivergence() {
        var history = ModelHistory()
        let empty = ModelDocument()
        let one = ModelDocument(entities: [GardenEntity(kind: .rectangle, origin: Vec3(0, 0, 0), width: 2, depth: 3)])
        history.record(empty)
        XCTAssertEqual(history.undo(current: one), empty)
        XCTAssertTrue(history.canRedo)
        XCTAssertEqual(history.redo(current: empty), one)
        XCTAssertEqual(history.undo(current: one), empty)
        history.record(empty)
        XCTAssertFalse(history.canRedo)
        XCTAssertNil(history.redo(current: one))
    }

    func testEmptyHistoryIsSafe() {
        var history = ModelHistory()
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertNil(history.undo(current: ModelDocument()))
        XCTAssertNil(history.redo(current: ModelDocument()))
    }

    func testValidationRejectsInvalidDimensionsAndNonFiniteValues() {
        for value in [0, -1, Double.infinity, Double.nan] {
            let entity = GardenEntity(kind: .rectangle, origin: Vec3(0, 0, 0), width: value, depth: 2)
            XCTAssertThrowsError(try ModelDocument(entities: [entity]).validate())
        }
        let entity = GardenEntity(kind: .circle, origin: Vec3(.nan, 0, 0), width: 2, depth: 2)
        XCTAssertThrowsError(try ModelDocument(entities: [entity]).objString())
    }

    func testValidationRejectsDuplicateIDsAndInvalidColor() {
        let entity = GardenEntity(kind: .rectangle, origin: Vec3(0, 0, 0), width: 2, depth: 2)
        XCTAssertThrowsError(try ModelDocument(entities: [entity, entity]).validate())
        var badColor = entity
        badColor.colorHex = "nonsense"
        XCTAssertThrowsError(try ModelDocument(entities: [badColor]).validate())
    }

    func testSolidBoxExportHasEightVerticesAndSixFaces() throws {
        let entity = GardenEntity(name: "Box\nInjected", kind: .rectangle, origin: Vec3(3, 2, 4), width: 2, depth: 4, height: 6)
        let obj = try ModelDocument(entities: [entity]).objString()
        let lines = obj.split(separator: "\n")
        XCTAssertEqual(lines.filter { $0.hasPrefix("v ") }.count, 8)
        XCTAssertEqual(lines.filter { $0.hasPrefix("f ") }.count, 6)
        XCTAssertTrue(obj.contains("v 2 2 2"))
        XCTAssertTrue(obj.contains("v 4 8 6"))
        XCTAssertFalse(lines.contains("Injected"))
    }

    func testPlanarRectangleHasOneFaceAndRotationTransformsVertices() throws {
        let entity = GardenEntity(kind: .rectangle, origin: Vec3(1, 0, 1), width: 2, depth: 4, rotation: .pi / 2)
        let obj = try ModelDocument(entities: [entity]).objString()
        let lines = obj.split(separator: "\n")
        XCTAssertEqual(lines.filter { $0.hasPrefix("v ") }.count, 4)
        XCTAssertEqual(lines.filter { $0.hasPrefix("f ") }.count, 1)
        let points = lines.filter { $0.hasPrefix("v ") }.map { $0.split(separator: " ").dropFirst().compactMap { Double($0) } }
        XCTAssertTrue(points.contains { abs($0[0] + 1) < 0.00001 && abs($0[2] - 2) < 0.00001 })
    }

    func testCircleExportIsClosedAndIndicesAreGlobal() throws {
        let first = GardenEntity(kind: .rectangle, origin: Vec3(0, 0, 0), width: 1, depth: 1)
        let second = GardenEntity(kind: .circle, origin: Vec3(3, 0, 0), width: 2, depth: 4, height: 3)
        let obj = try ModelDocument(entities: [first, second]).objString()
        let lines = obj.split(separator: "\n")
        let vertices = lines.filter { $0.hasPrefix("v ") }
        let faces = lines.filter { $0.hasPrefix("f ") }
        XCTAssertEqual(vertices.count, 68)
        XCTAssertEqual(faces.count, 35)
        for face in faces.dropFirst() {
            for index in face.split(separator: " ").dropFirst().compactMap({ Int($0) }) {
                XCTAssertTrue((5...68).contains(index))
            }
        }
    }

    func testLineExportRetainsNegativeDeltas() throws {
        let line = GardenEntity(kind: .line, origin: Vec3(2, 3, 4), width: -2, depth: -4, height: -3)
        let obj = try ModelDocument(entities: [line]).objString()
        XCTAssertTrue(obj.contains("v 0 0 0"))
        XCTAssertTrue(obj.contains("l 1 2"))
        var zero = line
        zero.width = 0; zero.depth = 0; zero.height = 0
        XCTAssertThrowsError(try ModelDocument(entities: [zero]).validate())
    }

    func testDemoIsValidAndExports() throws {
        XCTAssertGreaterThan(ModelDocument.demo.entities.count, 5)
        try ModelDocument.demo.validate()
        XCTAssertFalse(try ModelDocument.demo.objString().isEmpty)
    }
}
