import AppKit
import SceneKit
import GardenStudioCore

/// Applies view-only styles and presentation overlays without changing model geometry.
/// Reuse one instance per viewport and call after rebuilding its model nodes.
final class PresentationRenderer {
    static let overlayRootName = "gardenstudio.presentation"
    private let baselines = NSMapTable<SCNMaterial, PresentationMaterialBaseline>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    func resetBaselines() { baselines.removeAllObjects() }

    func update(scene: SCNScene, presentation: PresentationState) {
        scene.rootNode.childNode(withName: Self.overlayRootName, recursively: false)?.removeFromParentNode()
        guard (try? presentation.validate()) != nil else { return }
        let overlay = SCNNode()
        overlay.name = Self.overlayRootName
        overlay.categoryBitMask = 4
        scene.rootNode.addChildNode(overlay)
        for guide in presentation.guides { overlay.addChildNode(dashedGuide(guide)) }
        for annotation in presentation.annotations {
            let parent = SCNNode(); parent.name = "annotation.\(annotation.id.uuidString)"; parent.categoryBitMask = 4
            if annotation.kind == "dimension", let end = annotation.end {
                let a = annotation.start, b = end
                let distance = hypot(hypot(b.x - a.x, b.y - a.y), b.z - a.z)
                let tick = max(0.035, min(0.15, distance * 0.025))
                let dx = b.x - a.x, dz = b.z - a.z
                let horizontalLength = hypot(dx, dz)
                let side = horizontalLength > 1e-8 ? Vec3(-dz / horizontalLength * tick, 0, dx / horizontalLength * tick) : Vec3(tick, 0, 0)
                let vertices = [a, b,
                    Vec3(a.x - side.x, a.y - side.y, a.z - side.z), Vec3(a.x + side.x, a.y + side.y, a.z + side.z),
                    Vec3(b.x - side.x, b.y - side.y, b.z - side.z), Vec3(b.x + side.x, b.y + side.y, b.z + side.z)]
                parent.addChildNode(lineNode(vertices, color: .darkGray))
                let text = annotation.text.isEmpty ? presentation.formattedLength(distance) : annotation.text
                let label = textNode(text, threeDimensional: false)
                label.position = vector(Vec3((a.x+b.x)/2, (a.y+b.y)/2 + tick*1.7, (a.z+b.z)/2))
                parent.addChildNode(label)
            } else {
                let label = textNode(annotation.text, threeDimensional: annotation.kind == "text3D")
                label.position = vector(annotation.start)
                parent.addChildNode(label)
                if let end = annotation.end, annotation.kind == "text" { parent.addChildNode(lineNode([annotation.start, end], color: .darkGray)) }
            }
            overlay.addChildNode(parent)
        }
        let plane = presentation.section.flatMap { $0.enabled ? try? $0.normalized() : nil }
        scene.rootNode.enumerateChildNodes { [weak self] node, _ in
            guard let self else { return }
            if let light = node.light, light.type == .directional {
                light.castsShadow = presentation.shadows
                light.shadowColor = NSColor(white: 0, alpha: 0.32)
                light.shadowRadius = 4
                light.shadowSampleCount = 16
                light.shadowMapSize = CGSize(width: 2048, height: 2048)
                light.maximumShadowDistance = 150
            }
            guard self.isModelGeometry(node), let geometry = node.geometry else { return }
            for material in geometry.materials {
                let baseline: PresentationMaterialBaseline
                if let previous = self.baselines.object(forKey: material) { baseline = previous }
                else { baseline = PresentationMaterialBaseline(material); self.baselines.setObject(baseline, forKey: material) }
                baseline.restore(material)
                switch presentation.style {
                case "monochrome": material.diffuse.contents = NSColor(calibratedWhite: 0.91, alpha: 1)
                case "wireframe": material.fillMode = .lines; material.lightingModel = .constant
                case "xray": material.transparency = 0.28; material.writesToDepthBuffer = false; material.transparencyMode = .aOne
                default: break
                }
                if let plane {
                    var modifiers = baseline.shaderModifiers ?? [:]
                    // Model-space vertices are transformed with SceneKit's current node
                    // model matrix. The interpolated world position makes the same cut
                    // plane apply correctly to translated/rotated/scaled child nodes.
                    modifiers[.geometry] = """
                    #pragma varyings
                    float3 sketchWorldPosition;
                    #pragma body
                    out.sketchWorldPosition = (scn_node.modelTransform * _geometry.position).xyz;
                    """
                    modifiers[.fragment] = """
                    #pragma arguments
                    float4 sketchSectionPlane;
                    #pragma body
                    if (dot(in.sketchWorldPosition, sketchSectionPlane.xyz) + sketchSectionPlane.w > 0.0) { discard_fragment(); }
                    """
                    material.shaderModifiers = modifiers
                    let n = plane.normal, p = plane.point
                    material.setValue(NSValue(scnVector4: SCNVector4(CGFloat(n.x), CGFloat(n.y), CGFloat(n.z), CGFloat(-(n.x*p.x+n.y*p.y+n.z*p.z)))), forKey: "sketchSectionPlane")
                }
            }
        }
    }

