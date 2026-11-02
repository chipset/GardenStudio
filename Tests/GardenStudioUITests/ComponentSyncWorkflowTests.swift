import AppKit
import XCTest
import GardenStudioCore
@testable import GardenStudioUI

final class ComponentSyncWorkflowTests: XCTestCase {
    private func controller(tool: ModelingTool) throws -> AppDelegate {
        _ = NSApplication.shared
        let source = GardenEntity(kind: .rectangle, origin: Vec3(0,0,0), width: 1, depth: 1, height: 1)
        var document = try EditorOperations.group(document: ModelDocument(entities: [source]), ids: [source.id], name: "Component", component: true)
        document = try EditorOperations.duplicate(document: document, ids: [source.id], count: 1, delta: Vec3(3,0,0))
        let controller = AppDelegate()
        controller.window = NSWindow(contentRect: NSRect(x:0,y:0,width:800,height:600), styleMask: [.borderless], backing: .buffered, defer: false)
        controller.document = document
        controller.viewport.document = document
        controller.viewport.tool = tool
        controller.setSelection([source.id])
        return controller
    }

    func testMaterialCommandsSynchronizeRegardlessOfActiveTransformTool() throws {
        for tool in [ModelingTool.select, .move, .rotate, .scale] {
            let controller = try controller(tool: tool)
            let peerOrigin = controller.document.entities[1].origin
            let material = SurfaceMaterial(colorHex: "#FF0000")
            try controller.applySurface(material, faceOnly: false)
            XCTAssertEqual(controller.document.entities[0].surface, material, tool.rawValue)
            XCTAssertEqual(controller.document.entities[1].surface, material, tool.rawValue)
            XCTAssertEqual(controller.document.entities[1].colorHex, "#FF0000", tool.rawValue)
            XCTAssertEqual(controller.document.entities[1].origin, peerOrigin, tool.rawValue)
        }
    }

    func testReverseFacesSynchronizesRegardlessOfActiveTransformTool() throws {
        for tool in [ModelingTool.select, .move, .rotate, .scale] {
            let controller = try controller(tool: tool)
            let peerOrigin = controller.document.entities[1].origin
            let original = try controller.document.entities[1].triangulatedMesh()
            controller.reverseSelection()
            let source = try controller.document.entities[0].triangulatedMesh()
            let peer = try controller.document.entities[1].triangulatedMesh()
            XCTAssertNotEqual(peer.triangles, original.triangles, tool.rawValue)
            XCTAssertEqual(peer.triangles, source.triangles, tool.rawValue)
            XCTAssertEqual(controller.document.entities[1].origin, peerOrigin, tool.rawValue)
        }
    }

    func testWholeInstanceTranslationAndRotationRemainIndependent() throws {
        for tool in [ModelingTool.select, .move, .rotate] {
            let controller = try controller(tool: tool)
            let peer = controller.document.entities[1]
            let translated = try EditorOperations.translate(document: controller.document, ids: controller.selection, delta: Vec3(1,2,3))
            controller.commit(translated)
            XCTAssertEqual(controller.document.entities[1], peer, tool.rawValue)
            let rotated = try EditorOperations.rotate(document: controller.document, ids: controller.selection, radians: .pi/2)
            controller.commit(rotated)
            XCTAssertEqual(controller.document.entities[1], peer, tool.rawValue)
        }
    }

    func testExplicitWholeInstanceTransformTransactionPreservesPeer() throws {
        let controller = try controller(tool: .select)
        let peer = controller.document.entities[1]
        controller.editSelection { try EditorOperations.translate(document: $0, ids: $1, delta: Vec3(1,2,3)) }
        controller.editSelection { try EditorOperations.rotate(document: $0, ids: $1, radians: .pi/2) }
        XCTAssertEqual(controller.document.entities[1], peer)
    }

    func testWholeInstanceBakedScaleRemainsUniqueForSubsequentMaterialEdits() throws {
        let controller = try controller(tool: .scale)
        let peer = controller.document.entities[1]
        let scaled = try EditorOperations.scale(document: controller.document, ids: controller.selection, factors: Vec3(2,3,4))
        controller.commit(scaled)
        XCTAssertEqual(controller.document.entities[1], peer)
        let groups = try XCTUnwrap(controller.document.editor).groups
        XCTAssertNotEqual(groups[0].componentID, groups[1].componentID)
        try controller.applySurface(SurfaceMaterial(colorHex: "#FF0000"), faceOnly: false)
        XCTAssertEqual(controller.document.entities[1], peer)
        XCTAssertEqual(controller.document.entities[0].colorHex, "#FF0000")
    }
}
