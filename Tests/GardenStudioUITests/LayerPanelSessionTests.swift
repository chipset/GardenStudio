import AppKit
import XCTest
import GardenStudioCore
@testable import GardenStudioUI

final class LayerPanelSessionTests: XCTestCase {
    func testOldLayerCheckboxCannotChangeNewlyOpenedModel() throws {
        _ = NSApplication.shared
        let app = AppDelegate()
        app.window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        let first = ModelLayer(name: "First")
        app.document = ModelDocument(editor: EditorState(layers: [first]))
        app.viewport.document = app.document
        app.layersPanel()
        let oldPanel = try XCTUnwrap(app.auxiliaryPanels.last)
        defer { oldPanel.close() }
        let checkbox = try XCTUnwrap(oldPanel.contentView?.subviews.flatMap { $0.subviews }.compactMap { $0 as? NSButton }.first { $0.title == first.name })

        let second = ModelLayer(name: "Second")
        app.reset(ModelDocument(editor: EditorState(layers: [second])))
        checkbox.state = .off
        app.layerVisibilityChanged(checkbox)

        XCTAssertTrue(try XCTUnwrap(app.document.editor?.layers.first).isVisible)
        XCTAssertFalse(app.dirty)
    }

    func testLayerCheckboxTracksLayerIdentityAfterReordering() throws {
        _ = NSApplication.shared
        let app = AppDelegate()
        app.window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        let first = ModelLayer(name: "First"), second = ModelLayer(name: "Second")
        app.document = ModelDocument(editor: EditorState(layers: [first, second]))
        app.viewport.document = app.document
        app.layersPanel()
        let panel = try XCTUnwrap(app.auxiliaryPanels.last)
        defer { panel.close() }
        let checkbox = try XCTUnwrap(panel.contentView?.subviews.flatMap { $0.subviews }.compactMap { $0 as? NSButton }.first { $0.title == first.name })

        app.document.editor?.layers.reverse()
        checkbox.state = .off
        app.layerVisibilityChanged(checkbox)

        XCTAssertFalse(try XCTUnwrap(app.document.editor?.layers.first { $0.id == first.id }).isVisible)
        XCTAssertTrue(try XCTUnwrap(app.document.editor?.layers.first { $0.id == second.id }).isVisible)
    }

    func testOldLayerCheckboxCannotChangeReopenedCopyWithSameLayerID() throws {
        _ = NSApplication.shared
        let app = AppDelegate()
        app.window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        let layer = ModelLayer(name: "Shared ID")
        let document = ModelDocument(editor: EditorState(layers: [layer]))
        app.document = document
        app.viewport.document = document
        app.layersPanel()
        let panel = try XCTUnwrap(app.auxiliaryPanels.last)
        defer { panel.close() }
        let checkbox = try XCTUnwrap(panel.contentView?.subviews.flatMap { $0.subviews }.compactMap { $0 as? NSButton }.first { $0.title == layer.name })

        app.reset(document)
        checkbox.state = .off
        app.layerVisibilityChanged(checkbox)

        XCTAssertTrue(try XCTUnwrap(app.document.editor?.layers.first).isVisible)
        XCTAssertFalse(app.dirty)
    }
}