    private func isModelGeometry(_ node: SCNNode) -> Bool {
        guard node.geometry != nil else { return false }
        var candidate: SCNNode? = node
        while let current = candidate {
            if current.name == Self.overlayRootName { return false }
            if let name = current.name, UUID(uuidString: name) != nil { return true }
            candidate = current.parent
        }
        return node.categoryBitMask == 2
    }

    private func dashedGuide(_ guide: GuideLine) -> SCNNode {
        let a = guide.start, b = guide.end
        let distance = hypot(hypot(b.x - a.x, b.y - a.y), b.z - a.z)
        let steps = max(1, min(500, Int(min(500, distance / 0.15))))
        var vertices: [Vec3] = []
        for step in 0..<steps {
            let from = Double(step) / Double(steps), to = (Double(step) + 0.55) / Double(steps)
            vertices.append(Vec3(a.x + (b.x-a.x)*from, a.y + (b.y-a.y)*from, a.z + (b.z-a.z)*from))
            vertices.append(Vec3(a.x + (b.x-a.x)*to, a.y + (b.y-a.y)*to, a.z + (b.z-a.z)*to))
        }
        let node = lineNode(vertices, color: NSColor(calibratedRed: 0.22, green: 0.48, blue: 0.72, alpha: 1))
        node.name = "guide.\(guide.id.uuidString)"
        return node
    }

    private func lineNode(_ vertices: [Vec3], color: NSColor) -> SCNNode {
        let source = SCNGeometrySource(vertices: vertices.map(vector))
        let indices = (0..<vertices.count).map(Int32.init)
        let geometry = SCNGeometry(sources: [source], elements: [SCNGeometryElement(indices: indices, primitiveType: .line)])
        let material = SCNMaterial(); material.diffuse.contents = color; material.lightingModel = .constant; material.writesToDepthBuffer = false
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry); node.categoryBitMask = 4; node.renderingOrder = 10
        return node
    }

    private func textNode(_ text: String, threeDimensional: Bool) -> SCNNode {
        let geometry = SCNText(string: text, extrusionDepth: threeDimensional ? 0.8 : 0)
        geometry.font = NSFont.systemFont(ofSize: 10, weight: threeDimensional ? .semibold : .medium)
        geometry.flatness = 0.25
        let material = SCNMaterial(); material.diffuse.contents = NSColor(calibratedWhite: 0.13, alpha: 1)
        material.lightingModel = threeDimensional ? .lambert : .constant
        material.isDoubleSided = true
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry); node.categoryBitMask = 4
        let scale: CGFloat = threeDimensional ? 0.04 : 0.018
        node.scale = SCNVector3(scale, scale, scale)
        if !threeDimensional {
            let billboard = SCNBillboardConstraint(); billboard.freeAxes = .all; node.constraints = [billboard]
            let bounds = geometry.boundingBox
            node.pivot = SCNMatrix4MakeTranslation((bounds.max.x + bounds.min.x)/2, bounds.min.y, 0)
            node.renderingOrder = 11
        }
        return node
    }
    private func vector(_ p: Vec3) -> SCNVector3 { SCNVector3(CGFloat(p.x), CGFloat(p.y), CGFloat(p.z)) }
}

private final class PresentationMaterialBaseline: NSObject {
    let diffuse: Any?
    let transparency: CGFloat
    let writesDepth: Bool
    let lightingModel: SCNMaterial.LightingModel
    let fillMode: SCNFillMode
    let transparencyMode: SCNTransparencyMode
    let shaderModifiers: [SCNShaderModifierEntryPoint: String]?
    init(_ material: SCNMaterial) {
        diffuse = material.diffuse.contents; transparency = material.transparency; writesDepth = material.writesToDepthBuffer
        lightingModel = material.lightingModel; fillMode = material.fillMode; transparencyMode = material.transparencyMode
        shaderModifiers = material.shaderModifiers
    }
    func restore(_ material: SCNMaterial) {
        material.diffuse.contents = diffuse; material.transparency = transparency; material.writesToDepthBuffer = writesDepth
        material.lightingModel = lightingModel; material.fillMode = fillMode; material.transparencyMode = transparencyMode
        material.shaderModifiers = shaderModifiers
    }
}
