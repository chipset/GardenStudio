import XCTest
import AppKit
import SceneKit
import GardenStudioCore
@testable import GardenStudioUI

final class PushPullCutTests: XCTestCase {
    private func fixture() -> (ModelViewport, GardenEntity, GardenEntity) {
        let host = GardenEntity(name: "Block", kind: .rectangle, origin: Vec3(0,0,0), width: 4, depth: 4, height: 3)
        let profile = GardenEntity(name: "Opening", kind: .rectangle, origin: Vec3(0,3,0), width: 1, depth: 1)
        let view = ModelViewport(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.document = ModelDocument(entities: [host, profile])
        view.tool = .pushPull
        view.selectedID = profile.id
        return (view, host, profile)
    }

    private func volume(_ entity: GardenEntity) throws -> Double {
        let mesh = try entity.triangulatedMesh()
        var result = 0.0
        for i in stride(from: 0, to: mesh.triangles.count, by: 3) {
            let a = mesh.vertices[mesh.triangles[i]], b = mesh.vertices[mesh.triangles[i+1]], c = mesh.vertices[mesh.triangles[i+2]]
            result += (a.x*(b.y*c.z-b.z*c.y) + a.y*(b.z*c.x-b.x*c.z) + a.z*(b.x*c.y-b.y*c.x))/6
        }
        return abs(result)
    }

    private func mouse(_ type: NSEvent.EventType, point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    func testNumericInwardPushCutsThroughAndCommitsOneUndoableChange() throws {
        let (view, host, _) = fixture(), before = view.document
        var commits = 0, history = ModelHistory(), previous = before
        view.onDocumentChange = { next in history.record(previous); previous = next; commits += 1 }
        view.applyMeasurement("-3")
        XCTAssertEqual(view.document.entities.count, 1)
        let result = try XCTUnwrap(view.document.entities.first(where: { $0.id == host.id }))
        XCTAssertEqual(try volume(result), 45, accuracy: 1e-7)
        XCTAssertEqual(view.selectedID, host.id)
        XCTAssertEqual(commits, 1)
        let after = view.document
        view.cancelOperation()
        XCTAssertEqual(view.document, after, "Escape after a committed cut must not restore the removed profile")
        XCTAssertEqual(history.undo(current: after), before)
        XCTAssertEqual(history.redo(current: before), after)
    }

    func testNumericInwardPushMakesPocketAtRequestedDepth() throws {
        let (view, host, _) = fixture()
        view.applyMeasurement("-1")
        XCTAssertEqual(view.document.entities.count, 1)
        let result = try XCTUnwrap(view.document.entities.first(where: { $0.id == host.id }))
        XCTAssertEqual(try volume(result), 47, accuracy: 1e-7)
        XCTAssertEqual(view.selectedID, host.id)
        let mesh = try result.triangulatedMesh()
        XCTAssertTrue(mesh.vertices.contains(where: { abs($0.y-2) < 1e-7 && abs($0.x) <= 0.5 && abs($0.z) <= 0.5 }))
    }

    func testStandaloneNegativePushStillExtrudesTheProfile() throws {
        let (view, _, profile) = fixture()
        view.document = ModelDocument(entities: [profile])
        view.applyMeasurement("-1")
        XCTAssertEqual(view.document.entities.map(\.id), [profile.id])
        XCTAssertEqual(try volume(XCTUnwrap(view.document.entities.first)), 1, accuracy: 1e-7)
        XCTAssertEqual(view.selectedID, profile.id)
    }

    func testRetypedPocketDepthUsesTheOriginalProfile() throws {
        let (view, host, _) = fixture()
        view.applyMeasurement("-1")
        view.applyMeasurement("-3")
        XCTAssertEqual(view.document.entities.map(\.id), [host.id])
        XCTAssertEqual(try volume(XCTUnwrap(view.document.entities.first)), 45, accuracy: 1e-7)
    }

    func testInterveningGeometryEditInvalidatesRetypedDepth() throws {
        let (view, host, _) = fixture()
        view.applyMeasurement("-1")
        var edited = view.document
        edited.entities[0].origin.x += 5
        view.document = edited
        view.applyMeasurement("-3")
        XCTAssertEqual(view.document, edited, "Retyping cannot restore an obsolete pre-cut document after another edit")
        XCTAssertEqual(view.selectedID, host.id)
    }

    func testInwardPushIntoLockedHostIsAtomic() throws {
        let (view, host, profile) = fixture()
        var locked = host
        locked.metadata = EntityMetadata(isLocked: true)
        let before = ModelDocument(entities: [locked, profile])
        view.document = before
        var commits = 0
        view.onDocumentChange = { _ in commits += 1 }
        view.applyMeasurement("-1")
        XCTAssertEqual(view.document, before)
        XCTAssertEqual(commits, 0)
    }

    func testProfilePushPullDragCanBeCancelledWithoutCommitting() throws {
        let (view, _, profile) = fixture(), before = view.document
        let projected = view.projectPoint(SCNVector3(0,3,0))
        let point = NSPoint(x: projected.x, y: projected.y)
        var commits = 0
        var status = ""
        view.onStatus = { status = $0 }
        view.onDocumentChange = { _ in commits += 1 }
        XCTAssertTrue(view.beginProfilePushPull(profileID: profile.id, at: point))
        XCTAssertEqual(view.selectedID, profile.id)
        view.mouseDragged(with: try mouse(.leftMouseDragged, point: NSPoint(x: point.x, y: point.y-100)))
        XCTAssertEqual(view.document.entities.count, 1, status)
        XCTAssertEqual(commits, 0, "Drag preview must not add undo entries")
        view.cancelOperation()
        XCTAssertEqual(view.document, before)
        XCTAssertEqual(commits, 0)
    }

    func testTypedDepthAfterShallowDragReplacesPocketWithThroughHole() throws {
        let (view, host, profile) = fixture()
        let projected = view.projectPoint(SCNVector3(0,3,0))
        let point = NSPoint(x: projected.x, y: projected.y)
        let dragged = NSPoint(x: point.x, y: point.y-30)
        var commits = 0
        var status = ""
        view.onStatus = { status = $0 }
        view.onDocumentChange = { _ in commits += 1 }
        XCTAssertTrue(view.beginProfilePushPull(profileID: profile.id, at: point))
        view.mouseDragged(with: try mouse(.leftMouseDragged, point: dragged))
        view.mouseUp(with: try mouse(.leftMouseUp, point: dragged))
        XCTAssertEqual(view.selectedID, host.id, status)
        XCTAssertEqual(commits, 1, status)
        view.applyMeasurement("-3")
        XCTAssertEqual(view.document.entities.map(\.id), [host.id])
        XCTAssertEqual(try volume(XCTUnwrap(view.document.entities.first)), 45, accuracy: 1e-7)
        XCTAssertEqual(commits, 2)
    }

    func testTypingExactDepthDuringDragCommitsThatCutOnce() throws {
        let (view, host, profile) = fixture()
        let projected = view.projectPoint(SCNVector3(0,3,0))
        let start = NSPoint(x: projected.x, y: projected.y)
        let dragged = NSPoint(x: start.x, y: start.y-30)
        var commits = 0
        view.onDocumentChange = { _ in commits += 1 }
        XCTAssertTrue(view.beginProfilePushPull(profileID: profile.id, at: start))
        view.mouseDragged(with: try mouse(.leftMouseDragged, point: dragged))
        XCTAssertEqual(view.document.entities.count, 1)
        view.applyMeasurement("-3")
        XCTAssertEqual(view.document.entities.map(\.id), [host.id])
        XCTAssertEqual(try volume(XCTUnwrap(view.document.entities.first)), 45, accuracy: 1e-7)
        XCTAssertEqual(view.selectedID, host.id)
        XCTAssertEqual(commits, 1)
        view.mouseUp(with: try mouse(.leftMouseUp, point: dragged))
        XCTAssertEqual(commits, 1, "Mouse release must not commit the old drag preview")
    }

    func testVerticalRectangleNormalMatchesDrawingPlaneInEveryQuadrant() throws {
        for plane in ["front", "right"] {
            for width in [-1, 1] {
                for height in [-1, 1] {
                    let view = ModelViewport(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
                    view.tool = .rectangle
                    view.setDrawingPlane(plane)
                    view.beginDrawing(at: Vec3(0,0,0))
                    view.applyMeasurement("\(width), \(height)")
                    let entity = try XCTUnwrap(view.document.entities.last)
                    let normal = try GeometryTools.normal(of: entity)
                    XCTAssertEqual(plane == "front" ? normal.z : normal.x, 1, accuracy: 1e-7, "\(plane), \(width), \(height)")
                }
            }
        }
    }

    func testUndersideDrawingKeepsOutwardNormalForNegativeInwardPush() throws {
        for tool in [ModelingTool.rectangle, .circle] {
            let view = ModelViewport(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            view.tool = tool
            view.setDrawingAxes(try DrawingAxes(origin: Vec3(0,0,0), xAxis: Vec3(1,0,0), normal: Vec3(0,-1,0)))
            view.beginDrawing(at: Vec3(0,0,0))
            view.applyMeasurement(tool == .circle ? "1" : "1, 1")
            let entity = try XCTUnwrap(view.document.entities.last)
            XCTAssertEqual(try GeometryTools.normal(of: entity).y, -1, accuracy: 1e-7)
        }
    }
}
