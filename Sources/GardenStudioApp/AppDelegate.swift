import AppKit
import SceneKit
import GardenStudioCore
import GardenStudioIO
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var window: NSWindow!
    let viewport = ModelViewport(frame: .zero)
    var documentRevision = UUID()
    private var approvedCloseRevision: UUID?
    var document = ModelDocument.demo { didSet { documentRevision = UUID() } }
    var history = ModelHistory()
    var currentURL: URL?
    var dirty = false
    var selected: UUID?
    var selection = Set<UUID>()
    var syncingSelection = false
    var suppressLinkedSync = false
    var auxiliaryPanels: [NSWindow] = []
    var layerToggleIDs: [ObjectIdentifier: UUID] = [:]
    var materialsPanel: MaterialsPanelController?
    let snapLabel = NSTextField(labelWithString: "")
    var toolButtons: [ModelingTool: NSButton] = [:]
    let status = NSTextField(labelWithString: "Select an object, or choose a drawing tool to begin.")
    let measurements = NSTextField(string: "")
    let table = GeometryOutlinerTableView()
    let selectionLabel = NSTextField(labelWithString: "Nothing selected")
    let dimensionsLabel = NSTextField(wrappingLabelWithString: "Click an object to inspect its dimensions.")
    let countLabel = NSTextField(labelWithString: "")
    var eventMonitor: Any?
    var exportPanel: NSSavePanel?
    var exportFormatID = "dae"
    var exportModes: [ExchangeDescriptor] = []
    var exportPicker: NSPopUpButton?
    var exportScopePicker: NSPopUpButton?
    var exportUnitPicker: NSPopUpButton?
    var exportAxisPicker: NSPopUpButton?
    var exportMaterialsCheckbox: NSButton?
    var exportQualityField: NSTextField?
    var exchangeBusy = false
    var nativeExchangeReady = false
    var exportDescription: NSTextField?
    let ink = NSColor(calibratedRed: 0.17, green: 0.22, blue: 0.23, alpha: 1)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMenus()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 1040, height: 680)
        window.title = "Garden Studio"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(calibratedWhite: 0.965, alpha: 1)
        window.delegate = self
        window.center()
        window.acceptsMouseMovedEvents = true
        window.appearance = NSAppearance(named: .aqua)
        buildUI()
        viewport.onDocumentChange = { [weak self] next in self?.commit(next) }
        viewport.onSelectionSetChange = { [weak self] ids in self?.setSelection(ids) }
        viewport.onMeasure = { [weak self] start, end, dimension in self?.addMeasurement(start: start, end: end, dimension: dimension) }
        viewport.onTextPoint = { [weak self] point in self?.addText(at: point, threeD: false) }
        viewport.onSectionPoint = { [weak self] point, normal in self?.setSection(point: point, normal: normal) }
        viewport.onAxesPoint = { [weak self] point in self?.status.stringValue = "Drawing axes moved to \(point.x), \(point.y), \(point.z)" }
        viewport.onDrawingAxesChange = { [weak self] axes in self?.updatePresentation{$0.drawingAxes=axes} }
        viewport.onStatus = { [weak self] text in self?.status.stringValue = text }
        viewport.document = document
        refresh()
        setTool(.select)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window.isKeyWindow, !(self.window.firstResponder is NSTextView), !(self.window.firstResponder is NSTextField) else { return event }
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty, let key = event.charactersIgnoringModifiers?.lowercased() {
                let shortcuts: [String: ModelingTool] = [" ": .select, "l": .line, "r": .rectangle, "c": .circle, "p": .pushPull, "m": .move, "b": .paint, "e": .erase, "o": .orbit, "h": .pan, "q": .rotate, "s": .scale, "f": .offset, "a": .arc, "g": .polygon, "t": .tapeMeasure]
                if let tool = shortcuts[key] { self.setTool(tool); return nil }
            }
            return event
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(viewport)
        // Deterministic launch capture for repeatable native visual verification.
        if let path = ProcessInfo.processInfo.environment["SKETCHMAKE_SCREENSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, let content = self.window.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
                content.cacheDisplay(in: content.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    func setupMenus() {
        let bar = NSMenu()
        func menu(_ title: String, _ entries: [(String, Selector?, String)]) {
            let root = NSMenuItem(); bar.addItem(root)
            let sub = NSMenu(title: title); root.submenu = sub
            for (name, action, key) in entries {
                if name == "-" { sub.addItem(.separator()); continue }
                let item = NSMenuItem(title: name, action: action, keyEquivalent: key); item.target = self; sub.addItem(item)
            }
        }
        menu("Garden Studio", [("About Garden Studio", #selector(about), ""), ("-", nil, ""), ("Quit Garden Studio", #selector(quit), "q")])
        menu("File", [("New Model", #selector(newModel), "n"), ("Open…", #selector(openModel), "o"), ("Save", #selector(saveModel), "s"), ("Save As…", #selector(saveAs), "S"), ("-", nil, ""), ("Import Geometry / Reference…", #selector(importGeometry), "i"), ("Export…", #selector(exportGeometry), "e"), ("Export OBJ…", #selector(exportOBJ), ""), ("Import/Export Compatibility…", #selector(exchangeCompatibility), ""), ("Open Garden Studio", #selector(loadDemo), "")])
        menu("Edit", [("Undo", #selector(undoAction), "z"), ("Redo", #selector(redoAction), "Z"), ("Delete", #selector(deleteSelection), "\u{8}"), ("Duplicate", #selector(duplicateSelection), "d")])
        if let edit = bar.items.last?.submenu {
            edit.addItem(.separator())
            for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
                edit.addItem(NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: key))
            }
        }
        menu("Camera", [("Isometric", #selector(isoView), "1"), ("Top", #selector(topView), "2"), ("Front", #selector(frontView), "3"), ("Right", #selector(rightView), "4"), ("Zoom Extents", #selector(zoomExtents), "0")])
        installWorkspaceMenus(on: bar)
        menu("Help", [("Modeling Controls", #selector(help), "?")])
        NSApp.mainMenu = bar
    }

    func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(labelWithString: text); field.font = .systemFont(ofSize: size, weight: weight); field.textColor = ink; return field
    }
    func button(_ title: String, _ action: Selector, symbol: String? = nil) -> NSButton {
        let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .texturedRounded
        if let symbol { b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title); b.imagePosition = .imageLeading }
        return b
    }
    func stack(_ views: [NSView], vertical: Bool = false, spacing: CGFloat = 8) -> NSStackView {
        let s = NSStackView(views: views); s.orientation = vertical ? .vertical : .horizontal; s.spacing = spacing; s.alignment = vertical ? .leading : .centerY; return s
    }
    func separator() -> NSView { let v = NSBox(); v.boxType = .separator; return v }
    func buildUI() {
        guard let content = window.contentView else { return }
        let brand = label("▰  SKETCH MAKE", size: 17, weight: .bold)
        let subtitle = label("A space for your next idea", size: 11); subtitle.textColor = .secondaryLabelColor
        let brandStack = stack([brand, subtitle], vertical: true, spacing: 3)
        let spacer = NSView()
        let top = stack([brandStack, spacer, button("New", #selector(newModel), symbol: "doc.badge.plus"), button("Open", #selector(openModel), symbol: "folder"), button("Save", #selector(saveModel), symbol: "square.and.arrow.down"), button("Import", #selector(importGeometry), symbol: "square.and.arrow.down.on.square"), button("Export", #selector(exportGeometry), symbol: "square.and.arrow.up")], spacing: 12)
        top.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 18)
        top.heightAnchor.constraint(equalToConstant: 70).isActive = true
        let toolbar = stack([label("CAMERA", size: 10, weight: .semibold), button("Iso", #selector(isoView), symbol: "cube"), button("Top", #selector(topView)), button("Front", #selector(frontView)), button("Right", #selector(rightView)), button("Fit", #selector(zoomExtents), symbol: "arrow.up.left.and.arrow.down.right"), NSView(), snapLabel, button("Settings", #selector(modelSettings), symbol: "slider.horizontal.3")], spacing: 9)
        toolbar.edgeInsets = NSEdgeInsets(top: 7, left: 16, bottom: 7, right: 18)
        toolbar.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let tools = ModelingTool.allCases
        let rail = ToolRail(); rail.orientation = .vertical; rail.spacing = 5; rail.edgeInsets = NSEdgeInsets(top: 12, left: 9, bottom: 12, right: 9)
        for (index, tool) in tools.enumerated() {
            let b = NSButton(image: NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: tool.displayName) ?? NSImage(), target: self, action: #selector(toolClicked(_:)))
            b.tag = index; b.bezelStyle = .regularSquare; b.isBordered = false; b.toolTip = tool.displayName; b.imageScaling = .scaleProportionallyDown
            b.widthAnchor.constraint(equalToConstant: 38).isActive = true; b.heightAnchor.constraint(equalToConstant: 34).isActive = true
            rail.addArrangedSubview(b); toolButtons[tool] = b
        }
        rail.frame = NSRect(x: 0, y: 0, width: 56, height: tools.count * 39 + 24)
        let railScroll = NSScrollView(); railScroll.documentView = rail; railScroll.hasVerticalScroller = true; railScroll.scrollerStyle = .overlay; railScroll.drawsBackground = false
        railScroll.widthAnchor.constraint(equalToConstant: 56).isActive = true
        viewport.translatesAutoresizingMaskIntoConstraints = false
        let viewportHost = NSView(); viewportHost.addSubview(viewport)
        NSLayoutConstraint.activate([viewport.leadingAnchor.constraint(equalTo: viewportHost.leadingAnchor), viewport.trailingAnchor.constraint(equalTo: viewportHost.trailingAnchor), viewport.topAnchor.constraint(equalTo: viewportHost.topAnchor), viewport.bottomAnchor.constraint(equalTo: viewportHost.bottomAnchor)])
        let inspector = buildInspector(); inspector.widthAnchor.constraint(equalToConstant: 250).isActive = true
        let body = stack([railScroll, viewportHost, inspector], spacing: 0); body.alignment = .top
        for view in [railScroll, viewportHost, inspector] { view.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true }
        status.lineBreakMode = .byTruncatingTail; status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        measurements.placeholderString = "e.g. 3, 4 or 250cm"; measurements.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        measurements.target = self; measurements.action = #selector(applyMeasurement); measurements.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let bottom = stack([status, NSView(), label("Measurements", size: 11, weight: .medium), measurements], spacing: 10)
        bottom.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 14); bottom.heightAnchor.constraint(equalToConstant: 42).isActive = true
        let root = stack([top, separator(), toolbar, separator(), body, separator(), bottom], vertical: true, spacing: 0)
        root.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor), root.trailingAnchor.constraint(equalTo: content.trailingAnchor), root.topAnchor.constraint(equalTo: content.topAnchor), root.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        for view in [top, toolbar, body, bottom] { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
    }
    func buildInspector() -> NSView {
        let title = label("MODEL", size: 10, weight: .bold)
        let name = label("Garden Studio", size: 21, weight: .medium); name.lineBreakMode = .byTruncatingTail; name.widthAnchor.constraint(equalToConstant: 214).isActive = true; name.identifier = NSUserInterfaceItemIdentifier("documentName")
        countLabel.font = .systemFont(ofSize: 11); countLabel.textColor = .secondaryLabelColor
        selectionLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        dimensionsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); dimensionsLabel.textColor = .secondaryLabelColor
        let swatches = stack([], spacing: 7)
        for (index, hex) in ["#E7DCC8", "#A27650", "#7FABB5", "#6F8F6C", "#D3CEC2", "#535B60"].enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(pickMaterial(_:))); b.tag = index; b.bezelStyle = .regularSquare; b.wantsLayer = true
            let value = UInt32(hex.dropFirst(), radix: 16)!
            b.layer?.backgroundColor = NSColor(calibratedRed: CGFloat(value >> 16 & 255)/255, green: CGFloat(value >> 8 & 255)/255, blue: CGFloat(value & 255)/255, alpha: 1).cgColor
            b.layer?.cornerRadius = 4; b.isBordered = false; b.widthAnchor.constraint(equalToConstant: 28).isActive = true; b.heightAnchor.constraint(equalToConstant: 28).isActive = true; b.toolTip = hex; swatches.addArrangedSubview(b)
        }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("objects")); column.title = "Objects"; column.width = 210; table.addTableColumn(column)
        table.geometryResponder = viewport; table.allowsMultipleSelection = true; table.headerView = nil; table.rowHeight = 29; table.style = .plain; table.backgroundColor = .clear; table.delegate = self; table.dataSource = self
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        let hint = label("DRAW → EXTRUDE → MAKE", size: 10, weight: .bold)
        let tips = NSTextField(wrappingLabelWithString: "R  Draw a rectangle\nP  Pull it into a solid\nB  Give it a material\n\nRight-drag to orbit.\nShift + right-drag to pan.\nScroll to zoom.")
        tips.font = .systemFont(ofSize: 11); tips.textColor = .secondaryLabelColor
        let root = stack([title, name, countLabel, separator(), label("ENTITY INFO", size: 10, weight: .bold), selectionLabel, dimensionsLabel, separator(), label("MATERIALS", size: 10, weight: .bold), swatches, button("Materials & Textures…", #selector(showMaterials), symbol: "paintpalette"), separator(), label("OUTLINER", size: 10, weight: .bold), stack([button("Group", #selector(groupSelection)), button("Layers…", #selector(layersPanel)), button("Scenes…", #selector(scenesPanel))], spacing: 5), scroll, separator(), hint, tips], vertical: true, spacing: 13)
        root.edgeInsets = NSEdgeInsets(top: 21, left: 18, bottom: 20, right: 18)
        for v in [dimensionsLabel, scroll, tips] { v.widthAnchor.constraint(equalToConstant: 214).isActive = true }
        root.wantsLayer = true; root.layer?.backgroundColor = NSColor(calibratedWhite: 0.97, alpha: 1).cgColor
        return root
    }
    func commit(_ proposed: ModelDocument, camera requestedCamera: CameraState? = nil) {
        viewport.cancelEditingDrag()
        let liveCamera = viewport.captureCamera()
        var next = proposed
        do { try synchronizeLinkedEdits(in: &next) }
        catch { viewport.document = document; showError(error); return }
        guard next != document || (requestedCamera != nil && requestedCamera != liveCamera) else { return }

        // Record the view that was actually onscreen, including unsaved navigation.
        var previous = document
        var beforeView = previous.presentation ?? PresentationState()
        beforeView.camera = liveCamera
        beforeView.orthographic = liveCamera.orthographic
        previous.presentation = beforeView

        var nextView = next.presentation ?? beforeView
        let projectionChanged = (next.presentation?.orthographic ?? liveCamera.orthographic)
            != (document.presentation?.orthographic ?? liveCamera.orthographic)
        nextView.camera = requestedCamera ?? liveCamera
        nextView.orthographic = requestedCamera?.orthographic
            ?? (projectionChanged ? nextView.orthographic : liveCamera.orthographic)
        nextView.camera.orthographic = nextView.orthographic
        next.presentation = nextView

        do { try next.validate() }
        catch { viewport.document = document; showError(error); return }
        history.record(previous, restoresCamera: requestedCamera != nil || projectionChanged)
        document = next
        dirty = true
        refresh()
        if let requestedCamera { viewport.applyCamera(requestedCamera) }
    }
    func refresh() {
        viewport.document = document
        viewport.snapStep = document.editor?.snapStep ?? 0.001
        viewport.setOrthographic(document.presentation?.orthographic ?? false)
        snapLabel.stringValue = "\((document.editor?.units ?? "m").uppercased()) · \(String(format: "%.3g", viewport.snapStep)) m SNAP"
        selection.formIntersection(Set(document.entities.map(\.id)))
        selected = viewport.selectedID.flatMap { selection.contains($0) ? $0 : nil } ?? selection.sorted { $0.uuidString < $1.uuidString }.first
        viewport.selectedIDs = selection
        window.title = "\(document.name)\(dirty ? " •" : "") — Garden Studio"
        window.isDocumentEdited = dirty
        countLabel.stringValue = "\(document.entities.count) objects · \(document.editor?.units ?? "m")"
        func updateName(_ view: NSView) { if view.identifier?.rawValue == "documentName", let text = view as? NSTextField { text.stringValue = document.name }; view.subviews.forEach(updateName) }
        if let root = window.contentView { updateName(root) }
        table.reloadData(); syncingSelection = true; table.selectRowIndexes(IndexSet(document.entities.indices.filter { selection.contains(document.entities[$0].id) }), byExtendingSelection: false); syncingSelection = false; updateSelectionInfo()
    }
    func select(_ id: UUID?) { setSelection(id.map { Set([$0]) } ?? []) }
    func setSelection(_ ids: Set<UUID>) {
        guard !syncingSelection else { return }; syncingSelection = true; defer { syncingSelection = false }
        selection = document.effectiveSelection(ids, editingGroupID: viewport.editingGroupID).intersection(Set(document.entities.map(\.id)))
        selected = viewport.selectedID.flatMap { selection.contains($0) ? $0 : nil } ?? selection.sorted { $0.uuidString < $1.uuidString }.first
        viewport.selectedIDs = selection
        let rows = IndexSet(document.entities.indices.filter { selection.contains(document.entities[$0].id) })
        table.selectRowIndexes(rows, byExtendingSelection: false)
        updateSelectionInfo()
    }
    func updateSelectionInfo() {
        if selection.count > 1 {
            selectionLabel.stringValue = "\(selection.count) objects selected"
            dimensionsLabel.stringValue = "Shift-click or drag to select.\nModify / Organize menus edit selection."
        } else if let entity = document.entities.first(where: { $0.id == selected }) {
            selectionLabel.stringValue = entity.name
            let units = ["m":"meters","mm":"millimeters","cm":"centimeters","ft":"feet","in":"inches"][document.editor?.units ?? "m"] ?? "meters"
            let formatter = PresentationState(units: units)
            dimensionsLabel.stringValue = "W  \(formatter.formattedLength(entity.width))\nD  \(formatter.formattedLength(entity.depth))\nH  \(formatter.formattedLength(entity.height))"
        } else { selectionLabel.stringValue = "Nothing selected"; dimensionsLabel.stringValue = "Click an object to inspect its dimensions." }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { document.entities.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entity = document.entities[row]
        let group = document.editor?.groups.first(where: { $0.id == entity.metadata?.groupID })
        let prefix = entity.metadata?.isLocked == true ? "🔒 " : (entity.isVisible(in: document) ? "" : "◌ ")
        let text = label(prefix + (group.map { "\($0.name) / " } ?? "") + entity.name, size: 11)
        text.textColor = entity.isVisible(in: document) ? ink : .secondaryLabelColor; return text
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection else { return }
        setSelection(Set(table.selectedRowIndexes.filter { document.entities.indices.contains($0) }.map { document.entities[$0].id }))
    }
    @objc func toolClicked(_ sender: NSButton) { setTool(ModelingTool.allCases[sender.tag]) }
    func setTool(_ tool: ModelingTool) { viewport.tool = tool; for (key, b) in toolButtons { b.contentTintColor = key == tool ? .systemOrange : ink; b.state = key == tool ? .on : .off }; window?.makeFirstResponder(viewport) }
    @objc func pickMaterial(_ sender: NSButton) { let colors = ["#E7DCC8", "#A27650", "#7FABB5", "#6F8F6C", "#D3CEC2", "#535B60"]; viewport.paintColor = colors[sender.tag]; setTool(.paint) }
    @objc func applyMeasurement() { viewport.applyMeasurement(measurements.stringValue); measurements.stringValue = ""; window.makeFirstResponder(viewport) }
    func changeCamera(to camera: CameraState) {
        var next = document
        var presentation = next.presentation ?? PresentationState()
        presentation.camera = camera
        presentation.orthographic = camera.orthographic
        next.presentation = presentation
        commit(next, camera: camera)
    }

    func restoreScene(_ scene: SavedScene) {
        var next = document
        if let visibleIDs = scene.visibleLayerIDs, var editor = next.editor {
            let visible=Set(visibleIDs)
            for index in editor.layers.indices { editor.layers[index].isVisible = visible.contains(editor.layers[index].id) }
            next.editor = editor
        }
        let hidden=Set(scene.hiddenIDs)
        for index in next.entities.indices {
            var metadata = next.entities[index].metadata ?? EntityMetadata()
            metadata.isHidden = hidden.contains(next.entities[index].id)
            next.entities[index].metadata = metadata
        }
        var presentation = next.presentation ?? PresentationState()
        presentation.camera = scene.camera
        presentation.orthographic = scene.camera.orthographic
        next.presentation = presentation
        commit(next, camera: scene.camera)
    }
    @objc func undoAction() {
        guard let change = history.undoChange(current: document) else { return }
        restoreHistory(change)
    }

    @objc func redoAction() {
        guard let change = history.redoChange(current: document) else { return }
        restoreHistory(change)
    }

    private func restoreHistory(_ change: ModelHistoryChange) {
        viewport.cancelEditingDrag()
        let liveCamera = viewport.captureCamera()
        document = change.document
        dirty = true
        refresh()
        viewport.applyCamera(change.restoresCamera ? (document.presentation?.camera ?? liveCamera) : liveCamera)
    }
    @objc func deleteSelection() { guard !selection.isEmpty else { return }; var next = document; next.entities.removeAll { selection.contains($0.id) && $0.isEditable(in: document) }; commit(next); setSelection([]) }
    @objc func duplicateSelection() { editSelection { try EditorOperations.duplicate(document: $0, ids: $1, count: 1, delta: Vec3(0.1,0,0.1), editingGroupID: viewport.editingGroupID) } }
    @objc func isoView() { viewport.setStandardView("iso") }
    @objc func topView() { viewport.setStandardView("top") }
    @objc func frontView() { viewport.setStandardView("front") }
    @objc func rightView() { viewport.setStandardView("right") }
    @objc func zoomExtents() { viewport.zoomExtents() }
    func mayDiscard() -> Bool {
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "Save changes to \(document.name)?"; alert.informativeText = "Your unsaved changes will be lost if you discard them."; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Discard")
        switch alert.runModal() { case .alertFirstButtonReturn: return performSave(forcePanel: false); case .alertThirdButtonReturn: return true; default: return false }
    }
    @objc func newModel() { guard mayDiscard() else { return }; reset(ModelDocument()) }
    @objc func loadDemo() { guard mayDiscard() else { return }; reset(.demo) }
    func reset(_ next: ModelDocument, url: URL? = nil) { viewport.cancelOperation(); viewport.editingGroupID = nil; layerToggleIDs.removeAll(); document = next; currentURL = url; history = ModelHistory(); selected = nil; selection = []; dirty = false; refresh(); if let camera = next.presentation?.camera { viewport.applyCamera(camera) } else { viewport.zoomExtents() } }
    @objc func openModel() {
        guard mayDiscard() else { return }; let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { reset(try Self.readProject(at: url), url: url) } catch { showError(error) }
    }
    static func readProject(at url: URL) throws -> ModelDocument {
        guard url.isFileURL else { throw GeometryIOError.invalid("Choose a local Garden Studio project.") }
        let resolved = url.resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 100_000_000 else {
            throw GeometryIOError.invalid("Choose a regular project file no larger than 100 MB.")
        }
        let reader = try FileHandle(forReadingFrom: resolved)
        defer { try? reader.close() }
        let data = try reader.read(upToCount: 100_000_001) ?? Data()
        guard data.count <= 100_000_000 else { throw GeometryIOError.invalid("The project exceeds the 100 MB limit.") }
        let document = try JSONDecoder().decode(ModelDocument.self, from: data)
        try document.validate()
        return document
    }
    @objc func saveModel() { _ = performSave(forcePanel: false) }
    @objc func saveAs() { _ = performSave(forcePanel: true) }
    func performSave(forcePanel: Bool) -> Bool {
        var url = currentURL
        if forcePanel || url == nil { let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "\(document.name).gardenstudio.json"; guard panel.runModal() == .OK else { return false }; url = panel.url }
        guard let url else { return false }
        do { try document.validate(); let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; var saved = document; var presentation = saved.presentation ?? PresentationState(); presentation.camera = viewport.captureCamera(); presentation.orthographic = presentation.camera.orthographic; saved.presentation = presentation; let data = try encoder.encode(saved); guard data.count <= 100_000_000 else { throw GeometryIOError.invalid("The project exceeds the 100 MB limit. Export a smaller selection or reduce embedded textures.") }; try data.write(to: url, options: .atomic); document = saved; currentURL = url; dirty = false; refresh(); status.stringValue = "Saved \(url.lastPathComponent)"; return true } catch { showError(error); return false }
    }
    func showError(_ error: Error) { let alert = NSAlert(error: error); alert.runModal() }
    @objc func about() { let a = NSAlert(); a.messageText = "Garden Studio"; a.informativeText = "An independent native macOS modeling app inspired by SketchUp Make 2017.\n\nBuilt with AppKit and SceneKit. Original implementation; not affiliated with Trimble.\n\nProjects: JSON · Meshes, vectors, archives and reference images"; a.runModal() }
    @objc func help() { let a = NSAlert(); a.messageText = "From a face to a space"; a.informativeText = "Space Select · L Line · R Rectangle · C Circle\nP Push/Pull · M Move · B Paint · E Erase\nO Orbit · H Pan\n\nClick two ground points to draw. Choose Push/Pull and drag a face vertically, or select it and enter a height below. Measurements accept m, cm, mm, ft and comma-separated dimensions.\n\nRight-drag orbits; Shift-right-drag pans. Scroll zooms. Delete removes selected geometry. ⌘D duplicates. ⌘Z undoes. ⌘1–4 change views; ⌘0 fits.\n\nModels contain primitives, profiles and imported meshes. File → Import/Export Compatibility lists available mesh, vector, archive and image modes. Export offers units/up-axis for unitless meshes and whole/visible/selected scope. Native SKP uses an installed SketchUp SDK. Import/export SKM paint in Materials & Textures; the Make bridge remains a fallback. CRV jobs, DWG and CNC toolpaths require their original applications."; a.runModal() }
    @objc func quit() { NSApp.terminate(nil) }
    func approveDocumentWindowClose(using decision:()->Bool)->Bool {
        approvedCloseRevision=nil
        guard decision() else{return false}
        approvedCloseRevision=documentRevision
        return true
    }
    func documentTerminationReply(using decision:()->Bool)->NSApplication.TerminateReply {
        if approvedCloseRevision==documentRevision {
            approvedCloseRevision=nil
            return .terminateNow
        }
        return decision() ? .terminateNow:.terminateCancel
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { approveDocumentWindowClose { mayDiscard() } }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { documentTerminationReply { mayDiscard() } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
public func runGardenStudioApplication() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
