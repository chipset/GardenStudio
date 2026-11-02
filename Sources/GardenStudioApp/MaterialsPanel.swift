import AppKit
import SceneKit
import GardenStudioCore
import GardenStudioIO
import UniformTypeIdentifiers

/// Shared native renderer material construction. UV inputs are measured in local meters.
enum MaterialManager {
    static func makeMaterial(surface: SurfaceMaterial?, fallbackColorHex: String) -> SCNMaterial {
        let material = SCNMaterial()
        material.name = surface?.name ?? "Color"
        material.isDoubleSided = true
        material.lightingModel = .lambert
        let hex = surface?.colorHex ?? fallbackColorHex
        if let data = surface?.textureData, let image = NSImage(data: data) {
            material.diffuse.contents = image
        } else { material.diffuse.contents = color(hex) }
        let repeatSize = max(0.0001, surface?.textureScale ?? 1)
        let scale = SCNMatrix4MakeScale(CGFloat(1 / repeatSize), CGFloat(1 / repeatSize), 1)
        let rotate = SCNMatrix4MakeRotation(CGFloat(surface?.textureRotation ?? 0), 0, 0, 1)
        material.diffuse.contentsTransform = SCNMatrix4Mult(rotate, scale)
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .repeat
        material.diffuse.minificationFilter = .linear
        material.diffuse.magnificationFilter = .linear
        return material
    }

    static func materials(for entity: GardenEntity) -> (materials: [SCNMaterial], triangleMaterialIndices: [Int]) {
        let material = entity.surface
        var result = [makeMaterial(surface: material, fallbackColorHex: entity.colorHex)]
        let triangleCount = (try? entity.triangulatedMesh().triangles.count).map { $0 / 3 } ?? 0
        var assignments = Array(repeating: 0, count: triangleCount)
        for face in material?.faceOverrides ?? [] {
            let surface = SurfaceMaterial(name: "Face material", colorHex: face.colorHex, textureData: face.textureData, textureScale: face.textureScale, textureRotation: face.textureRotation)
            let index = result.count
            result.append(makeMaterial(surface: surface, fallbackColorHex: face.colorHex))
            for triangle in face.triangleIndices where assignments.indices.contains(triangle) { assignments[triangle] = index }
        }
        return (result, assignments)
    }

