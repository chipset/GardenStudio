import AppKit
import SceneKit
import SketchCore

/// Injectable transport keeps geometry responder tests independent of the system pasteboard service.
protocol GeometryPasteboard {
    func data(forType type:NSPasteboard.PasteboardType)->Data?
    func string(forType type:NSPasteboard.PasteboardType)->String?
    func writeGeometry(data:Data,text:String,type:NSPasteboard.PasteboardType)->Bool
}
extension NSPasteboard:GeometryPasteboard {
    func writeGeometry(data:Data,text:String,type:NSPasteboard.PasteboardType)->Bool {
        let item=NSPasteboardItem();item.setData(data,forType:type);item.setString(text,forType:.string)
        clearContents();return writeObjects([item])
    }
}

// SceneKit uses Y up. Model dimensions are metres; X/Z is the drawing plane.
enum ModelingTool: String, CaseIterable {
    case select, line, rectangle, circle, pushPull, move, paint, erase, orbit, pan
    case polygon, arc, freehand, rotate, scale, offset, followMe, tapeMeasure, dimension, text, section, axes, rotatedRectangle
}

final class ModelViewport: SCNView {
    var tool: ModelingTool = .select { didSet { cancelOperation(); updateCursor(); showToolHint() } }
    var document = ModelDocument() { didSet {
        if let axes=document.presentation?.drawingAxes {drawingPlane=Plane(origin:axes.origin,u:axes.xAxis,v:axes.yAxis,n:axes.normal)}
        else {drawingPlane=Plane(origin:Vec3(0,0,0),u:Vec3(1,0,0),v:Vec3(0,0,1),n:Vec3(0,1,0))}
        updateAxisIndicators()
        if let owner=faceOwner {
            let before=oldValue.entities.first{$0.id==owner},after=document.entities.first{$0.id==owner}
            if let before,let after,hasSameFaceGeometry(before,after) {
                // Face ordinals survive paint and rigid placement, but a cached
                // world-space extrusion profile does not survive those edits.
                if before.origin != after.origin || before.rotation != after.rotation || before.surface != after.surface || before.colorHex != after.colorHex {pickedProfile=nil}
            } else {clearFaceSelection()}
        }
        if let context=editingGroupID,!(document.editor?.groups.contains(where:{$0.id==context}) ?? false){editingGroupID=nil}
        rebuildEntities()
    } }
    var selectedID: UUID? { didSet {
        guard !syncingSelection else { return }
        syncingSelection = true
        if let id = selectedID { if !selectedIDs.contains(id) { selectedIDs = [id] } } else { selectedIDs = [] }
        syncingSelection = false; clearFaceSelectionIfOwnerChanged(); rebuildEntities()
    } }
    var selectedIDs: Set<UUID> = [] { didSet {
        guard !syncingSelection else { return }
        syncingSelection = true
        if selectedID == nil || !selectedIDs.contains(selectedID!) { selectedID = selectedIDs.sorted { $0.uuidString < $1.uuidString }.first }
        syncingSelection = false; clearFaceSelectionIfOwnerChanged(); rebuildEntities()
    } }
    private var syncingSelection = false
    var snapStep: Double = 0.001
    var editingGroupID: UUID? { didSet {rebuildEntities()} }
    var onGroupEditingChange: ((UUID?) -> Void)?
    var onSelectionSetChange: ((Set<UUID>) -> Void)?
    var onMeasure: ((Vec3, Vec3, Bool) -> Void)?
    var onTextPoint: ((Vec3) -> Void)?
    var onSectionPoint: ((Vec3, Vec3) -> Void)?
    var onAxesPoint: ((Vec3) -> Void)?
    var onDrawingAxesChange:((DrawingAxes)->Void)?
    let presentationRenderer = PresentationRenderer()
    private struct Plane { var origin: Vec3; var u: Vec3; var v: Vec3; var n: Vec3 }
    private var drawingPlane = Plane(origin: Vec3(0,0,0), u: Vec3(1,0,0), v: Vec3(0,0,1), n: Vec3(0,1,0))
    private var activePlane: Plane?
    private var points: [Vec3] = []
    private var rotatedRectangle = false
    private var axisConstraint: String?
    private var shiftConstraint: String?
    private var inferencePoints: [(Vec3, String)] = []
    private let inferenceMarker = SCNNode()
    private var pickedProfile: SketchEntity?
    private var boxSelecting = false
    private var selectionBeforeBox: Set<UUID> = []
    private let selectionBox = CAShapeLayer()
    private var inferenceLabel = ""
    private var faceOwner: UUID?
    private var faceSelection: [Int] = []
    var selectedFaceIndices: [Int] { faceOwner == selectedID ? faceSelection : [] }
    func recordFaceSelection(owner:UUID?,indices:[Int]) {
        if owner != faceOwner || indices != faceSelection {pickedProfile=nil}
        faceOwner=owner;faceSelection=indices
    }
    private func clearFaceSelection() {faceOwner=nil;faceSelection=[];pickedProfile=nil}
    private func clearFaceSelectionIfOwnerChanged() {
        if let owner=faceOwner,owner != selectedID {clearFaceSelection()}
    }
    private func hasSameFaceGeometry(_ before:SketchEntity,_ after:SketchEntity)->Bool {
        before.kind==after.kind && before.width==after.width && before.depth==after.depth && before.height==after.height && before.mesh==after.mesh && before.profile==after.profile && before.profileExtrusion==after.profileExtrusion
    }
    private var vertexDragPoint: Vec3?
    var paintColor = "#BA8B61"
    var onDocumentChange: ((ModelDocument) -> Void)?
    var onSelectionChange: ((UUID?) -> Void)?
    var onStatus: ((String) -> Void)?

