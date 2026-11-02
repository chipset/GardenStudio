import Foundation
import XCTest
@testable import GardenStudioCore

final class PresentationStateTests: XCTestCase {
    func testOldEmptyPresentationDecodesWithUsableDefaults() throws {
        let state = try JSONDecoder().decode(PresentationState.self, from: Data("{}".utf8))
        XCTAssertTrue(state.scenes.isEmpty)
        XCTAssertFalse(state.shadows)
        XCTAssertEqual(state.style, "solid")
        XCTAssertGreaterThan(state.camera.distance, 0)
        XCTAssertNoThrow(try state.validate())
    }
    func testScenesAnnotationsAndCutRoundTripWithoutLosingIdentity() throws {
        let scene = SavedScene(name: "Section", camera: CameraState(target: Vec3(2, 3, 4), yaw: 1, pitch: 0.4, distance: 12, orthographic: true), hiddenIDs: [UUID()])
        let state = PresentationState(scenes: [scene], annotations: [ModelAnnotation(kind: "dimension", start: Vec3(0, 0, 0), end: Vec3(3, 0, 4))], guides: [GuideLine(start: Vec3(0, 0, 0), end: Vec3(0, 0, 8))], style: "xray", shadows: true, orthographic: true, section: SectionPlane(point: Vec3(2, 0, 0), normal: Vec3(8, 0, 0)))
        try state.validate()
        let copy = try JSONDecoder().decode(PresentationState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(copy, state)
        XCTAssertEqual(copy.scenes[0].id, scene.id)
    }
    func testCustomDrawingAxesPersistAndRejectNonOrthogonalBasis() throws {
        let axes=try DrawingAxes(origin:Vec3(2,3,4),xAxis:Vec3(0,0,-1),normal:Vec3(0,1,0))
        let state=PresentationState(drawingAxes:axes)
        let copy=try JSONDecoder().decode(PresentationState.self,from:JSONEncoder().encode(state))
        XCTAssertEqual(copy.drawingAxes,axes)
        XCTAssertThrowsError(try DrawingAxes(origin:Vec3(0,0,0),xAxis:Vec3(1,0,0),normal:Vec3(1,1,0)))
        var corrupted=axes;corrupted.yAxis=Vec3(0,1,0)
        XCTAssertThrowsError(try PresentationState(drawingAxes:corrupted).validate())
    }
    func testSectionPlaneDistanceIsInvariantUnderNormalMagnitude() throws {
        let first = SectionPlane(point: Vec3(2, 0, 0), normal: Vec3(10, 0, 0))
        let second = SectionPlane(point: Vec3(2, 0, 0), normal: Vec3(1, 0, 0))
        XCTAssertEqual(try first.signedDistance(to: Vec3(5, 99, -2)), 3, accuracy: 1e-12)
        XCTAssertEqual(try first.signedDistance(to: Vec3(-1, 0, 0)), try second.signedDistance(to: Vec3(-1, 0, 0)), accuracy: 1e-12)
        XCTAssertEqual(try first.normalized().normal, Vec3(1, 0, 0))
    }
    func testInvalidCutAndMissingDimensionEndRejected() throws {
        XCTAssertThrowsError(try PresentationState(section: SectionPlane(point: Vec3(0, 0, 0), normal: Vec3(0, 0, 0))).validate())
        XCTAssertThrowsError(try PresentationState(annotations: [ModelAnnotation(kind: "dimension", start: Vec3(0, 0, 0))]).validate())
        XCTAssertThrowsError(try PresentationState(guides: [GuideLine(start: Vec3(0, 0, 0), end: Vec3(0, 0, 0))]).validate())
    }
    func testNonfiniteCameraUnknownStyleAndDuplicateIDsRejected() throws {
        XCTAssertThrowsError(try PresentationState(camera: CameraState(distance: .infinity)).validate())
        XCTAssertThrowsError(try PresentationState(style: "unsupported").validate())
        let annotation = ModelAnnotation(kind: "text", start: Vec3(0, 0, 0), text: "Note")
        XCTAssertThrowsError(try PresentationState(annotations: [annotation, annotation]).validate())
    }
    func testLengthFormattingKeepsScaleAcrossUnitChoices() {
        XCTAssertEqual(PresentationState(units: "millimeters").formattedLength(0.0254), "25.40 mm")
        XCTAssertEqual(PresentationState(units: "inches").formattedLength(0.0254), "1.00 in")
        XCTAssertEqual(PresentationState(units: "meters").formattedLength(5), "5.00 m")
    }
    func testExtremeCoordinatesCannotOverflowOverlayGeometry() {
        XCTAssertThrowsError(try PresentationState(guides: [GuideLine(start: Vec3(-1e308, 0, 0), end: Vec3(1e308, 0, 0))]).validate())
    }

    func testSavedSceneOldJSONDefaultsLayerSnapshotAndNewSnapshotRoundTrips() throws {
        let oldScene = SavedScene(name: "Legacy", camera: CameraState())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(oldScene)) as? [String: Any])
        json.removeValue(forKey: "visibleLayerIDs")
        let legacy = try JSONDecoder().decode(SavedScene.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.visibleLayerIDs)
        let layers = [UUID(), UUID()]
        let scene = SavedScene(name: "Layers", camera: CameraState(), visibleLayerIDs: layers)
        let restored = try JSONDecoder().decode(SavedScene.self, from: JSONEncoder().encode(scene))
        XCTAssertEqual(restored.visibleLayerIDs, layers)
        let noneVisible = SavedScene(name: "Empty layer snapshot", camera: CameraState(), visibleLayerIDs: [])
        XCTAssertEqual(try JSONDecoder().decode(SavedScene.self, from: JSONEncoder().encode(noneVisible)).visibleLayerIDs, [])
    }

    func testSmallDimensionsKeepTheirMagnitudeAndSign() throws {
        for (units, meters, expected) in [
            ("meters", 0.001, 0.001), ("meters", -0.0000123, -0.0000123),
            ("millimeters", 0.000001, 0.001), ("centimeters", 0.00001, 0.001),
            ("feet", 0.0003048, 0.001), ("inches", -0.0000254, -0.001),
            ("meters", 1e-20, 1e-20)
        ] {
            let text = PresentationState(units: units).formattedLength(meters)
            let value = try XCTUnwrap(Double(text.split(separator: " ")[0]))
            XCTAssertEqual(value, expected, accuracy: abs(expected) * 0.001, text)
        }
    }

}