    /// Builds local-space triangles with planar UV coordinates in meters and one element per used material.
    static func geometry(for entity: GardenEntity) -> SCNGeometry? {
        guard let mesh = localMesh(for: entity), !mesh.triangles.isEmpty else { return nil }
        let appearance = materials(for: entity)
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], uv: [CGPoint] = []
        var groups = Array(repeating: [Int32](), count: appearance.materials.count)
        for triangle in 0..<(mesh.triangles.count / 3) {
            let points = (0..<3).map { mesh.vertices[mesh.triangles[triangle * 3 + $0]] }
            let a = points[0], b = points[1], c = points[2]
            let ux = b.x-a.x, uy = b.y-a.y, uz = b.z-a.z
            let vx = c.x-a.x, vy = c.y-a.y, vz = c.z-a.z
            let nx = uy*vz-uz*vy, ny = uz*vx-ux*vz, nz = ux*vy-uy*vx
            let length = max(1e-15,sqrt(nx*nx+ny*ny+nz*nz))
            let normal = SCNVector3(CGFloat(nx/length),CGFloat(ny/length),CGFloat(nz/length))
            let materialIndex = appearance.triangleMaterialIndices[triangle]
            for (corner, point) in points.enumerated() {
                groups[materialIndex].append(Int32(vertices.count))
                vertices.append(SCNVector3(CGFloat(point.x),CGFloat(point.y),CGFloat(point.z)))
                normals.append(normal)
                if let coordinates = mesh.textureCoordinates {
                    let coordinate = coordinates[mesh.triangles[triangle * 3 + corner]]
                    uv.append(CGPoint(x:coordinate.u,y:coordinate.v))
                } else if abs(nx) >= abs(ny) && abs(nx) >= abs(nz) { uv.append(CGPoint(x:point.z,y:point.y)) }
                else if abs(ny) >= abs(nz) { uv.append(CGPoint(x:point.x,y:point.z)) }
                else { uv.append(CGPoint(x:point.x,y:point.y)) }
            }
        }
        let used = groups.indices.filter { !groups[$0].isEmpty }
        let geometry = SCNGeometry(sources:[SCNGeometrySource(vertices:vertices),SCNGeometrySource(normals:normals),SCNGeometrySource(textureCoordinates:uv)],elements:used.map { SCNGeometryElement(indices:groups[$0],primitiveType:.triangles) })
        geometry.materials = used.map { appearance.materials[$0] }
        return geometry
    }

    /// Resolves a hit on geometry(for:) back to the model's original triangle ordinal.
    static func triangleIndex(for hit: SCNHitTestResult, entity: GardenEntity) -> Int? {
        let appearance = materials(for:entity)
        var groups = Array(repeating:[Int](),count:appearance.materials.count)
        for (triangle,materialIndex) in appearance.triangleMaterialIndices.enumerated() { groups[materialIndex].append(triangle) }
        let used = groups.filter { !$0.isEmpty }
        guard used.indices.contains(hit.geometryIndex), used[hit.geometryIndex].indices.contains(hit.faceIndex) else { return nil }
        return used[hit.geometryIndex][hit.faceIndex]
    }

    private static func localMesh(for entity:GardenEntity) -> MeshData? {
        if let mesh = entity.mesh { return mesh }
        guard var mesh = try? entity.triangulatedMesh() else { return nil }
        let cosine = cos(entity.rotation), sine = sin(entity.rotation)
        mesh.vertices = mesh.vertices.map {
            let x = $0.x-entity.origin.x, z = $0.z-entity.origin.z
            return Vec3(cosine*x-sine*z,$0.y-entity.origin.y,sine*x+cosine*z)
        }
        return mesh
    }

    static func color(_ hex: String) -> NSColor {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xE7DCC8
        return NSColor(srgbRed: CGFloat(value >> 16 & 255) / 255, green: CGFloat(value >> 8 & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    static func hex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? .white
        func component(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", component(rgb.redComponent), component(rgb.greenComponent), component(rgb.blueComponent))
    }
}

final class MaterialsPanelController: NSObject {
    static func numberForEditing(_ value:Double)->String {String(value)}
    var onApply: ((SurfaceMaterial, Bool) throws -> Void)?
    private var panel: NSPanel?
    private weak var parentWindow: NSWindow?
    private var material = SurfaceMaterial()
    private var library: [SurfaceMaterial] = [
        SurfaceMaterial(name: "Warm plaster",colorHex:"#E7DCC8"), SurfaceMaterial(name:"Oak",colorHex:"#A27650"),
        SurfaceMaterial(name:"Glass blue",colorHex:"#7FABB5"), SurfaceMaterial(name:"Sage",colorHex:"#6F8F6C"),
        SurfaceMaterial(name:"Concrete",colorHex:"#D3CEC2"), SurfaceMaterial(name:"Charcoal",colorHex:"#535B60"),
        SurfaceMaterial(name:"Brick",colorHex:"#A5624B"), SurfaceMaterial(name:"Porcelain",colorHex:"#F1F0E8")
    ]
    private let libraryMenu = NSPopUpButton()
    private let nameField = NSTextField()
    private let colorWell = NSColorWell()
    private let scaleField = NSTextField(string:"1")
    private let rotationField = NSTextField(string:"0")
    private let faceOnly = NSButton(checkboxWithTitle: "Apply to picked face(s) only", target: nil, action: nil)
    private let textureLabel = NSTextField(labelWithString:"No texture · solid color")
    private let preview = NSImageView()
    private let feedback = NSTextField(wrappingLabelWithString:"Choose a material or embed a PNG/JPEG texture.")
    private var importSKMButton: NSButton?
    private var exportSKMButton: NSButton?
    private let nativeStatus = NSTextField(wrappingLabelWithString:"Checking native SketchUp material support…")
    private var nativeAvailable = false
    private var exchangeBusy = false
    private var disabledControls: [(NSControl, Bool)] = []
    private struct SavedLibrary: Codable { var version = 1; var materials: [SurfaceMaterial] }

    func show(for window: NSWindow, current: SurfaceMaterial?) {
        if panel == nil { buildPanel() }
        if !exchangeBusy {
            material = current ?? SurfaceMaterial()
            updateFields()
            refreshNativeAvailability()
        }
        guard let panel else { return }
        if parentWindow !== window {
            parentWindow?.removeChildWindow(panel)
            parentWindow = window
            window.addChildWindow(panel, ordered: .above)
            panel.setFrameOrigin(NSPoint(x: window.frame.maxX - panel.frame.width - 26, y: window.frame.maxY - panel.frame.height - 50))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func text(_ value: String, size: CGFloat = 12, bold: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString:value)
        field.font = .systemFont(ofSize:size,weight:bold ? .semibold : .regular)
        return field
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title:title,target:self,action:action); button.bezelStyle = .rounded; return button
    }
    private func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let view = NSStackView(views:views); view.orientation = .horizontal; view.alignment = .centerY; view.spacing = spacing; return view
    }
    private func buildPanel() {
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:432,height:792),styleMask:[.titled,.closable,.utilityWindow],backing:.buffered,defer:false)
        panel.title = "Materials & Textures"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named:.aqua)
        self.panel = panel
        libraryMenu.target = self; libraryMenu.action = #selector(selectPreset)
        refreshLibraryMenu()
        colorWell.target = self; colorWell.action = #selector(colorChanged)
        colorWell.widthAnchor.constraint(equalToConstant:55).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant:30).isActive = true
        nameField.placeholderString = "Material name"
        nameField.widthAnchor.constraint(equalToConstant:260).isActive = true
        scaleField.widthAnchor.constraint(equalToConstant:75).isActive = true
        rotationField.widthAnchor.constraint(equalToConstant:75).isActive = true
        scaleField.font = .monospacedDigitSystemFont(ofSize:12,weight:.regular)
        rotationField.font = scaleField.font
        scaleField.target = self; scaleField.action = #selector(refreshPreview)
        rotationField.target = self; rotationField.action = #selector(refreshPreview)
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 7
        preview.layer?.masksToBounds = true
        preview.widthAnchor.constraint(equalToConstant:100).isActive = true
        preview.heightAnchor.constraint(equalToConstant:82).isActive = true
        textureLabel.font = .systemFont(ofSize:11)
        textureLabel.textColor = .secondaryLabelColor
        textureLabel.lineBreakMode = .byTruncatingMiddle
        feedback.font = .systemFont(ofSize:11)
        feedback.textColor = .secondaryLabelColor
        feedback.widthAnchor.constraint(equalToConstant:388).isActive = true
        let textureActions = NSStackView(views:[textureLabel,button("Load PNG/JPEG…",#selector(loadTexture)),button("Remove Texture",#selector(removeTexture))])
        textureActions.orientation = .vertical; textureActions.alignment = .leading; textureActions.spacing = 7
        let hint = NSTextField(wrappingLabelWithString:"Texture size is meters per repeat. Rotation is in degrees. Textures are embedded in your project; no external image paths are needed.")
        hint.font = .systemFont(ofSize:11); hint.textColor = .secondaryLabelColor; hint.widthAnchor.constraint(equalToConstant:388).isActive = true
        let faceHint = NSTextField(wrappingLabelWithString:"For face-only paint, pick a face in the model first. New whole-object paint replaces existing face overrides.")
        faceHint.font = .systemFont(ofSize:11); faceHint.textColor = .secondaryLabelColor; faceHint.widthAnchor.constraint(equalToConstant:388).isActive = true
        let apply = button("Apply Material",#selector(applyMaterial)); apply.keyEquivalent = "\r"
        let importSKM = button("Import SKM…",#selector(importNativeMaterial))
        let exportSKM = button("Export SKM…",#selector(exportNativeMaterial))
        importSKM.isEnabled = false; exportSKM.isEnabled = false
        importSKMButton = importSKM; exportSKMButton = exportSKM
        nativeStatus.font = .systemFont(ofSize:10)
        nativeStatus.textColor = .secondaryLabelColor
        nativeStatus.widthAnchor.constraint(equalToConstant:388).isActive = true
        let root = NSStackView(views:[text("MATERIAL LIBRARY",size:10,bold:true),libraryMenu,row([button("Load Library…",#selector(loadLibrary)),button("Save Library…",#selector(saveLibrary))]),row([importSKM,exportSKM]),nativeStatus,text("EDIT MATERIAL",size:10,bold:true),row([text("Name"),nameField]),row([text("Fallback color"),colorWell]),row([preview,textureActions],spacing:14),row([text("Tile size"),scaleField,text("m"),text("Rotation"),rotationField,text("°")]),hint,faceOnly,faceHint,button("Add to Library",#selector(addToLibrary)),feedback,NSView(),row([button("Close",#selector(close)),apply])])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top:18,left:20,bottom:18,right:20)
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(root)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:content.leadingAnchor),root.trailingAnchor.constraint(equalTo:content.trailingAnchor),root.topAnchor.constraint(equalTo:content.topAnchor),root.bottomAnchor.constraint(equalTo:content.bottomAnchor)])
        }
        libraryMenu.widthAnchor.constraint(equalToConstant:388).isActive = true
    }

    private func updateFields() {
        nameField.stringValue = material.name
        colorWell.color = MaterialManager.color(material.colorHex)
        scaleField.stringValue = Self.numberForEditing(material.textureScale)
        rotationField.stringValue = Self.numberForEditing(material.textureRotation * 180 / .pi)
        updatePreview()
        feedback.stringValue = "Choose a material or embed a PNG/JPEG texture."
    }
    private func updatePreview() {
        preview.image = material.textureData.flatMap(NSImage.init(data:))
        preview.layer?.backgroundColor = MaterialManager.color(material.colorHex).cgColor
        textureLabel.stringValue = material.textureData.map { "Embedded image · \($0.count / 1024) KB" } ?? "No texture · solid color"
    }
    private func readFields() throws -> SurfaceMaterial {
        var result = material
        result.name = nameField.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        result.colorHex = MaterialManager.hex(colorWell.color)
        guard let scale = Double(scaleField.stringValue), let degrees = Double(rotationField.stringValue) else { throw SurfaceMaterialError.invalid("Enter numeric texture size and rotation values.") }
        result.textureScale = scale; result.textureRotation = degrees * .pi / 180
        // The editor describes a paint, rather than carrying another object's face selections.
        result.faceOverrides = []
        try result.validate()
        return result
    }
    private func refreshLibraryMenu() {
        libraryMenu.removeAllItems()
        libraryMenu.addItems(withTitles:library.map(\.name))
    }
    private func showError(_ error: Error) {
        feedback.stringValue = error.localizedDescription
        guard let panel else { return }
        NSAlert(error:error).beginSheetModal(for:panel)
    }
    private func refreshNativeAvailability() {
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let available = NativeModelFormat.isAvailable
            DispatchQueue.main.async {
                guard let self else { return }
                self.nativeAvailable = available
                self.importSKMButton?.isEnabled = available && !self.exchangeBusy
                self.exportSKMButton?.isEnabled = available && !self.exchangeBusy
                self.nativeStatus.stringValue = available
                    ? "Native SketchUp materials · import to edit, then Apply Material."
                    : "Native SKM requires a usable SketchUp SDK installed on this Mac."
            }
        }
    }
    private func setExchangeBusy(_ busy: Bool) {
        exchangeBusy = busy
        if busy {
            func disable(_ view: NSView) {
                if let control = view as? NSControl {
                    disabledControls.append((control,control.isEnabled))
                    control.isEnabled = false
                }
                view.subviews.forEach(disable)
            }
            if let content = panel?.contentView { disable(content) }
        } else {
            for (control,enabled) in disabledControls { control.isEnabled = enabled }
            disabledControls.removeAll()
            importSKMButton?.isEnabled = nativeAvailable
            exportSKMButton?.isEnabled = nativeAvailable
        }
    }
    @objc private func importNativeMaterial() {
        guard nativeAvailable, !exchangeBusy, let panel else { return }
        let open = NSOpenPanel()
        open.allowedFileTypes = ["skm"]
        open.allowsMultipleSelection = false
        open.message = "Choose a SketchUp material to edit. Apply Material updates the model."
        open.beginSheetModal(for:panel) { [weak self] response in
            guard let self, response == .OK, let url = open.url else { return }
            self.setExchangeBusy(true)
            self.feedback.stringValue = "Importing SketchUp material…"
            DispatchQueue.global(qos:.userInitiated).async {
                let result = Result { try NativeModelFormat.readMaterial(url:url) }
                DispatchQueue.main.async {
                    self.setExchangeBusy(false)
                    switch result {
                    case let .success(candidate):
                        self.material = candidate
                        self.updateFields()
                        self.feedback.stringValue = "Imported SKM. Apply Material to paint the current selection."
                    case let .failure(error): self.showError(error)
                    }
                }
            }
        }
    }
    @objc private func exportNativeMaterial() {
        guard nativeAvailable, !exchangeBusy, let panel else { return }
        let candidate: SurfaceMaterial
        do { candidate = try readFields() } catch { showError(error); return }
        let save = NSSavePanel()
        save.allowedContentTypes = [UTType(filenameExtension:"skm") ?? .data]
        save.nameFieldStringValue = "Material.skm"
        save.beginSheetModal(for:panel) { [weak self] response in
            guard let self, response == .OK, let url = save.url else { return }
            self.setExchangeBusy(true)
            self.feedback.stringValue = "Exporting SketchUp material…"
            DispatchQueue.global(qos:.userInitiated).async {
                let result = Result { try NativeModelFormat.writeMaterial(candidate,to:url) }
                DispatchQueue.main.async {
                    self.setExchangeBusy(false)
                    switch result {
                    case .success: self.feedback.stringValue = "Exported \(url.lastPathComponent)."
                    case let .failure(error): self.showError(error)
                    }
                }
            }
        }
    }
    @objc private func selectPreset() {
        guard library.indices.contains(libraryMenu.indexOfSelectedItem) else { return }
        material = library[libraryMenu.indexOfSelectedItem]; updateFields()
    }
    @objc private func colorChanged() { material.colorHex = MaterialManager.hex(colorWell.color); updatePreview() }
    @objc private func refreshPreview() {
        do { material = try readFields(); updatePreview() } catch { feedback.stringValue = error.localizedDescription }
    }
    @objc private func loadTexture() {
        let open = NSOpenPanel(); open.allowedContentTypes = [.png,.jpeg]; open.allowsMultipleSelection = false
        guard open.runModal() == .OK, let url = open.url else { return }
        do {
            let bytes = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            guard bytes > 0, bytes <= SurfaceMaterial.maximumTextureBytes else { throw SurfaceMaterialError.invalid("Choose a PNG/JPEG texture no larger than 10 MB.") }
            let data = try Data(contentsOf:url)
            var candidate = try readFields(); candidate.textureData = data
            try candidate.validate()
            guard NSImage(data:data) != nil else { throw SurfaceMaterialError.invalid("The selected image could not be decoded.") }
            material = candidate; updatePreview(); feedback.stringValue = "Texture embedded. Apply the material to update the model."
        } catch { showError(error) }
    }
    @objc private func removeTexture() { material.textureData = nil; updatePreview() }
    @objc private func applyMaterial() {
        do {
            let candidate = try readFields(); material = candidate
            guard let onApply else { throw SurfaceMaterialError.invalid("Open a model and select an editable object before applying a material.") }
            try onApply(candidate,faceOnly.state == .on)
            feedback.stringValue = faceOnly.state == .on ? "Face material sent to the current selection." : "Material applied to the selected object."
        } catch { showError(error) }
    }
    @objc private func addToLibrary() {
        do {
            var item = try readFields(); item.id = UUID()
            guard library.count < 200 else { throw SurfaceMaterialError.invalid("A material library can contain at most 200 materials.") }
            library.append(item); material = item; refreshLibraryMenu(); libraryMenu.selectItem(at:library.count-1)
            feedback.stringValue = "Added to this library. Save Library to keep a reusable copy."
        } catch { showError(error) }
    }
    @objc private func saveLibrary() {
        let save = NSSavePanel(); save.allowedContentTypes = [.json]; save.nameFieldStringValue = "Materials.sketchmaterial.json"
        guard save.runModal() == .OK, let url = save.url else { return }
        do {
            for item in library { try item.validate() }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            let data = try encoder.encode(SavedLibrary(materials:library))
            guard data.count <= 60 * 1024 * 1024 else { throw SurfaceMaterialError.invalid("The material library exceeds the 60 MB file limit.") }
            try data.write(to:url,options:.atomic); feedback.stringValue = "Saved \(library.count) reusable materials."
        } catch { showError(error) }
    }
    @objc private func loadLibrary() {
        let open = NSOpenPanel(); open.allowedContentTypes = [.json]; open.allowsMultipleSelection = false
        guard open.runModal() == .OK, let url = open.url else { return }
        do {
            guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) <= 60 * 1024 * 1024 else { throw SurfaceMaterialError.invalid("The material library exceeds the 60 MB file limit.") }
            let data = try Data(contentsOf:url)
            let saved = try JSONDecoder().decode(SavedLibrary.self,from:data)
            guard saved.version == 1, !saved.materials.isEmpty, saved.materials.count <= 200 else { throw SurfaceMaterialError.invalid("This material library version or material count is unsupported.") }
            for item in saved.materials { try item.validate() }
            library = saved.materials; refreshLibraryMenu(); libraryMenu.selectItem(at:0)
            material = library[0]; updateFields(); feedback.stringValue = "Loaded \(library.count) reusable materials."
        } catch { showError(error) }
    }
    @objc private func close() { panel?.orderOut(nil) }
}
