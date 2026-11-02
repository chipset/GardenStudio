import AppKit

/// Outliner selection edits the same geometry as the canvas without stealing
/// standard text-editing actions from the measurement field or native dialogs.
final class GeometryOutlinerTableView: NSTableView {
    weak var geometryResponder: ModelViewport?

    @objc func copy(_ sender: Any?) { geometryResponder?.copy(sender) }
    @objc func cut(_ sender: Any?) { geometryResponder?.cut(sender) }
    @objc func paste(_ sender: Any?) { geometryResponder?.paste(sender) }
    override func selectAll(_ sender: Any?) {
        guard let geometryResponder else { super.selectAll(sender); return }
        geometryResponder.selectAll(sender)
    }
}