    let models = SCNNode()
    private let preview = SCNNode()
    let cameraNode = SCNNode()
    private var tracking: NSTrackingArea?
    private var anchor: SCNVector3?
    private var latestGround: SCNVector3?
    private var dragStart = NSPoint.zero
    private var previousMouse = NSPoint.zero
    private var dragDocument: ModelDocument?
    private var dragEntity: SketchEntity?
    private var dragGround: SCNVector3?
    private var cameraGesture = false
    private var target = SCNVector3(0, 1, 0)
    private var yaw: CGFloat = .pi / 4
    private var pitch: CGFloat = 0.52
    private var distance: CGFloat = 19
    // Cache visible geometry bounds when rebuilding, not on each navigation event.
    private var modelBoundsCenter: Vec3?
    private var modelBoundsRadius: Double = 0

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frameRect, options: options)
        setupScene()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupScene()
    }

    private func setupScene() {
        let world = SCNScene()
        scene = world
        world.background.contents = NSColor(calibratedRed: 0.81, green: 0.87, blue: 0.91, alpha: 1)
        world.rootNode.addChildNode(models)
        world.rootNode.addChildNode(preview)
        world.rootNode.addChildNode(inferenceMarker)
        selectionBox.fillColor = NSColor.systemBlue.withAlphaComponent(0.08).cgColor
        selectionBox.strokeColor = NSColor.systemBlue.withAlphaComponent(0.8).cgColor
        selectionBox.lineWidth = 1
        wantsLayer = true; layer?.addSublayer(selectionBox)
        backgroundColor = .white
        antialiasingMode = .multisampling4X
        autoenablesDefaultLighting = false
        allowsCameraControl = false
        rendersContinuously = false
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zNear = 0.01
        cameraNode.camera?.zFar = 5000
        cameraNode.camera?.fieldOfView = 43
        cameraNode.camera?.wantsHDR = false
        world.rootNode.addChildNode(cameraNode)
        pointOfView = cameraNode
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = NSColor(white: 0.78, alpha: 1)
        world.rootNode.addChildNode(ambient)
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 650
        sun.eulerAngles = SCNVector3(-CGFloat.pi / 3, -CGFloat.pi / 5, 0)
        world.rootNode.addChildNode(sun)
        let ground = SCNNode(geometry: SCNPlane(width: 2000, height: 2000))
        ground.eulerAngles.x = -.pi / 2
        ground.position.y = -0.025
        ground.geometry?.firstMaterial = material("#E3E4DB")
        ground.name = "ground"
        world.rootNode.addChildNode(ground)
        var grid: [SCNVector3] = []
        for index in -40...40 {
            let x = CGFloat(index)
            grid += [SCNVector3(x, 0, -40), SCNVector3(x, 0, 40)]
            grid += [SCNVector3(-40, 0, x), SCNVector3(40, 0, x)]
        }
        world.rootNode.addChildNode(lineNode(grid, color: NSColor(white: 0.64, alpha: 0.28)))
        let xAxis=lineNode([SCNVector3(-100,0.008,0),SCNVector3(100,0.008,0)],color:.systemRed);xAxis.name="sketchmake.axis.x";world.rootNode.addChildNode(xAxis)
        let zAxis=lineNode([SCNVector3(0,0.008,-100),SCNVector3(0,0.008,100)],color:.systemGreen);zAxis.name="sketchmake.axis.z";world.rootNode.addChildNode(zAxis)
        let yAxis=lineNode([SCNVector3(0,0,0),SCNVector3(0,100,0)],color:.systemBlue);yAxis.name="sketchmake.axis.y";world.rootNode.addChildNode(yAxis)
        updateCamera()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor() }

    private func updateCursor() {
        switch tool {
        case .select: NSCursor.arrow.set()
        case .orbit, .pan, .move: NSCursor.openHand.set()
        default: NSCursor.crosshair.set()
        }
    }

    private func material(_ hex: String) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color(hex)
        m.lightingModel = .lambert
        m.isDoubleSided = true
        return m
    }

    private func color(_ hex: String) -> NSColor {
        MaterialManager.color(hex)
    }

    private func lineNode(_ vertices: [SCNVector3], color: NSColor) -> SCNNode {
        guard !vertices.isEmpty else { return SCNNode() }
        let source = SCNGeometrySource(vertices: vertices)
        let indices = Array(0..<Int32(vertices.count))
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .constant
        m.readsFromDepthBuffer = true
        m.writesToDepthBuffer = false
        geometry.materials = [m]
        let node = SCNNode(geometry: geometry)
        node.categoryBitMask = 4
        return node
    }

    private func entityNode(_ source: SketchEntity, temporary: Bool = false) -> SCNNode {
        var entity=source
        if entity.kind != .mesh,entity.kind != .line,let world=try? entity.triangulatedMesh() {
            let c=cos(entity.rotation),s=sin(entity.rotation)
            var local=world
            local.vertices=world.vertices.map{p in let x=p.x-entity.origin.x,z=p.z-entity.origin.z;return Vec3(c*x-s*z,p.y-entity.origin.y,s*x+c*z)}
            entity.kind = .mesh;entity.mesh=local
        }
        let node = SCNNode()
        node.name = entity.id.uuidString
        node.categoryBitMask = temporary ? 4 : 2
        node.position = SCNVector3(CGFloat(entity.origin.x), CGFloat(entity.origin.y), CGFloat(entity.origin.z))
        // SceneKit stores transforms as floats. Preserve libm's Double phase
        // before passing a bounded equivalent angle to the renderer.
        node.eulerAngles.y = CGFloat(atan2(sin(entity.rotation),cos(entity.rotation)))
        let selected = selectedIDs.contains(entity.id) && !temporary
        let stroke = temporary ? NSColor.systemOrange : (selected ? NSColor.systemBlue : NSColor(calibratedWhite: 0.18, alpha: 1))
        if entity.kind == .mesh, let mesh = entity.mesh {
            let vertices = mesh.vertices.map { SCNVector3(CGFloat($0.x), CGFloat($0.y), CGFloat($0.z)) }
            if !mesh.triangles.isEmpty {
                let source = SCNGeometrySource(vertices: vertices)
                let element = SCNGeometryElement(indices: mesh.triangles.map { Int32($0) }, primitiveType: .triangles)
                let geometry = MaterialManager.geometry(for:entity) ?? SCNGeometry(sources: [source], elements: [element])
                if geometry.materials.isEmpty {geometry.materials=[material(entity.colorHex)]}
                for surface in geometry.materials {
                    if selected { surface.emission.contents = NSColor(calibratedRed: 0.03, green: 0.08, blue: 0.18, alpha: 1) }
                    if temporary {surface.transparency=0.55}
                }
                let solid = SCNNode(geometry: geometry); solid.categoryBitMask = temporary ? 4 : 2; node.addChildNode(solid)
            }
            var edges: [SCNVector3] = []
            for i in stride(from: 0, to: mesh.lineIndices.count, by: 2) {
                edges += [vertices[mesh.lineIndices[i]], vertices[mesh.lineIndices[i+1]]]
            }
            if !selected,mesh.triangles.count<=60000 {
                var adjacent:[String:(Int,Int,Vec3,Int,Bool)]=[:]
                for i in stride(from:0,to:mesh.triangles.count,by:3) {
                    let a=mesh.triangles[i],b=mesh.triangles[i+1],c=mesh.triangles[i+2]
                    let normal=normalized(cross(sub(mesh.vertices[b],mesh.vertices[a]),sub(mesh.vertices[c],mesh.vertices[a])))
                    for (start,end) in [(a,b),(b,c),(c,a)] {
                        let key="\(min(start,end)):\(max(start,end))"
                        if let previous=adjacent[key] {adjacent[key]=(previous.0,previous.1,previous.2,previous.3+1,previous.4 || dot(previous.2,normal)<0.995)}
                        else {adjacent[key]=(start,end,normal,1,false)}
                    }
                }
                var outline:[SCNVector3]=[]
                for edge in adjacent.values where edge.3==1 || edge.4 {outline += [vertices[edge.0],vertices[edge.1]]}
                node.addChildNode(lineNode(outline,color:stroke))
            }
            // Keep wire profiles selectable; triangle surfaces use their own hit geometry.
            if !edges.isEmpty {
                let wire = lineNode(edges, color: selected || temporary ? stroke : color(entity.surface?.colorHex ?? entity.colorHex)); wire.categoryBitMask = temporary ? 4 : 2; node.addChildNode(wire)
            }
            if selected && mesh.triangles.count <= 60_000 {
                var triangleEdges: [SCNVector3] = []
                for i in stride(from: 0, to: mesh.triangles.count, by: 3) {
                    let a = vertices[mesh.triangles[i]], b = vertices[mesh.triangles[i+1]], c = vertices[mesh.triangles[i+2]]
                    triangleEdges += [a,b,b,c,c,a]
                }
                node.addChildNode(lineNode(triangleEdges, color: stroke))
            }
            return node
        }
        if entity.kind == .line {
            let end = SCNVector3(CGFloat(entity.width), CGFloat(entity.height), CGFloat(entity.depth))
            let edge = lineNode([SCNVector3Zero, end], color: selected || temporary ? stroke : color(entity.surface?.colorHex ?? entity.colorHex))
            edge.categoryBitMask = temporary ? 4 : 2
            node.addChildNode(edge)
            return node
        }
        return node
    }

    private func rebuildEntities() {
        models.childNodes.forEach { $0.removeFromParentNode() }
        document.entities.filter { $0.isVisible(in: document) }.forEach {
            let node=entityNode($0)
            if editingGroupID != nil,document.effectiveSelection([$0.id],editingGroupID:editingGroupID).isEmpty {node.opacity=0.25}
            models.addChildNode(node)
        }
        let bounds = models.boundingBox
        let center = Vec3((Double(bounds.min.x)+Double(bounds.max.x))/2,
                          (Double(bounds.min.y)+Double(bounds.max.y))/2,
                          (Double(bounds.min.z)+Double(bounds.max.z))/2)
        let radius = hypot(hypot(Double(bounds.max.x)-center.x, Double(bounds.max.y)-center.y), Double(bounds.max.z)-center.z)
        modelBoundsCenter = !models.childNodes.isEmpty && [center.x,center.y,center.z,radius].allSatisfy(\.isFinite) ? center : nil
        modelBoundsRadius = modelBoundsCenter == nil ? 0 : radius
        updateCamera()
        refreshInferencePoints()
        if let scene { presentationRenderer.update(scene: scene, presentation: document.presentation ?? PresentationState()) }
        needsDisplay = true
    }

    private func updateCamera() {
        cameraNode.camera?.orthographicScale = Double(distance)*0.45
        cameraNode.camera?.zNear = Double(max(0.000001, min(0.01, distance / 10000)))
        let offset = modelBoundsCenter.map { hypot(hypot($0.x-Double(target.x), $0.y-Double(target.y)), $0.z-Double(target.z)) } ?? 0
        cameraNode.camera?.zFar = max(5000, (Double(distance) + offset + modelBoundsRadius) * 1.1)
        cameraNode.position = SCNVector3(target.x + distance * cos(pitch) * sin(yaw), target.y + distance * sin(pitch), target.z + distance * cos(pitch) * cos(yaw))
        // The convenience look(at:) reuses the node's current worldUp, allowing
        // previous views to roll the next one. Use a fixed world reference.
        let viewDelta=sub(vec(cameraNode.position),vec(target))
        let horizontal=hypot(viewDelta.x,viewDelta.z)
        let viewDistance=hypot(horizontal,viewDelta.y)
        let up=horizontal<=viewDistance*1e-6 ? SCNVector3(0,0,-1):SCNVector3(0,1,0)
        cameraNode.look(at:target,up:up,localFront:SCNVector3(0,0,-1))
        needsDisplay = true
    }

    func setStandardView(_ name: String) {
        switch name.lowercased() {
        case "top": yaw = 0; pitch = .pi / 2 - 0.001
        case "front": yaw = 0; pitch = 0.001
        case "right": yaw = .pi / 2; pitch = 0.001
        default: yaw = .pi / 4; pitch = 0.52
        }
        updateCamera()
    }

    func zoomExtents() {
        guard !document.entities.isEmpty else { target = SCNVector3(0, 0, 0); distance = 19; updateCamera(); return }
        var minX = Double.infinity, maxX = -Double.infinity
        var minZ = Double.infinity, maxZ = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        for entity in document.entities where entity.isVisible(in: document) {
            if let mesh = try? entity.triangulatedMesh() {
                for vertex in mesh.vertices {
                    minX = min(minX, vertex.x); maxX = max(maxX, vertex.x)
                    minY = min(minY, vertex.y); maxY = max(maxY, vertex.y)
                    minZ = min(minZ, vertex.z); maxZ = max(maxZ, vertex.z)
                }
                continue
            }
            minX = min(minX, entity.origin.x - abs(entity.width) / 2)
            maxX = max(maxX, entity.origin.x + abs(entity.width) / 2)
            minZ = min(minZ, entity.origin.z - abs(entity.depth) / 2)
            maxZ = max(maxZ, entity.origin.z + abs(entity.depth) / 2)
            minY = min(minY, entity.origin.y)
            maxY = max(maxY, entity.origin.y + abs(entity.height))
        }
        guard minX.isFinite, maxX.isFinite else { return }
        let center=Vec3(minX/2+maxX/2,minY/2+maxY/2,minZ/2+maxZ/2)
        let fitDistance=max(0.005,max(maxX-minX,max(maxZ-minZ,maxY-minY))*2.1)
        let proposed=CameraState(target:center,yaw:Double(yaw),pitch:Double(pitch),distance:fitDistance,
                                 orthographic:cameraNode.camera?.usesOrthographicProjection ?? false)
        guard (try? proposed.validate()) != nil else {
            onStatus?("Model extents exceed the supported camera range. The current view was preserved.")
            return
        }
        target=scn(center)
        distance=CGFloat(fitDistance)
        updateCamera()
    }

    private func vec(_ p: SCNVector3) -> Vec3 { Vec3(Double(p.x), Double(p.y), Double(p.z)) }
    private func scn(_ p: Vec3) -> SCNVector3 { SCNVector3(CGFloat(p.x),CGFloat(p.y),CGFloat(p.z)) }
    private func add(_ a: Vec3, _ b: Vec3) -> Vec3 { Vec3(a.x+b.x,a.y+b.y,a.z+b.z) }
    private func sub(_ a: Vec3, _ b: Vec3) -> Vec3 { Vec3(a.x-b.x,a.y-b.y,a.z-b.z) }
    private func mul(_ a: Vec3, _ t: Double) -> Vec3 { Vec3(a.x*t,a.y*t,a.z*t) }
    private func dot(_ a: Vec3, _ b: Vec3) -> Double { a.x*b.x+a.y*b.y+a.z*b.z }
    private func cross(_ a: Vec3, _ b: Vec3) -> Vec3 { Vec3(a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x) }
    private func length(_ a: Vec3) -> Double { sqrt(dot(a,a)) }
    private func normalized(_ a: Vec3) -> Vec3 { mul(a,1/max(length(a),1e-12)) }
    private func makePlane(origin: Vec3, normal: Vec3) -> Plane {
        let n = normalized(normal)
        let u = normalized(cross(abs(n.y) > 0.9 ? Vec3(0,0,1) : Vec3(0,1,0),n))
        return Plane(origin: origin,u:u,v:normalized(cross(n,u)),n:n)
    }
    private func updateAxisIndicators() {
        guard let root=scene?.rootNode else{return}
        let names=["sketchmake.axis.x","sketchmake.axis.y","sketchmake.axis.z"]
        for name in names {root.childNode(withName:name,recursively:false)?.removeFromParentNode()}
        let offset=mul(drawingPlane.n,0.008),origin=drawingPlane.origin
        let x=add(origin,offset),xA=add(x,mul(drawingPlane.u,-100)),xB=add(x,mul(drawingPlane.u,100))
        let zA=add(add(origin,offset),mul(drawingPlane.v,-100)),zB=add(add(origin,offset),mul(drawingPlane.v,100))
        let normalEnd=add(origin,mul(drawingPlane.n,100))
        let xAxis=lineNode([scn(xA),scn(xB)],color:.systemRed);xAxis.name=names[0]
        let yAxis=lineNode([scn(origin),scn(normalEnd)],color:.systemBlue);yAxis.name=names[1]
        let zAxis=lineNode([scn(zA),scn(zB)],color:.systemGreen);zAxis.name=names[2]
        root.addChildNode(xAxis);root.addChildNode(yAxis);root.addChildNode(zAxis)
    }
    func setDrawingPlane(_ name: String) {
        cancelOperation()
        let origin=drawingPlane.origin
        switch name.lowercased() {
        case "front": drawingPlane = Plane(origin: origin,u:Vec3(1,0,0),v:Vec3(0,1,0),n:Vec3(0,0,1))
        case "right": drawingPlane = Plane(origin: origin,u:Vec3(0,0,-1),v:Vec3(0,1,0),n:Vec3(1,0,0))
        default: drawingPlane = Plane(origin: origin,u:Vec3(1,0,0),v:Vec3(0,0,1),n:Vec3(0,1,0))
        }
        updateAxisIndicators()
        if let axes=try? DrawingAxes(origin:drawingPlane.origin,xAxis:drawingPlane.u,normal:drawingPlane.n){onDrawingAxesChange?(axes)}
        onStatus?("Drawing plane: \(name). Click a surface to draw on its plane.")
    }
    func setDrawingAxes(_ axes:DrawingAxes) {
        drawingPlane=Plane(origin:axes.origin,u:axes.xAxis,v:axes.yAxis,n:axes.normal)
        updateAxisIndicators()
        onDrawingAxesChange?(axes)
    }
    private func groundPoint(_ point: NSPoint) -> SCNVector3? { drawingPoint(point).map(scn) }
    private func drawingPoint(_ point: NSPoint, infer: Bool = true, shift: Bool = false) -> Vec3? {
        if (tool == .tapeMeasure || tool == .dimension),axisConstraint == nil,!shift,let (_,hit)=entityHit(point) {
            var result=vec(hit.worldCoordinates),best=10.0
            inferenceLabel="On surface"
            for (candidate,label) in inferencePoints {
                if let section=document.presentation?.section,section.enabled,let signed=try? section.signedDistance(to:candidate),signed>0{continue}
                let p=projectPoint(scn(candidate))
                guard p.z>=0,p.z<=1 else {continue}
                let separation=hypot(Double(p.x-point.x),Double(p.y-point.y))
                if separation<best {best=separation;result=candidate;inferenceLabel=label}
            }
            return result
        }
        let plane = activePlane ?? drawingPlane
        let near = vec(unprojectPoint(SCNVector3(point.x,point.y,0)))
        let far = vec(unprojectPoint(SCNVector3(point.x,point.y,1)))
        let ray = sub(far,near), denom = dot(ray,plane.n)
        guard abs(denom) > 1e-10 else { return nil }
        let t = dot(sub(plane.origin,near),plane.n)/denom
        guard t > 0 else { return nil }
        var result = add(near,mul(ray,t))
        inferenceLabel = ""
        if infer {
            var best: (Vec3,String,Double)?
            for (candidate,label) in inferencePoints {
                if let section=document.presentation?.section,section.enabled,let signed=try? section.signedDistance(to:candidate),signed>0{continue}
                guard abs(dot(sub(candidate,plane.origin),plane.n)) < max(snapStep,1e-5) else { continue }
                let projected = projectPoint(scn(candidate))
                guard projected.z >= 0, projected.z <= 1 else { continue }
                let d = hypot(Double(projected.x-point.x),Double(projected.y-point.y))
                if d < 10, d < (best?.2 ?? .infinity) { best = (candidate,label,d) }
            }
            if let best { result = best.0; inferenceLabel = best.1 }
            else if snapStep.isFinite, snapStep > 0 {
                let local = sub(result,plane.origin)
                result = add(plane.origin,add(mul(plane.u,(dot(local,plane.u)/snapStep).rounded()*snapStep),mul(plane.v,(dot(local,plane.v)/snapStep).rounded()*snapStep)))
            }
        }
        if let first = points.first ?? anchor.map(vec) {
            let delta = sub(result,first)
            if shift, shiftConstraint == nil {
                shiftConstraint = abs(delta.x) >= abs(delta.y) && abs(delta.x) >= abs(delta.z) ? "x" : (abs(delta.y) >= abs(delta.z) ? "y" : "z")
            } else if !shift { shiftConstraint = nil }
            let axis = axisConstraint ?? shiftConstraint
            if let axis {
                let direction = axis == "x" ? Vec3(1,0,0) : axis == "y" ? Vec3(0,1,0) : Vec3(0,0,1)
                let rayLength=dot(ray,ray),projection=dot(direction,ray),separation=sub(near,first)
                let denominator=rayLength-projection*projection
                if abs(denominator)>1e-12 {
                    let along=(dot(ray,separation)*projection-dot(direction,separation)*rayLength)/denominator
                    result=add(first,mul(direction,along))
                } else { result=add(first,mul(direction,dot(sub(result,first),direction))) }
                inferenceLabel = "\(axis.uppercased()) axis locked"
            } else if inferenceLabel.isEmpty {
                let tolerance = Double(distance)/max(Double(bounds.height),1)*7
                if abs(delta.x) < tolerance { result.x = first.x; inferenceLabel = "Aligned X" }
                if abs(delta.z) < tolerance { result.z = first.z; inferenceLabel = "Aligned Z" }
            }
        }
        guard [result.x,result.y,result.z].allSatisfy({ $0.isFinite && abs($0)<1e6 }) else { return nil }
        return result
    }
    private func refreshInferencePoints() {
        inferencePoints = []
        for guide in document.presentation?.guides ?? [] {
            inferencePoints += [(guide.start,"Guide endpoint"),(guide.end,"Guide endpoint"),(mul(add(guide.start,guide.end),0.5),"Guide midpoint")]
        }
        for entity in document.entities where entity.isVisible(in: document) {
            guard let mesh = try? entity.triangulatedMesh() else { continue }
            let vertices = mesh.vertices
            if !vertices.isEmpty {
                var center = Vec3(0,0,0)
                for v in vertices { center = add(center,v) }
                inferencePoints.append((mul(center,1/Double(vertices.count)),"Center"))
            }
            let step = max(1,vertices.count/200)
            for i in stride(from:0,to:vertices.count,by:step) { inferencePoints.append((vertices[i],"Endpoint")) }
            for i in stride(from:0,to:min(mesh.lineIndices.count,400),by:2) {
                inferencePoints.append((mul(add(vertices[mesh.lineIndices[i]],vertices[mesh.lineIndices[i+1]]),0.5),"Midpoint"))
            }
            if mesh.lineIndices.isEmpty {
                var seen=Set<String>()
                for i in stride(from:0,to:min(mesh.triangles.count,300),by:3) {
                    for edge in [(mesh.triangles[i],mesh.triangles[i+1]),(mesh.triangles[i+1],mesh.triangles[i+2]),(mesh.triangles[i+2],mesh.triangles[i])] {
                        let key="\(min(edge.0,edge.1)):\(max(edge.0,edge.1))"
                        if seen.insert(key).inserted { inferencePoints.append((mul(add(vertices[edge.0],vertices[edge.1]),0.5),"Midpoint")) }
                    }
                }
            }
            if inferencePoints.count > 6000 { break }
        }
    }
    private func entityHit(_ point: NSPoint) -> (SketchEntity,SCNHitTestResult)? {
        for hit in hitTest(point,options:[.categoryBitMask:2,.searchMode:SCNHitTestSearchMode.all.rawValue]) {
            if let section=document.presentation?.section,section.enabled,let signed=try? section.signedDistance(to:vec(hit.worldCoordinates)),signed>0 {continue}
            var node: SCNNode? = hit.node
            while let current = node {
                if let name=current.name, let id=UUID(uuidString:name), let entity=document.entities.first(where:{$0.id==id}), entity.isVisible(in:document),editingGroupID == nil || !document.effectiveSelection([entity.id],editingGroupID:editingGroupID).isEmpty { return (entity,hit) }
                node=current.parent
            }
        }
        return nil
    }
    private func faceIndices(for entity: SketchEntity, hit: SCNHitTestResult) -> [Int] {
        guard let geometry=hit.node.geometry,geometry.elements.indices.contains(hit.geometryIndex),geometry.elements[hit.geometryIndex].primitiveType == .triangles else{return []}
        let seed=MaterialManager.triangleIndex(for:hit,entity:entity)
        return coplanarFaceIndices(entity:entity,point:vec(hit.worldCoordinates),normal:vec(hit.worldNormal),seedTriangle:seed)
    }
    func coplanarFaceIndices(entity:SketchEntity,point:Vec3,normal:Vec3,seedTriangle:Int?)->[Int] {
        guard let mesh=try? entity.triangulatedMesh(),!mesh.triangles.isEmpty else{return []}
        let hitNormal=normalized(normal)
        let tolerance=max(1e-7,Double(distance)*1e-7)
        var result:[Int]=[]
        for i in stride(from:0,to:mesh.triangles.count,by:3) {
            let a=mesh.vertices[mesh.triangles[i]],b=mesh.vertices[mesh.triangles[i+1]],c=mesh.vertices[mesh.triangles[i+2]]
            let normal=normalized(cross(sub(b,a),sub(c,a)))
            if abs(dot(normal,hitNormal))>0.999 && abs(dot(sub(a,point),normal))<tolerance && abs(dot(sub(b,point),normal))<tolerance && abs(dot(sub(c,point),normal))<tolerance {result.append(i/3)}
        }
        if result.isEmpty,entity.kind == .mesh || entity.surface != nil,let triangle=seedTriangle{return [triangle]}
        guard let seed=seedTriangle,result.contains(seed) else{return result}
        // Coincident vertices can have distinct indices at UV/material seams.
        // Connect by physical edges, so a picked face includes its tessellation
        // while separate coplanar islands remain independently paintable.
        struct PositionKey:Hashable {let x:Double;let y:Double;let z:Double}
        struct EdgeKey:Hashable {let a:Int;let b:Int}
        var positions:[PositionKey:Int]=[:],vertices:[Int:Int]=[:]
        func canonical(_ source:Int)->Int {
            if let known=vertices[source]{return known}
            let p=mesh.vertices[source],key=PositionKey(x:p.x,y:p.y,z:p.z)
            let index=positions[key] ?? positions.count
            positions[key]=index;vertices[source]=index;return index
        }
        var owners:[EdgeKey:Int]=[:],neighbors:[Int:[Int]]=[:]
        for triangle in result {
            let indices=(0..<3).map{canonical(mesh.triangles[triangle*3+$0])}
            for (a,b) in [(indices[0],indices[1]),(indices[1],indices[2]),(indices[2],indices[0])] {
                let key=EdgeKey(a:min(a,b),b:max(a,b))
                if let owner=owners[key]{neighbors[owner,default:[]].append(triangle);neighbors[triangle,default:[]].append(owner)}
                else{owners[key]=triangle}
            }
        }
        var connected:Set<Int>=[seed],pending=[seed]
        while let triangle=pending.popLast(){for neighbor in neighbors[triangle] ?? [] where connected.insert(neighbor).inserted{pending.append(neighbor)}}
        return result.filter{connected.contains($0)}
    }
    private func profileForPickedFace(_ entity: SketchEntity,hit: SCNHitTestResult) -> SketchEntity? {
        guard let mesh=try? entity.triangulatedMesh() else{return nil}
        let selected=faceSelection.filter{$0>=0 && $0*3+2<mesh.triangles.count}
        guard !selected.isEmpty,selected.count<20000 else{return nil}
        var points:[Vec3]=[],canonical:[String:Int]=[:],edges:[String:(Int,Int,Int)]=[:]
        func index(_ p: Vec3) -> Int {
            let key=String(format:"%.12g,%.12g,%.12g",p.x,p.y,p.z)
            if let found=canonical[key]{return found}
            let value=points.count;points.append(p);canonical[key]=value;return value
        }
        for face in selected {
            let triangle=(0..<3).map{index(mesh.vertices[mesh.triangles[face*3+$0]])}
            for (a,b) in [(triangle[0],triangle[1]),(triangle[1],triangle[2]),(triangle[2],triangle[0])] {
                let key="\(min(a,b)):\(max(a,b))";let count=edges[key]?.2 ?? 0;edges[key]=(a,b,count+1)
            }
        }
        var boundary=edges.values.filter{$0.2==1}.map{($0.0,$0.1)},loops:[[Vec3]]=[]
        while let edge=boundary.first {
            boundary.removeFirst();var ring=[edge.0,edge.1]
            while ring.last != ring.first {
                guard let i=boundary.firstIndex(where:{$0.0==ring.last || $0.1==ring.last}) else{return nil}
                let next=boundary.remove(at:i);ring.append(next.0==ring.last ? next.1:next.0)
                if ring.count>points.count+1{return nil}
            }
            ring.removeLast();if ring.count>=3{loops.append(ring.map{points[$0]})}
        }
        func area(_ ring:[Vec3])->Double {
            var total=Vec3(0,0,0)
            for i in ring.indices{total=add(total,cross(ring[i],ring[(i+1)%ring.count]))}
            return length(total)
        }
        loops.sort{area($0)>area($1)}
        guard let outer=loops.first,var face=try? GeometryTools.face(points:outer,holes:Array(loops.dropFirst()),name:"Extruded face",colorHex:entity.colorHex) else{return nil}
        face.surface=entity.surface;face.surface?.faceOverrides=[];face.metadata=entity.metadata
        if face.metadata?.componentPartID != nil{face.metadata?.componentPartID=UUID()}
        return face
    }
    private func entityAt(_ point: NSPoint) -> SketchEntity? {
        if let hit=entityHit(point) { return hit.0 }
        for entity in document.entities.reversed() where entity.isVisible(in:document) {
            if editingGroupID != nil,document.effectiveSelection([entity.id],editingGroupID:editingGroupID).isEmpty {continue}
            guard let mesh=try? entity.triangulatedMesh(),mesh.lineIndices.count<=40000 else { continue }
            for i in stride(from:0,to:mesh.lineIndices.count,by:2) {
                var start=mesh.vertices[mesh.lineIndices[i]],end=mesh.vertices[mesh.lineIndices[i+1]]
                if let section=document.presentation?.section,section.enabled,let a=try? section.signedDistance(to:start),let b=try? section.signedDistance(to:end) {
                    if a>0,b>0{continue}
                    if (a>0) != (b>0) {
                        let intersection=add(start,mul(sub(end,start),a/(a-b)))
                        if a>0{start=intersection}else{end=intersection}
                    }
                }
                let a=projectPoint(scn(start)),b=projectPoint(scn(end))
                guard a.z>=0,a.z<=1,b.z>=0,b.z<=1 else { continue }
                let dx=b.x-a.x,dy=b.y-a.y,squared=dx*dx+dy*dy
                let f=squared>0 ? max(0,min(1,((point.x-a.x)*dx+(point.y-a.y)*dy)/squared)) : 0
                if hypot(point.x-a.x-f*dx,point.y-a.y-f*dy)<=6 { return entity }
            }
        }
        return nil
    }
    private func choose(_ id: UUID?) { chooseSet(id.map { [$0] } ?? []) }
    private func chooseSet(_ ids: Set<UUID>) {
        selectedIDs=document.effectiveSelection(ids,editingGroupID:editingGroupID)
        onSelectionSetChange?(selectedIDs)
        onSelectionChange?(selectedID)
    }
    private func commit(_ next: ModelDocument) {
        do { try next.validate(); cancelEditingDrag(); document=next; onDocumentChange?(next) }
        catch { onStatus?(error.localizedDescription) }
    }
    private func beginDrawingPlane(_ point: NSPoint) {
        if let (_,hit)=entityHit(point) { activePlane=makePlane(origin:vec(hit.worldCoordinates),normal:vec(hit.worldNormal)) }
        else { activePlane=drawingPlane }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point=convert(event.locationInWindow,from:nil)
        dragStart=point; previousMouse=point
        cameraGesture=tool == .orbit || tool == .pan || event.modifierFlags.contains(.option)
        if cameraGesture { NSCursor.closedHand.set(); return }
        let entity=entityAt(point)
        if let (picked,hit)=entityHit(point) { recordFaceSelection(owner:picked.id,indices:faceIndices(for:picked,hit:hit)) } else { recordFaceSelection(owner:nil,indices:[]) }
        let drawing: Set<ModelingTool>=[.rectangle,.rotatedRectangle,.circle,.line,.polygon,.arc,.freehand,.tapeMeasure,.dimension,.text,.section,.axes]
        if drawing.contains(tool) {
            if points.isEmpty && anchor == nil { beginDrawingPlane(point); rotatedRectangle=tool == .rotatedRectangle || event.modifierFlags.contains(.control) }
            guard let position=drawingPoint(point,shift:event.modifierFlags.contains(.shift)) else { onStatus?("The drawing plane is edge-on. Orbit or change drawing plane.");return }
            if tool == .text { onTextPoint?(position);activePlane=nil;return }
            if tool == .section { onSectionPoint?(position,(activePlane ?? drawingPlane).n);activePlane=nil;return }
            if tool == .axes {
                drawingPlane.origin=position
                updateAxisIndicators()
                if let axes=try? DrawingAxes(origin:position,xAxis:drawingPlane.u,normal:drawingPlane.n){onDrawingAxesChange?(axes)}
                onAxesPoint?(position);activePlane=nil;onStatus?("Drawing axes moved to clicked point.");return
            }
            if tool == .freehand { beginDrawing(at:position);return }
            if tool == .polygon {
                if points.count>=3 && (event.clickCount>1 || length(sub(position,points[0])) < Double(distance)/500) { finishProfile();return }
                points.append(position);anchor=scn(points[0]);onStatus?("Polygon: click corners; double-click or Return closes the face.");return
            }
            if tool == .arc {
                points.append(position);anchor=scn(points[0])
                if points.count==3 { do { append(try GeometryTools.arc(center:points[0],start:points[1],end:points[2]));clearDrawing() } catch { onStatus?(error.localizedDescription);points.removeLast() } }
                else { onStatus?(points.count==1 ? "Arc: choose start point." : "Arc: choose end point.") };return
            }
            if let first=anchor {
                if tool == .tapeMeasure || tool == .dimension {
                    onMeasure?(vec(first),position,tool == .dimension)
                    onStatus?("Distance: " + formattedLength(length(sub(position,vec(first)))));clearDrawing();return
                }
                if (tool == .rectangle || tool == .rotatedRectangle) && rotatedRectangle {
                    if points.count<2 { points=[vec(first),position];onStatus?("Rotated rectangle: choose perpendicular width.");return }
                    do { append(try rectangleFace(points[0],points[1],position));clearDrawing() } catch { onStatus?(error.localizedDescription) };return
                }
                do { append(try makeEntity(vec(first),position));clearDrawing() } catch { onStatus?(error.localizedDescription) }
            } else { beginDrawing(at:position);onStatus?(tool == .circle ? "Choose radius or enter a length." : "Choose next point or enter dimensions.") }
            return
        }
        switch tool {
        case .select:
            if event.clickCount>1,let entity,entity.metadata?.groupID != nil {
                choose(entity.id);enterGroupEditing();return
            }
            if event.modifierFlags.contains(.shift) { if let entity { var ids=selectedIDs;if ids.contains(entity.id) { ids.subtract(document.effectiveSelection([entity.id],editingGroupID:editingGroupID)) } else { ids.formUnion(document.effectiveSelection([entity.id],editingGroupID:editingGroupID)) };chooseSet(ids) } }
            else if let entity { choose(entity.id) } else { choose(nil);boxSelecting=true;selectionBeforeBox=[] }
            if event.modifierFlags.contains(.shift),entity == nil { boxSelecting=true;selectionBeforeBox=selectedIDs }
        case .paint,.erase:
            guard let entity,entity.isEditable(in:document) else { onStatus?("Object is locked or hidden.");return }
            var changed=document
            let ids=document.effectiveSelection([entity.id],editingGroupID:editingGroupID)
            if tool == .erase { changed.entities.removeAll { ids.contains($0.id) && $0.isEditable(in:document) };chooseSet(selectedIDs.subtracting(ids)) }
            else { for i in changed.entities.indices where ids.contains(changed.entities[i].id) && changed.entities[i].isEditable(in:document) { changed.entities[i].colorHex=paintColor;changed.entities[i].surface=nil } }
            commit(changed)
        case .followMe: performSweepAlongSelectedPath()
        case .pushPull,.move,.rotate,.scale,.offset:
            guard let entity,entity.isEditable(in:document) else { onStatus?("Select an unlocked object.");return }
            if !selectedIDs.contains(entity.id) { choose(entity.id) }
            dragEntity=entity;dragDocument=document;dragGround=groundPoint(point);pickedProfile=nil
            if tool == .move {
                vertexDragPoint=nil
                if event.modifierFlags.contains(.control) {
                    let vertices:[Vec3]
                    if isFlatProfile(entity),let profile=try? GeometryTools.worldProfile(of:entity) {vertices=profile.outer+profile.holes.flatMap{$0}}
                    else if entity.kind == .mesh,let mesh=try? entity.triangulatedMesh(){vertices=mesh.vertices}
                    else {onStatus?("Vertex editing works on flat faces and editable meshes.");dragDocument=nil;dragEntity=nil;return}
                    let closest=vertices.min{a,b in let pa=projectPoint(scn(a)),pb=projectPoint(scn(b));return hypot(pa.x-point.x,pa.y-point.y)<hypot(pb.x-point.x,pb.y-point.y)}
                    guard let vertex=closest else{return}
                    let projected=projectPoint(scn(vertex))
                    guard hypot(projected.x-point.x,projected.y-point.y)<14 else {onStatus?("Control-drag within 14 pixels of a face or mesh vertex.");dragDocument=nil;dragEntity=nil;return}
                    vertexDragPoint=vertex
                    activePlane=makePlane(origin:vertex,normal:(try? GeometryTools.normal(of:entity)) ?? drawingPlane.n)
                    dragGround=groundPoint(point)
                }
                anchor=dragGround
            }
            if tool == .pushPull,let (_,hit)=entityHit(point) {
                let normal=(try? GeometryTools.normal(of:entity)) ?? Vec3(0,0,0)
                if length(normal)<0.5 || abs(dot(normalized(vec(hit.worldNormal)),normal))<0.99 {
                    pickedProfile=profileForPickedFace(entity,hit:hit)
                }
            }
            onStatus?("Drag to \(tool.rawValue), or enter a measurement. Shift selects multiple objects.")
        default:break
        }
    }
    private func append(_ source: SketchEntity) {
        var entity=source
        if let editingGroupID {var metadata=entity.metadata ?? EntityMetadata();metadata.groupID=editingGroupID;entity.metadata=metadata}
        if entity.kind == .line {
            do {
                let end=add(entity.origin,Vec3(entity.width,entity.height,entity.depth))
                let next=try GeometryTools.connectLine(document:document,start:entity.origin,end:end,tolerance:max(1e-7,min(snapStep*0.1,1e-5)),editingGroupID:editingGroupID)
                let previous=Set(document.entities.map(\.id));let added=next.entities.last(where:{!previous.contains($0.id)})
                commit(next);choose(added?.id)
            } catch {onStatus?(error.localizedDescription)}
        } else {var next=document;next.entities.append(entity);commit(next);choose(entity.id)}
    }
    func enterGroupEditing() {
        guard let id=selectedID,let entity=document.entities.first(where:{$0.id==id}),let member=entity.metadata?.groupID else {onStatus?("Select a grouped object first.");return}
        let groups=document.editor?.groups ?? []
        var candidate=member,seen=Set<UUID>()
        while let parent=groups.first(where:{$0.id==candidate})?.parentID,parent != editingGroupID,seen.insert(candidate).inserted {candidate=parent}
        guard candidate != editingGroupID else {onStatus?("Editing direct members of this group. Escape exits.");return}
        cancelOperation();editingGroupID=candidate;chooseSet([id]);onGroupEditingChange?(candidate)
        onStatus?("Editing group: \(groups.first(where:{$0.id==candidate})?.name ?? "Group"). Escape exits.")
    }
    func leaveGroupEditing() {
        cancelOperation()
        editingGroupID=document.editor?.groups.first(where:{$0.id==editingGroupID})?.parentID
        chooseSet(selectedIDs);onGroupEditingChange?(editingGroupID)
        onStatus?(editingGroupID == nil ? "Exited group editing." : "Editing parent group. Escape exits.")
    }
    func beginDrawing(at position:Vec3) {anchor=scn(position);points=[position];latestGround=nil}
    private func clearDrawing() { anchor=nil;points=[];activePlane=nil;latestGround=nil;preview.childNodes.forEach{$0.removeFromParentNode()} }
    private func rectangleFace(_ a: Vec3,_ b: Vec3,_ third: Vec3) throws -> SketchEntity {
        let direction=normalized(sub(b,a)),plane=activePlane ?? drawingPlane
        let perpendicular=normalized(cross(plane.n,direction)),amount=dot(sub(third,b),perpendicular)
        let c=add(b,mul(perpendicular,amount)),d=add(a,mul(perpendicular,amount))
        var corners=[a,b,c,d]
        if dot(cross(sub(b,a),sub(c,a)),plane.n)<0{corners.reverse()}
        return try GeometryTools.face(points:corners,name:"Rotated rectangle",colorHex:"#E7DCC8")
    }
    private func makeEntity(_ a: Vec3,_ b: Vec3) throws -> SketchEntity {
        let plane=activePlane ?? drawingPlane,delta=sub(b,a)
        if tool == .line { return SketchEntity(name:"Line",kind:.line,origin:a,width:delta.x,depth:delta.z,height:delta.y,colorHex:"#353B3C") }
        if tool == .circle {
            let radius=length(delta)
            guard radius>1e-7 else { throw GeometryIOError.invalid("Circle radius must be positive.") }
            if abs(plane.n.y)>0.999 { return SketchEntity(name:"Circle",kind:.circle,origin:a,width:radius*2,depth:radius*2) }
            return try GeometryTools.face(points:(0..<48).map { i in let angle=Double(i)*2 * .pi/48;return add(a,add(mul(plane.u,cos(angle)*radius),mul(plane.v,sin(angle)*radius))) },name:"Circle")
        }
        let du=dot(delta,plane.u),dv=dot(delta,plane.v)
        guard abs(du)>1e-7,abs(dv)>1e-7 else { throw GeometryIOError.invalid("Rectangle needs nonzero width and depth.") }
        if abs(plane.n.y)>0.999,abs(plane.u.x)>0.999 { return SketchEntity(name:"Rectangle",kind:.rectangle,origin:mul(add(a,b),0.5),width:abs(delta.x),depth:abs(delta.z)) }
        return try GeometryTools.face(points:[a,add(a,mul(plane.u,du)),b,add(a,mul(plane.v,dv))],name:"Rectangle")
    }
    private func finishProfile() {
        guard points.count>=3 else { onStatus?("A face needs at least three corners.");return }
        do {
            var outline=points
            if outline.count>2,dot(cross(sub(outline[1],outline[0]),sub(outline[2],outline[0])),(activePlane ?? drawingPlane).n)<0{outline.reverse()}
            append(try GeometryTools.face(points:outline,name:tool == .freehand ? "Freehand face" : "Polygon"));clearDrawing()
        }
        catch { onStatus?(error.localizedDescription) }
    }
    override func mouseMoved(with event: NSEvent) {
        let point=convert(event.locationInWindow,from:nil)
        guard let end=drawingPoint(point,shift:event.modifierFlags.contains(.shift)) else { return }
        inferenceMarker.childNodes.forEach{$0.removeFromParentNode()}
        if !inferenceLabel.isEmpty {
            let dot=SCNNode(geometry:SCNSphere(radius:Double(distance)/450));dot.position=scn(end);dot.geometry?.firstMaterial=material("#D94C32");dot.categoryBitMask=4;inferenceMarker.addChildNode(dot)
        }
        guard anchor != nil else { if !inferenceLabel.isEmpty { onStatus?(inferenceLabel) };return }
        updateDrawingPreview(to:end)
    }
    func updateDrawingPreview(to end:Vec3) {
        guard let first=anchor else{return}
        latestGround=scn(end);preview.childNodes.forEach{$0.removeFromParentNode()}
        if tool == .polygon || tool == .freehand || tool == .arc || rotatedRectangle {
            let route=points+[end];var pairs:[SCNVector3]=[]
            for i in 1..<route.count { pairs += [scn(route[i-1]),scn(route[i])] }
            preview.addChildNode(lineNode(pairs,color:.systemOrange))
        } else if tool == .tapeMeasure || tool == .dimension { preview.addChildNode(lineNode([first,scn(end)],color:.systemOrange)) }
        else if let shape=try? makeEntity(vec(first),end) { preview.addChildNode(entityNode(shape,temporary:true)) }
        onStatus?(formattedLength(length(sub(end,vec(first)))) + " · " + inferenceLabel + " · Click to finish")
    }
    override func mouseDragged(with event: NSEvent) {
        let point=convert(event.locationInWindow,from:nil)
        if cameraGesture { manipulateCamera(point,pan:tool == .pan || event.modifierFlags.contains(.shift));return }
        if tool == .freehand {
            if let p=drawingPoint(point),let last=points.last,length(sub(p,last))>Double(distance)/400 { points.append(p);mouseMoved(with:event) };return
        }
        if boxSelecting {
            let rect=CGRect(x:min(dragStart.x,point.x),y:min(dragStart.y,point.y),width:abs(point.x-dragStart.x),height:abs(point.y-dragStart.y))
            selectionBox.path=CGPath(rect:rect,transform:nil);return
        }
        guard let original=dragEntity,let before=dragDocument else { return }
        do {
            var next=before
            switch tool {
            case .pushPull:
                let base=pickedProfile != nil ? 0 : (original.kind == .mesh ? (original.profileExtrusion ?? 0) : original.height)
                let value=base+Double(point.y-dragStart.y)*Double(distance)/600
                if let face=pickedProfile {
                    var extruded=try GeometryTools.extrude(entity:face,distance:value);extruded.name="Face extrusion";next.entities.append(extruded)
                } else if let index=next.entities.firstIndex(where:{$0.id==original.id}) {
                    next.entities[index]=try GeometryTools.extrude(entity:original,distance:value)
                }
            case .move:
                guard let start=dragGround,let end=groundPoint(point) else {return}
                let delta=sub(vec(end),vec(start))
                if let vertex=vertexDragPoint {next=try movedVertex(in:before,from:vertex,delta:delta)}
                else {next=try EditorOperations.translate(document:before,ids:selectedIDs,delta:delta,editingGroupID:editingGroupID)}
            case .rotate: next=try EditorOperations.rotate(document:before,ids:selectedIDs,radians:Double(point.x-dragStart.x) * .pi/180,editingGroupID:editingGroupID)
            case .scale:
                let f=max(0.001,1+Double(point.x-dragStart.x)/150)
                next=try EditorOperations.scale(document:before,ids:selectedIDs,factors:Vec3(f,f,f),editingGroupID:editingGroupID)
            case .offset:
                if let index=next.entities.firstIndex(where:{$0.id==original.id}) { next.entities[index]=try GeometryTools.offset(entity:original,distance:Double(point.x-dragStart.x)*Double(distance)/600) }
            default:return
            }
            try next.validate();document=next
        } catch { onStatus?(error.localizedDescription) }
    }
    override func mouseUp(with event: NSEvent) {
        if tool == .freehand,points.count>=3 { finishProfile() }
        if boxSelecting {
            let point=convert(event.locationInWindow,from:nil)
            let rect=NSRect(x:min(point.x,dragStart.x),y:min(point.y,dragStart.y),width:abs(point.x-dragStart.x),height:abs(point.y-dragStart.y))
            if rect.width>3,rect.height>3 {
                chooseSet(selectionBeforeBox.union(boxSelectionIDs(in:rect)))
            }
            boxSelecting=false;selectionBox.path=nil
        }
        if let before=dragDocument,before != document {
            let old=Set(before.entities.map(\.id))
            let created=pickedProfile == nil ? nil : document.entities.last(where:{!old.contains($0.id)})?.id
            onDocumentChange?(document)
            if let created {choose(created);pickedProfile=nil}
        }
        dragEntity=nil;dragDocument=nil;dragGround=nil;cameraGesture=false
        if tool == .move {anchor=nil;activePlane=nil;vertexDragPoint=nil;preview.childNodes.forEach{$0.removeFromParentNode()}}
        updateCursor()
    }
    func boxSelectionIDs(in rect:NSRect)->Set<UUID> {
        var ids=Set<UUID>()
        for entity in document.entities where entity.isVisible(in:document) {
            if editingGroupID != nil,document.effectiveSelection([entity.id],editingGroupID:editingGroupID).isEmpty {continue}
            guard let mesh=try? entity.triangulatedMesh() else { continue }
            if mesh.vertices.contains(where:{v in
                if let section=document.presentation?.section,section.enabled,let signed=try? section.signedDistance(to:v),signed>0{return false}
                let p=projectPoint(scn(v))
                return p.z>=0 && p.z<=1 && rect.contains(NSPoint(x:p.x,y:p.y))
            }) {ids.insert(entity.id)}
        }
        return ids
    }
    private func isFlatProfile(_ entity: SketchEntity) -> Bool {
        if entity.profile != nil{return abs(entity.profileExtrusion ?? 0)<1e-8}
        return (entity.kind == .rectangle || entity.kind == .circle) && abs(entity.height)<1e-8
    }
    private func movedVertex(in original: ModelDocument,from vertex: Vec3,delta: Vec3) throws -> ModelDocument {
        var next=original,changed=false
        for i in next.entities.indices {
            let source=original.entities[i]
            guard source.isEditable(in:original),isFlatProfile(source),!original.effectiveSelection([source.id],editingGroupID:editingGroupID).isEmpty,let profile=try? GeometryTools.worldProfile(of:source) else{continue}
            let tolerance=max(1e-8,min(snapStep*0.1,1e-6))
            let all=profile.outer+profile.holes.flatMap{$0}
            guard all.contains(where:{length(sub($0,vertex))<tolerance}) else{continue}
            func moved(_ points:[Vec3])->[Vec3]{points.map{length(sub($0,vertex))<tolerance ? add($0,delta):$0}}
            var replacement=try GeometryTools.face(points:moved(profile.outer),holes:profile.holes.map(moved),name:source.name,colorHex:source.colorHex)
            replacement.id=source.id;replacement.metadata=source.metadata;replacement.surface=source.surface;replacement.surface?.faceOverrides=[]
            next.entities[i]=replacement;changed=true
        }
        let meshIDs=Set(original.entities.filter{$0.kind == .mesh && selectedIDs.contains($0.id) && $0.isEditable(in:original)}.map(\.id))
        if !meshIDs.isEmpty {
            next=try EditorOperations.moveVertex(document:next,ids:meshIDs,at:vertex,delta:delta,tolerance:max(1e-8,min(snapStep*0.1,1e-6)),editingGroupID:editingGroupID)
            changed=true
        }
        guard changed else{throw GeometryIOError.unsupported("Select a vertex belonging to a flat profiled face or editable mesh.")}
        try next.validate();return next
    }
    func performOffset(_ amount: Double) {
        do { var next=document;for i in next.entities.indices where selectedIDs.contains(next.entities[i].id) && next.entities[i].isEditable(in:document) { next.entities[i]=try GeometryTools.offset(entity:next.entities[i],distance:amount) };commit(next) }
        catch {onStatus?(error.localizedDescription)}
    }
    func performSweepAlongSelectedPath() {
        let context=document.effectiveSelection(selectedIDs,editingGroupID:editingGroupID)
        let selection=document.entities.filter{selectedIDs.contains($0.id) && context.contains($0.id) && $0.isEditable(in:document) && $0.isVisible(in:document)}
        guard selection.count==selectedIDs.count else {onStatus?("Every sweep source must be visible, unlocked, and inside the active group.");return}
        let profiles=selection.filter{(try? GeometryTools.worldProfile(of:$0)) != nil}
        guard profiles.count==1,let profile=profiles.first else {onStatus?("Follow Me: select exactly one face and every line/wire segment in one open path.");return}
        let paths=selection.filter{$0.id != profile.id}
        do {
            var route=try GeometryPath.orderedOpenPath(entities:paths)
            let outline=try GeometryTools.worldProfile(of:profile).outer
            let center=mul(outline.reduce(Vec3(0,0,0),add),1/Double(outline.count))
            let normal=try GeometryTools.normal(of:profile)
            let firstCompatible=abs(dot(normal,normalized(sub(route[1],route[0]))))>0.999
            let lastCompatible=abs(dot(normal,normalized(sub(route[route.count-2],route.last!))))>0.999
            if lastCompatible && (!firstCompatible || length(sub(route.last!,center))<length(sub(route[0],center))) {route.reverse()}
            let swept=try GeometryTools.sweep(profile:profile,path:route)
            append(swept);onStatus?("Follow Me sweep created using every selected path segment; sources retained.")
        } catch {onStatus?(error.localizedDescription)}
    }

    override func rightMouseDown(with event: NSEvent) { previousMouse = convert(event.locationInWindow, from: nil); NSCursor.closedHand.set() }
    override func rightMouseDragged(with event: NSEvent) { manipulateCamera(convert(event.locationInWindow, from: nil), pan: event.modifierFlags.contains(.shift)) }
    override func rightMouseUp(with event: NSEvent) { updateCursor() }
    override func otherMouseDown(with event: NSEvent) { rightMouseDown(with: event) }
    override func otherMouseDragged(with event: NSEvent) { rightMouseDragged(with: event) }
    override func otherMouseUp(with event: NSEvent) { rightMouseUp(with: event) }

    private func manipulateCamera(_ point: NSPoint, pan: Bool) {
        guard point.x.isFinite,point.y.isFinite else{return}
        let dx = CGFloat(point.x - previousMouse.x)
        let dy = CGFloat(point.y - previousMouse.y)
        previousMouse = point
        var nextTarget=target,nextYaw=yaw,nextPitch=pitch
        if pan {
            let amount = distance / 650
            nextTarget.x -= (cos(yaw) * dx + sin(yaw) * dy * sin(pitch)) * amount
            nextTarget.z += (sin(yaw) * dx - cos(yaw) * dy * sin(pitch)) * amount
            nextTarget.y -= dy * cos(pitch) * amount
        } else {
            // Add the gesture to a bounded equivalent phase. Small pointer
            // deltas otherwise vanish when a saved finite angle is very large.
            nextYaw = atan2(sin(yaw),cos(yaw)) - dx * 0.008
            if dy != 0 {nextPitch = min(.pi / 2 - 0.001, max(0.035, pitch - dy * 0.008))}
        }
        let candidate=CameraState(target:vec(nextTarget),yaw:Double(nextYaw),pitch:Double(nextPitch),distance:Double(distance),orthographic:cameraNode.camera?.usesOrthographicProjection ?? false)
        guard (try? candidate.validate()) != nil else {
            onStatus?("Camera movement exceeds the supported camera range. The current view was preserved.")
            return
        }
        target=nextTarget;yaw=nextYaw;pitch=nextPitch
        updateCamera()
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY.isFinite else { return }
        distance = min(10_000_000, max(0.001, distance * exp(CGFloat(-event.scrollingDeltaY) * 0.025)))
        updateCamera()
    }

    override func magnify(with event: NSEvent) {
        guard event.magnification.isFinite else { return }
        distance = min(10_000_000, max(0.001, distance * CGFloat(1 - event.magnification)))
        updateCamera()
    }

    static let geometryPasteboardType=NSPasteboard.PasteboardType("com.sketchmake.geometry+json")
    var geometryPasteboard:GeometryPasteboard = NSPasteboard.general

    @objc func copy(_ sender: Any?) {
        do {
            let payload=try ClipboardOperations.copy(document:dragDocument ?? document,ids:selectedIDs,editingGroupID:editingGroupID)
            guard !payload.entities.isEmpty else {onStatus?("Select geometry to copy.");return}
            try writeGeometryClipboard(payload)
            onStatus?("Copied \(payload.entities.count) objects.")
        } catch {onStatus?(error.localizedDescription)}
    }
    @objc func cut(_ sender: Any?) {
        do {
            let source=dragDocument ?? document
            let payload=try ClipboardOperations.copy(document:source,ids:selectedIDs,editingGroupID:editingGroupID,editableOnly:true)
            guard !payload.entities.isEmpty else {onStatus?("No unlocked selected objects to cut.");return}
            try writeGeometryClipboard(payload)
            let ids=Set(payload.entities.map(\.id))
            var next=source;next.entities.removeAll{ids.contains($0.id)}
            cancelOperation();commit(next);chooseSet(selectedIDs.subtracting(ids))
            onStatus?("Cut \(ids.count) unlocked objects.")
        } catch {onStatus?(error.localizedDescription)}
    }
    @objc func paste(_ sender: Any?) {
        do {
            let data=geometryPasteboard.data(forType:Self.geometryPasteboardType) ?? geometryPasteboard.string(forType:.string)?.data(using:.utf8)
            guard let data,!data.isEmpty,data.count<=64*1024*1024 else {throw GeometryIOError.invalid("Clipboard does not contain supported geometry JSON (64 MB maximum).")}
            let payload=try JSONDecoder().decode(ModelDocument.self,from:data)
            guard !payload.entities.isEmpty else {throw GeometryIOError.invalid("Clipboard geometry is empty.")}
            let before=Set(document.entities.map(\.id))
            let next=try ClipboardOperations.paste(payload:payload,into:dragDocument ?? document,editingGroupID:editingGroupID)
            cancelOperation();commit(next);chooseSet(Set(next.entities.map(\.id)).subtracting(before))
            onStatus?("Pasted \(payload.entities.count) objects.")
        } catch {onStatus?(error.localizedDescription)}
    }
    override func selectAll(_ sender: Any?) {
        let context=document.effectiveSelection(Set(document.entities.map(\.id)),editingGroupID:editingGroupID)
        let visible=Set(document.entities.filter{$0.isVisible(in:document)}.map(\.id))
        // A visible member seeds its complete group, including its hidden members;
        // unrelated hidden objects remain unselected.
        chooseSet(context.intersection(visible))
    }
    private func writeGeometryClipboard(_ payload:ModelDocument) throws {
        let data=try JSONEncoder().encode(payload)
        guard data.count<=64*1024*1024,let text=String(data:data,encoding:.utf8) else {throw GeometryIOError.invalid("Copied geometry exceeds the 64 MB clipboard limit.")}
        guard geometryPasteboard.writeGeometry(data:data,text:text,type:Self.geometryPasteboardType) else {throw GeometryIOError.invalid("The clipboard could not store geometry.")}
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode==53 {
            if editingGroupID != nil,anchor == nil,dragDocument == nil {leaveGroupEditing()} else {cancelOperation()};return
        }
        if event.keyCode==36 || event.keyCode==76 { if tool == .polygon || tool == .freehand {finishProfile();return} }
        if let key=event.charactersIgnoringModifiers?.lowercased(),["x","y","z"].contains(key),event.modifierFlags.intersection([.command,.control,.option]).isEmpty {
            axisConstraint = axisConstraint==key ? nil : key;onStatus?(axisConstraint.map{"\($0.uppercased()) axis locked"} ?? "Axis lock released");return
        }
        if event.keyCode==51 || event.keyCode==117 {
            if !points.isEmpty { if points.count>1 {points.removeLast()} else {clearDrawing()};preview.childNodes.forEach{$0.removeFromParentNode()};return }
            var next=document;let ids=next.effectiveSelection(selectedIDs,editingGroupID:editingGroupID)
            next.entities.removeAll{ids.contains($0.id) && $0.isEditable(in:document)};commit(next);choose(nil);return
        }
        super.keyDown(with:event)
    }
    func cancelOperation() {
        clearDrawing();inferenceMarker.childNodes.forEach{$0.removeFromParentNode()}
        if let original=dragDocument {document=original}
        dragDocument=nil;dragEntity=nil;dragGround=nil;pickedProfile=nil;vertexDragPoint=nil;boxSelecting=false;selectionBox.path=nil;cameraGesture=false;axisConstraint=nil;shiftConstraint=nil;showToolHint()
    }
    /// Committed commands and external history changes end an in-flight edit;
    /// otherwise a later Escape could restore its obsolete document snapshot.
    func cancelEditingDrag() {
        if dragDocument != nil {cancelOperation()}
    }
    func applyMeasurement(_ text: String) {
        let components=text.split(separator:",",omittingEmptySubsequences:false)
        let values=components.compactMap{parseLength(String($0))}
        guard !values.isEmpty,values.count==components.count,values.count<=3,values.allSatisfy({$0.isFinite && abs($0)<10000}) else {onStatus?("Enter m, cm, mm or ft. Dimensions: 4, 3. Rotate: degrees. Scale: factor.");return}
        if let first=anchor {
            guard [.line,.rectangle,.rotatedRectangle,.circle,.tapeMeasure,.dimension].contains(tool) else {onStatus?("Finish this outline with Return or additional clicks.");return}
            let plane=activePlane ?? drawingPlane
            if tool == .tapeMeasure || tool == .dimension {
                let end=add(vec(first),mul(plane.u,values[0]));onMeasure?(vec(first),end,tool == .dimension);clearDrawing();return
            }
            if rotatedRectangle,points.count==2 {
                let direction=normalized(sub(points[1],points[0]))
                let third=add(points[1],mul(normalized(cross(plane.n,direction)),values[0]))
                do {append(try rectangleFace(points[0],points[1],third));clearDrawing()} catch {onStatus?(error.localizedDescription)};return
            }
            var end=add(vec(first),add(mul(plane.u,values[0]),mul(plane.v,tool == .circle ? 0 : (values.count>1 ? values[1] : values[0]))))
            if tool == .line && values.count==1 {
                let previewDirection=latestGround.map{sub(vec($0),vec(first))}
                let direction=previewDirection.flatMap{length($0)>1e-12 ? normalized($0):nil} ?? plane.u
                end=add(vec(first),mul(direction,values[0]))
            }
            do {append(try makeEntity(vec(first),end));clearDrawing()} catch {onStatus?(error.localizedDescription)};return
        }
        do {
            switch tool {
            case .offset:performOffset(values[0]);return
            case .rotate:commit(try EditorOperations.rotate(document:document,ids:selectedIDs,radians:values[0] * .pi/180,editingGroupID:editingGroupID));return
            case .scale:commit(try EditorOperations.scale(document:document,ids:selectedIDs,factors:Vec3(values[0],values.count>1 ? values[1]:values[0],values.count>2 ? values[2]:values[0]),editingGroupID:editingGroupID));return
            case .move:commit(try EditorOperations.translate(document:document,ids:selectedIDs,delta:Vec3(values[0],values.count>1 ? values[1]:0,values.count>2 ? values[2]:0),editingGroupID:editingGroupID));return
            default:break
            }
            guard let id=selectedID,let index=document.entities.firstIndex(where:{$0.id==id}),document.entities[index].isEditable(in:document) else {onStatus?("Select an unlocked object first.");return}
            var next=document,newExtrusionID:UUID?
            if tool == .pushPull {
                if let pickedProfile {var shape=try GeometryTools.extrude(entity:pickedProfile,distance:values[0]);shape.name="Face extrusion";next.entities.append(shape);newExtrusionID=shape.id}
                else {next.entities[index]=try GeometryTools.extrude(entity:next.entities[index],distance:values[0])}
            } else if next.entities[index].kind == .mesh {
                onStatus?("Use Scale for mesh dimensions, or Push/Pull for profiled faces.");return
            } else if next.entities[index].kind == .line {
                next.entities[index].width=values[0]
                if values.count>1 {next.entities[index].depth=values[1]}
                if values.count>2 {next.entities[index].height=values[2]}
            } else {
                next.entities[index].width=max(0.000001,abs(values[0]))
                if values.count>1 {next.entities[index].depth=max(0.000001,abs(values[1]))}
                else if next.entities[index].kind == .circle {next.entities[index].depth=max(0.000001,abs(values[0]))}
                if values.count>2 {next.entities[index].height=max(0,values[2])}
            }
            try next.validate()
            commit(next)
            if let newExtrusionID {choose(newExtrusionID);pickedProfile=nil}
            onStatus?("Dimensions applied.")
        } catch {onStatus?(error.localizedDescription)}
    }
    private func formattedLength(_ value: Double) -> String {
        let editorUnits=document.editor?.units ?? "m"
        let units=["m":"meters","mm":"millimeters","cm":"centimeters","ft":"feet","in":"inches"][editorUnits] ?? document.presentation?.units ?? "meters"
        let factors:[String:(Double,String)]=["millimeters":(1000,"mm"),"centimeters":(100,"cm"),"feet":(1/0.3048,"ft"),"inches":(1/0.0254,"in")]
        let conversion=factors[units] ?? (1,"m")
        return String(format:"%.4f %@",value*conversion.0,conversion.1)
    }
    private func parseLength(_ text: String) -> Double? {
        var value=text.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        for (suffix,scale) in [("mm",0.001),("cm",0.01),("ft",0.3048),("in",0.0254),("'",0.3048),("\"",0.0254),("m",1.0)] where value.hasSuffix(suffix) {value.removeLast(suffix.count);return Double(value.trimmingCharacters(in:.whitespaces)).map{$0*scale}}
        return Double(value)
    }
    func captureCamera() -> CameraState { CameraState(target:vec(target),yaw:Double(yaw),pitch:Double(pitch),distance:Double(distance),orthographic:cameraNode.camera?.usesOrthographicProjection ?? false) }
    func applyCamera(_ state: CameraState) {
        guard (try? state.validate()) != nil else{return}
        target=scn(state.target);yaw=CGFloat(state.yaw);pitch=CGFloat(state.pitch);distance=CGFloat(state.distance);setOrthographic(state.orthographic);updateCamera()
    }
    func setOrthographic(_ enabled: Bool) {cameraNode.camera?.usesOrthographicProjection=enabled;cameraNode.camera?.orthographicScale=Double(distance)*0.45;needsDisplay=true}
    private func showToolHint() {
        let hints:[ModelingTool:String]=[
            .select:"Select · Shift-click toggles · Drag empty space for box selection",
            .line:"Line · Click endpoints · X/Y/Z locks axis · Shift holds inference",
            .rectangle:"Rectangle · Click two corners · Control-click first point for rotated 3-point rectangle",
            .rotatedRectangle:"Rotated rectangle · Click corner, baseline end, then perpendicular width",
            .circle:"Circle · Click center and radius · Numeric input uses radius",
            .polygon:"Polygon · Click corners · Return or double-click closes face",
            .arc:"Arc · Click center, start, end · Creates a tessellated wire path",
            .freehand:"Freehand · Drag a closed outline · Release creates face",
            .pushPull:"Push/Pull · Drag face normal distance or enter signed height",
            .move:"Move · Drag selection or enter X,Y,Z offsets",
            .rotate:"Rotate · Drag horizontally or enter degrees about model Y",
            .scale:"Scale · Drag horizontally or enter X,Y,Z factors",
            .offset:"Offset · Click face, drag or enter distance; positive expands",
            .followMe:"Follow Me · Shift-select a profile and connected wire, then click",
            .paint:"Paint · Choose material, then click an unlocked object",
            .erase:"Erase · Click an unlocked object or press Delete",
            .orbit:"Orbit · Drag · Shift-drag pans · Scroll zooms",
            .pan:"Pan · Drag to move view · Scroll zooms",
            .tapeMeasure:"Tape Measure · Click two points to measure and add a guide",
            .dimension:"Dimension · Click two endpoints to add a dimension",
            .text:"Text · Click a point to place a label",
            .section:"Section · Click a surface to place its section plane",
            .axes:"Axes · Click a point to relocate drawing axes"]
        onStatus?(hints[tool] ?? tool.rawValue)
    }
}
