import AppKit
import Foundation
import CryptoKit
import SceneKit
import GardenStudioCore

/// Geometry interchange for SketchUp's COLLADA 1.4.1 importer/exporter.
/// Geometry is flattened to static triangle/line meshes in meters, Y up.
/// Diffuse PNG/JPEG images and face colors are retained; imported UV layouts are regenerated.
public enum ColladaFormat {
    public static func read(url: URL) throws -> ModelDocument {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 64 * 1024 * 1024 else {
            throw GeometryIOError.invalid("COLLADA files must be smaller than 64 MB.")
        }
        let data = try Data(contentsOf: url)
        // Preflight before invoking a native importer: no entity expansion, network
        // resources, scripts or deforming rigs are admitted. Texture files are read
        // by the bounded local loader, then stripped before SceneKit sees XML.
        guard let xmlText = String(data: data, encoding: .utf8), !xmlText.uppercased().contains("<!DOCTYPE"), !xmlText.uppercased().contains("<!ENTITY") else { throw GeometryIOError.unsupported("XML DTD and entity declarations are not supported.") }
        let gate = ColladaPreflight()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = gate
        guard parser.parse(), gate.error == nil, gate.rootIsCollada else {
            throw gate.error ?? GeometryIOError.invalid("This is not a valid COLLADA document.")
        }
        let appearance = try ColladaAppearance.prepare(data: data, baseURL: url)
        guard let source = SCNSceneSource(data: appearance.data, options: [.checkConsistency: true]) else {
            throw GeometryIOError.invalid("SceneKit could not read this COLLADA document.")
        }
        let scene = try source.scene(options: [
            .checkConsistency: true,
            .convertToYUp: true,
            .convertUnitsToMeters: NSNumber(value: 1.0),
            .preserveOriginalTopology: false,
            .animationImportPolicy: SCNSceneSource.AnimationImportPolicy.doNotPlay,
            .assetDirectoryURLs: [],
            .overrideAssetURLs: true
        ])
        var entities: [GardenEntity] = []
        var totalVertices = 0
        func visit(_ node: SCNNode) throws {
            if let geometry = node.geometry {
                let firstEntity = entities.count
                guard let source = geometry.sources(for: .vertex).first else {
                    throw GeometryIOError.unsupported("A COLLADA geometry has no supported vertex positions.")
                }
                let localPositions = try positions(source)
                let localUV = try geometry.sources(for: .texcoord).first.map { try coordinates($0) }
                if let localUV, localUV.count != localPositions.count {
                    throw GeometryIOError.invalid("COLLADA texture coordinates do not match its vertices.")
                }
                guard localPositions.count <= 250_000 else { throw GeometryIOError.invalid("A COLLADA mesh exceeds 250,000 vertices.") }
                let transform = node.worldTransform
                let determinant = transform.m11 * (transform.m22 * transform.m33 - transform.m23 * transform.m32)
                    - transform.m12 * (transform.m21 * transform.m33 - transform.m23 * transform.m31)
                    + transform.m13 * (transform.m21 * transform.m32 - transform.m22 * transform.m31)
                for (elementIndex, element) in geometry.elements.enumerated() {
                    var triangles: [Int] = [], lines: [Int] = []
                    let indices = try indices(element)
                    switch element.primitiveType {
                    case .triangles:
                        guard indices.count == element.primitiveCount * 3 else { throw GeometryIOError.invalid("Invalid COLLADA triangle index count.") }
                        triangles = indices
                    case .triangleStrip:
                        guard indices.count >= element.primitiveCount + 2 else { throw GeometryIOError.invalid("Invalid COLLADA triangle strip.") }
                        for index in 0..<element.primitiveCount {
                            let face = index % 2 == 0 ? [indices[index], indices[index+1], indices[index+2]] : [indices[index+1], indices[index], indices[index+2]]
                            if Set(face).count == 3 { triangles += face }
                        }
                    case .line:
                        guard indices.count == element.primitiveCount * 2 else { throw GeometryIOError.invalid("Invalid COLLADA line index count.") }
                        lines = indices
                    default:
                        throw GeometryIOError.unsupported("This COLLADA file contains unsupported points or untriangulated polygons. Export it with triangulation enabled.")
                    }
                    guard !triangles.isEmpty || !lines.isEmpty else { continue }
                    guard (triangles + lines).allSatisfy({ localPositions.indices.contains($0) }) else {
                        throw GeometryIOError.invalid("A COLLADA face references a missing vertex.")
                    }
                    var remap: [Int: Int] = [:]
                    var world: [Vec3] = []
                    var mappedUV: [TextureCoordinate] = []
                    func mapped(_ index: Int) -> Int {
                        if let existing = remap[index] { return existing }
                        let p = localPositions[index]
                        let transformed = node.convertPosition(SCNVector3(CGFloat(p.x), CGFloat(p.y), CGFloat(p.z)), to: nil)
                        let next = world.count
                        world.append(Vec3(Double(transformed.x), Double(transformed.y), Double(transformed.z)))
                        if let localUV { mappedUV.append(localUV[index]) }
                        remap[index] = next
                        return next
                    }
                    triangles = triangles.map(mapped)
                    lines = lines.map(mapped)
                    if determinant < 0 {
                        for index in stride(from: 0, to: triangles.count, by: 3) { triangles.swapAt(index + 1, index + 2) }
                    }
                    totalVertices += world.count
                    guard totalVertices <= 1_000_000, triangles.count <= 1_500_000, lines.count <= 1_000_000, entities.count < 50_000 else {
                        throw GeometryIOError.invalid("The COLLADA model exceeds the supported geometry limit.")
                    }
                    guard world.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { throw GeometryIOError.invalid("COLLADA contains non-finite transformed coordinates.") }
                    let width = world.map(\.x).max()! - world.map(\.x).min()!
                    let depth = world.map(\.z).max()! - world.map(\.z).min()!
                    let height = world.map(\.y).max()! - world.map(\.y).min()!
                    let material = geometry.materials.isEmpty ? nil : geometry.materials[elementIndex % geometry.materials.count]
                    let decodedMaterial = material.flatMap { appearance.materials[$0.name ?? ""] } ?? SurfaceMaterial(colorHex: colorHex(material))
                    if !mappedUV.isEmpty {
                        // Our DAE UVs contain the material repeat/rotation transform.
                        // Undo it here so the editable material applies it exactly once.
                        let cosine = cos(decodedMaterial.textureRotation), sine = sin(decodedMaterial.textureRotation)
                        mappedUV = mappedUV.map { TextureCoordinate(u:(cosine*$0.u+sine*$0.v)*decodedMaterial.textureScale,
                                                                    v:(-sine*$0.u+cosine*$0.v)*decodedMaterial.textureScale) }
                    }
                    let suffix = geometry.elements.count > 1 ? " \(elementIndex + 1)" : ""
                    entities.append(GardenEntity(name: (node.name ?? geometry.name ?? "Imported mesh") + suffix, kind: .mesh,
                        origin: Vec3(0, 0, 0), width: width, depth: depth, height: height, colorHex: decodedMaterial.colorHex,
                        mesh: MeshData(vertices: world, triangles: triangles, lineIndices: lines, textureCoordinates: mappedUV.isEmpty ? nil : mappedUV), surface: decodedMaterial))
                }
                if entities.count - firstEntity > 1, entities[firstEntity...].allSatisfy({ $0.mesh?.lineIndices.isEmpty == true }) {
                    let parts = Array(entities[firstEntity...])
                    var combined = MeshData()
                    let keepsUV = parts.allSatisfy { $0.mesh?.textureCoordinates != nil }
                    if keepsUV { combined.textureCoordinates = [] }
                    var surface = parts[0].surface ?? SurfaceMaterial(colorHex: parts[0].colorHex)
                    surface.faceOverrides = []
                    for (partIndex, part) in parts.enumerated() {
                        guard let mesh = part.mesh else { continue }
                        let vertexOffset = combined.vertices.count
                        let triangleOffset = combined.triangles.count / 3
                        combined.vertices += mesh.vertices
                        if keepsUV { combined.textureCoordinates?.append(contentsOf: mesh.textureCoordinates!) }
                        combined.triangles += mesh.triangles.map { $0 + vertexOffset }
                        combined.lineIndices += mesh.lineIndices.map { $0 + vertexOffset }
                        if partIndex > 0, !mesh.triangles.isEmpty, let other = part.surface {
                            surface.faceOverrides.append(FaceSurface(triangleIndices: Array(triangleOffset..<(triangleOffset + mesh.triangles.count / 3)), colorHex: other.colorHex, textureData: other.textureData, textureScale: other.textureScale, textureRotation: other.textureRotation))
                        }
                    }
                    guard combined.vertices.count <= 250_000 else { throw GeometryIOError.invalid("A material-grouped COLLADA mesh exceeds 250,000 vertices.") }
                    var merged = parts[0]
                    merged.name = node.name ?? geometry.name ?? "Imported mesh"
                    merged.mesh = combined
                    merged.width = combined.vertices.map(\.x).max()! - combined.vertices.map(\.x).min()!
                    merged.depth = combined.vertices.map(\.z).max()! - combined.vertices.map(\.z).min()!
                    merged.height = combined.vertices.map(\.y).max()! - combined.vertices.map(\.y).min()!
                    merged.surface = surface
                    entities.removeSubrange(firstEntity...)
                    entities.append(merged)
                }
            }
            for child in node.childNodes { try visit(child) }
        }
        try visit(scene.rootNode)
        guard !entities.isEmpty else { throw GeometryIOError.invalid("The COLLADA file contains no supported faces or lines.") }
        let document = ModelDocument(entities: entities, name: url.deletingPathExtension().lastPathComponent)
        try document.validate()
        return document
    }

    /// Writes geometry and material images beside the DAE. Keep the generated texture folder with the DAE.
    public static func write(_ document: ModelDocument, to url: URL) throws {
        try document.validate()
        guard !document.entities.isEmpty else { throw GeometryIOError.invalid("There is no geometry to export.") }
        var totalVertices = 0
        var geometries: [String] = [], effects: [String] = [], materials: [String] = [], nodes: [String] = [], images: [String] = []
        var textureFiles: [String: Data] = [:]
        let safeStem = url.deletingPathExtension().lastPathComponent.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" ? String($0) : "_" }.joined()
        let textureFolder = String(safeStem.prefix(120)) + "-textures"
        func materialXML(_ material: SurfaceMaterial, id: String) throws {
            let rgb = rgbString(material.colorHex)
            var diffuse = "<color>\(rgb) 1</color>", params = ""
            if let data = material.textureData {
                let digest = SHA256.hash(data: data).map { String(format:"%02x",$0) }.joined()
                let suffix = data.starts(with: [0x89,0x50,0x4e,0x47]) ? "png" : "jpg"
                let file = "\(digest).\(suffix)"
                textureFiles[file] = data
                guard textureFiles.count <= 200, textureFiles.values.reduce(0, { $0 + $1.count }) <= 50 * 1024 * 1024 else { throw GeometryIOError.invalid("COLLADA export exceeds the 200-image or 50 MB texture limit.") }
                let imageID = "image-\(digest)"
                if !images.contains(where: { $0.contains("id=\"\(imageID)\"") }) { images.append("<image id=\"\(imageID)\"><init_from>\(escape(textureFolder))/\(file)</init_from></image>") }
                params = "<newparam sid=\"\(id)-surface\"><surface type=\"2D\"><init_from>\(imageID)</init_from></surface></newparam><newparam sid=\"\(id)-sampler\"><sampler2D><source>\(id)-surface</source></sampler2D></newparam>"
                diffuse = "<texture texture=\"\(id)-sampler\" texcoord=\"UVSET0\"/>"
            }
            effects.append("<effect id=\"\(id)-fx\"><profile_COMMON>\(params)<technique sid=\"common\"><lambert><diffuse>\(diffuse)</diffuse></lambert></technique></profile_COMMON><extra><technique profile=\"SKETCHMAKE\"><fallback_color>\(material.colorHex)</fallback_color><texture_scale>\(number(material.textureScale))</texture_scale><texture_rotation>\(number(material.textureRotation))</texture_rotation></technique></extra></effect>")
            materials.append("<material id=\"\(id)-mat\" name=\"\(escape(material.name))\"><instance_effect url=\"#\(id)-fx\"/></material>")
        }
        for (index, entity) in document.entities.enumerated() {
            let id = "shape\(index)"
            let mesh = try entity.triangulatedMesh()
            totalVertices += mesh.vertices.count
            guard totalVertices <= 1_000_000 else { throw GeometryIOError.invalid("COLLADA export exceeds one million vertices.") }
            guard !mesh.triangles.isEmpty || !mesh.lineIndices.isEmpty else { throw GeometryIOError.invalid("An object has no geometry to export.") }
            let base = entity.surface ?? SurfaceMaterial(name: entity.name, colorHex: entity.colorHex)
            var paints = [base]
            paints += base.faceOverrides.map { SurfaceMaterial(name:"Face material",colorHex:$0.colorHex,textureData:$0.textureData,textureScale:$0.textureScale,textureRotation:$0.textureRotation) }
            var assignments = Array(repeating:0,count:mesh.triangles.count / 3)
            for (faceIndex,face) in base.faceOverrides.enumerated() { for triangle in face.triangleIndices { assignments[triangle] = faceIndex + 1 } }
            for (paintIndex,paint) in paints.enumerated() { try materialXML(paint,id:"\(id)-paint\(paintIndex)") }
            let positions = mesh.vertices.flatMap { [number($0.x),number($0.y),number($0.z)] }.joined(separator:" ")
            let cosine = cos(entity.rotation), sine = sin(entity.rotation)
            let local = mesh.vertices.map { p -> Vec3 in
                let x=p.x-entity.origin.x,z=p.z-entity.origin.z
                return Vec3(cosine*x-sine*z,p.y-entity.origin.y,sine*x+cosine*z)
            }
            var textureCoordinates: [String] = []
            for triangle in 0..<(mesh.triangles.count / 3) {
                let points = (0..<3).map { local[mesh.triangles[triangle*3+$0]] }
                let a=points[0],b=points[1],c=points[2]
                let ux=b.x-a.x,uy=b.y-a.y,uz=b.z-a.z,vx=c.x-a.x,vy=c.y-a.y,vz=c.z-a.z
                let nx=uy*vz-uz*vy,ny=uz*vx-ux*vz,nz=ux*vy-uy*vx
                let paint=paints[assignments[triangle]],co=cos(paint.textureRotation),si=sin(paint.textureRotation)
                for (corner,p) in points.enumerated() {
                    let u:Double,v:Double
                    if let coordinates = mesh.textureCoordinates {
                        let coordinate = coordinates[mesh.triangles[triangle*3+corner]]
                        u=coordinate.u;v=coordinate.v
                    } else if abs(nx)>=abs(ny) && abs(nx)>=abs(nz) { u=p.z;v=p.y }
                    else if abs(ny)>=abs(nz) { u=p.x;v=p.z }
                    else { u=p.x;v=p.y }
                    // SceneKit normalizes COLLADA T as 1-T; emit the inverse so
                    // explicit model coordinates survive native import unchanged.
                    textureCoordinates += [number((co*u-si*v)/paint.textureScale),number(1-(si*u+co*v)/paint.textureScale)]
                }
            }
            var primitives = ""
            for paintIndex in paints.indices {
                let triangles=assignments.indices.filter { assignments[$0] == paintIndex }
                if !triangles.isEmpty {
                    let tuples=triangles.flatMap { t in (0..<3).map { k in "\(mesh.triangles[t*3+k]) \(t*3+k)" } }.joined(separator:" ")
                    primitives += "<triangles count=\"\(triangles.count)\" material=\"surface\(paintIndex)\"><input semantic=\"VERTEX\" source=\"#\(id)-vertices\" offset=\"0\"/><input semantic=\"TEXCOORD\" source=\"#\(id)-uv\" offset=\"1\" set=\"0\"/><p>\(tuples)</p></triangles>"
                }
            }
            if !mesh.lineIndices.isEmpty { primitives += "<lines count=\"\(mesh.lineIndices.count/2)\" material=\"surface0\"><input semantic=\"VERTEX\" source=\"#\(id)-vertices\" offset=\"0\"/><p>\(mesh.lineIndices.map(String.init).joined(separator:" "))</p></lines>" }
            let uvSource = textureCoordinates.isEmpty ? "" : "<source id=\"\(id)-uv\"><float_array id=\"\(id)-uv-array\" count=\"\(textureCoordinates.count)\">\(textureCoordinates.joined(separator:" "))</float_array><technique_common><accessor source=\"#\(id)-uv-array\" count=\"\(textureCoordinates.count/2)\" stride=\"2\"><param name=\"S\" type=\"float\"/><param name=\"T\" type=\"float\"/></accessor></technique_common></source>"
            geometries.append("<geometry id=\"\(id)\" name=\"\(escape(entity.name))\"><mesh><source id=\"\(id)-positions\"><float_array id=\"\(id)-array\" count=\"\(mesh.vertices.count*3)\">\(positions)</float_array><technique_common><accessor source=\"#\(id)-array\" count=\"\(mesh.vertices.count)\" stride=\"3\"><param name=\"X\" type=\"float\"/><param name=\"Y\" type=\"float\"/><param name=\"Z\" type=\"float\"/></accessor></technique_common></source>\(uvSource)<vertices id=\"\(id)-vertices\"><input semantic=\"POSITION\" source=\"#\(id)-positions\"/></vertices>\(primitives)</mesh></geometry>")
            let bindings=paints.indices.map { "<instance_material symbol=\"surface\($0)\" target=\"#\(id)-paint\($0)-mat\"><bind_vertex_input semantic=\"UVSET0\" input_semantic=\"TEXCOORD\" input_set=\"0\"/></instance_material>" }.joined()
            nodes.append("<node id=\"node\(index)\" name=\"\(escape(entity.name))\"><instance_geometry url=\"#\(id)\"><bind_material><technique_common>\(bindings)</technique_common></bind_material></instance_geometry></node>")
        }
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">
        <asset><contributor><authoring_tool>Garden Studio</authoring_tool></contributor><created>2026-01-01T00:00:00Z</created><modified>2026-01-01T00:00:00Z</modified><unit name="meter" meter="1"/><up_axis>Y_UP</up_axis></asset>
        <library_images>\(images.joined())</library_images><library_effects>\(effects.joined())</library_effects><library_materials>\(materials.joined())</library_materials><library_geometries>\(geometries.joined())</library_geometries>
        <library_visual_scenes><visual_scene id="scene" name="\(escape(document.name))">\(nodes.joined())</visual_scene></library_visual_scenes><scene><instance_visual_scene url="#scene"/></scene></COLLADA>
        """
        guard xml.utf8.count <= 64 * 1024 * 1024 else { throw GeometryIOError.invalid("The generated COLLADA document exceeds the 64 MB limit.") }
        try writeBundle(Data(xml.utf8),textures:textureFiles,folder:textureFolder,to:url)
    }

    /// Install images before the DAE, retaining the previous DAE and removing
    /// newly installed images if any step fails.
    private static func writeBundle(_ dae:Data,textures:[String:Data],folder:String,to url:URL)throws {
        let manager=FileManager.default
        guard url.isFileURL else {throw GeometryIOError.invalid("COLLADA export requires a local file.")}
        if textures.isEmpty {try dae.write(to:url,options:.atomic);return}
        let parent=url.deletingLastPathComponent()
        let directory=parent.appendingPathComponent(folder,isDirectory:true)
        let base=parent.resolvingSymlinksInPath().standardizedFileURL.path
        guard directory.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base+"/") else {throw GeometryIOError.unsupported("The texture folder resolves outside the export directory.")}
        var daePermissions:NSNumber?
        if manager.fileExists(atPath:url.path) {
            let attributes=try manager.attributesOfItem(atPath:url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {throw GeometryIOError.invalid("A COLLADA export destination is not a regular file.")}
            daePermissions=attributes[.posixPermissions] as? NSNumber
        }
        if manager.fileExists(atPath:directory.path) {
            let attributes=try manager.attributesOfItem(atPath:directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {throw GeometryIOError.invalid("The COLLADA texture destination is not a directory.")}
        }
        var missing:[(URL,Data)]=[]
        for name in textures.keys.sorted() {
            let target=directory.appendingPathComponent(name)
            guard target.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(directory.resolvingSymlinksInPath().standardizedFileURL.path+"/") else {throw GeometryIOError.unsupported("A texture sidecar resolves outside its export folder.")}
            let data=textures[name]!
            if manager.fileExists(atPath:target.path) {
                guard try Data(contentsOf:target)==data else {throw GeometryIOError.invalid("An existing texture sidecar has different content; choose another export location.")}
            } else {missing.append((target,data))}
        }
        let work=parent.appendingPathComponent(".gardenstudio-dae-"+UUID().uuidString,isDirectory:true)
        try manager.createDirectory(at:work,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var retainRecovery=false
        defer {if !retainRecovery {try? manager.removeItem(at:work)}}
        for (index,item) in missing.enumerated() {try item.1.write(to:work.appendingPathComponent("image-\(index)"),options:.atomic)}
        let stagedDAE=work.appendingPathComponent("model.dae")
        try dae.write(to:stagedDAE,options:.atomic)
        if let mode=daePermissions {try manager.setAttributes([.posixPermissions:mode],ofItemAtPath:stagedDAE.path)}
        var madeDirectory=false,installed:[URL]=[],backup:URL?
        do {
            if !textures.isEmpty && !manager.fileExists(atPath:directory.path) {
                try manager.createDirectory(at:directory,withIntermediateDirectories:false)
                madeDirectory=true
            }
            for (index,item) in missing.enumerated() {
                try manager.moveItem(at:work.appendingPathComponent("image-\(index)"),to:item.0)
                installed.append(item.0)
            }
            if manager.fileExists(atPath:url.path) {
                let saved=work.appendingPathComponent("old.dae")
                try manager.moveItem(at:url,to:saved)
                backup=saved
            }
            try manager.moveItem(at:stagedDAE,to:url)
        } catch {
            var recoveryFailed=false
            if let backup {
                do {try manager.moveItem(at:backup,to:url)} catch {recoveryFailed=true}
            }
            for image in installed.reversed() {
                do {try manager.removeItem(at:image)} catch {recoveryFailed=true}
            }
            if madeDirectory {
                do {try manager.removeItem(at:directory)} catch {recoveryFailed=true}
            }
            if recoveryFailed {
                retainRecovery=true
                throw GeometryIOError.invalid("COLLADA export failed and could not restore every file. Recovery copies remain in \(work.path).")
            }
            throw error
        }
    }

    private static func rgbString(_ hex: String) -> String {
        let n=UInt32(hex.dropFirst(),radix:16) ?? 0xE7DCC8
        return [Double(n>>16 & 255)/255,Double(n>>8 & 255)/255,Double(n & 255)/255].map(number).joined(separator:" ")
    }

    private static func coordinates(_ source: SCNGeometrySource) throws -> [TextureCoordinate] {
        let bytes = source.bytesPerComponent
        guard source.usesFloatComponents, [4,8].contains(bytes), source.componentsPerVector >= 2,
              source.vectorCount <= 250_000, source.dataOffset >= 0,
              source.dataStride >= bytes*2, source.dataStride <= source.data.count,
              source.vectorCount == 0 || source.dataOffset + (source.vectorCount-1)*source.dataStride + bytes*2 <= source.data.count else {
            throw GeometryIOError.invalid("Invalid COLLADA texture-coordinate buffer.")
        }
        func number(_ offset: Int) -> Double {
            if bytes == 4 {
                var bits: UInt32 = 0
                _ = withUnsafeMutableBytes(of:&bits) { source.data.copyBytes(to:$0,from:offset..<(offset+4)) }
                return Double(Float(bitPattern:UInt32(littleEndian:bits)))
            }
            var bits: UInt64 = 0
            _ = withUnsafeMutableBytes(of:&bits) { source.data.copyBytes(to:$0,from:offset..<(offset+8)) }
            return Double(bitPattern:UInt64(littleEndian:bits))
        }
        return try (0..<source.vectorCount).map { index in
            let offset=source.dataOffset+index*source.dataStride
            let uv=TextureCoordinate(u:number(offset),v:number(offset+bytes))
            guard uv.u.isFinite,uv.v.isFinite else { throw GeometryIOError.invalid("Nonfinite COLLADA texture coordinates.") }
            return uv
        }
    }

    private static func positions(_ source: SCNGeometrySource) throws -> [Vec3] {
        guard source.usesFloatComponents, [4, 8].contains(source.bytesPerComponent), source.componentsPerVector >= 3, source.vectorCount >= 0,
              source.vectorCount <= 250_000, source.dataStride >= source.bytesPerComponent * 3, source.dataOffset >= 0 else {
            throw GeometryIOError.unsupported("The COLLADA file uses an unsupported vertex encoding.")
        }
        let bytes = source.bytesPerComponent
        guard source.vectorCount == 0 || source.dataOffset + (source.vectorCount - 1) * source.dataStride + bytes * 3 <= source.data.count else {
            throw GeometryIOError.invalid("Truncated COLLADA vertex buffer.")
        }
        func component(_ offset: Int) -> Double {
            if bytes == 4 {
                var bits: UInt32 = 0
                _ = withUnsafeMutableBytes(of: &bits) { source.data.copyBytes(to: $0, from: offset..<(offset + 4)) }
                return Double(Float(bitPattern: UInt32(littleEndian: bits)))
            }
            var bits: UInt64 = 0
            _ = withUnsafeMutableBytes(of: &bits) { source.data.copyBytes(to: $0, from: offset..<(offset + 8)) }
            return Double(bitPattern: UInt64(littleEndian: bits))
        }
        return (0..<source.vectorCount).map { index in
            let offset = source.dataOffset + index * source.dataStride
            return Vec3(component(offset), component(offset + bytes), component(offset + bytes * 2))
        }
    }

    private static func indices(_ element: SCNGeometryElement) throws -> [Int] {
        let bytes = element.bytesPerIndex
        guard [1, 2, 4, 8].contains(bytes), element.data.count % bytes == 0, element.data.count <= 12_000_000 else {
            throw GeometryIOError.invalid("Unsupported or oversized COLLADA index buffer.")
        }
        return try stride(from: 0, to: element.data.count, by: bytes).map { offset in
            var value: UInt64 = 0
            for byte in 0..<bytes { value |= UInt64(element.data[offset + byte]) << (byte * 8) }
            guard value <= UInt64(Int.max) else { throw GeometryIOError.invalid("COLLADA vertex index is out of range.") }
            return Int(value)
        }
    }
    private static func colorHex(_ material: SCNMaterial?) -> String {
        guard let color = (material?.diffuse.contents as? NSColor)?.usingColorSpace(.deviceRGB) else { return "#E7DCC8" }
        return String(format: "#%02X%02X%02X", Int((max(0, min(1, color.redComponent)) * 255).rounded()), Int((max(0, min(1, color.greenComponent)) * 255).rounded()), Int((max(0, min(1, color.blueComponent)) * 255).rounded()))
    }
    private static func number(_ value: Double) -> String { String(format: "%.9g", locale: Locale(identifier: "en_US_POSIX"), value == 0 ? 0 : value) }
    private static func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;") }
}

private final class ColladaPreflight: NSObject, XMLParserDelegate {
    var error: Error?
    var rootIsCollada = false
    private var depth = 0
    private var elementCount = 0
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        depth += 1; elementCount += 1
        if depth == 1 { rootIsCollada = elementName == "COLLADA" }
        guard depth <= 128, elementCount <= 1_000_000 else { fail(parser, "COLLADA document is too complex."); return }
        if elementName == "unit", let declared = attributeDict["meter"] {
            guard let value = Double(declared), value.isFinite, value > 0 else { fail(parser, "COLLADA units must be a positive finite meters-per-unit value."); return }
        }
        if ["controller", "animation", "script", "profile_GLSL", "profile_CG", "profile_GLES", "profile_GLES2"].contains(elementName) {
            fail(parser, "Animations, scripts and deforming rigs are not supported. Export a static COLLADA model.")
        }
        for key in ["url", "source", "target"] {
            if let value = attributeDict[key], !value.isEmpty && !value.hasPrefix("#") {
                fail(parser, "External COLLADA references are not supported. Export a self-contained model.")
            }
        }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { depth -= 1 }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { fail(parser, "External XML entities are not supported.") }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { fail(parser, "XML entity declarations are not supported.") }
    private func fail(_ parser: XMLParser, _ message: String) { if error == nil { error = GeometryIOError.unsupported(message) }; parser.abortParsing() }
}

/// SceneKit can discard an invalid mesh and still return its valid siblings.
/// Validate the original index streams before that lossy decoding step.
private enum ColladaGeometryValidation {
    private struct Stream { let count: Int }
    private struct Input { let offset: Int; let streams: [Stream] }

    static func validate(_ root: XMLElement) throws {
        func descendants(_ node: XMLElement, _ name: String) -> [XMLElement] {
            node.elements(forName: name) + (node.children ?? []).compactMap { $0 as? XMLElement }.flatMap { descendants($0, name) }
        }
        func invalid(_ message: String) -> GeometryIOError { .invalid("Invalid COLLADA geometry: " + message) }
        func integer(_ text: String?, default fallback: Int? = nil) throws -> Int {
            if text == nil, let fallback { return fallback }
            guard let text, let number = Int(text), number >= 0, number <= 20_000_000 else { throw invalid("invalid count, offset or index.") }
            return number
        }
        func attribute(_ node: XMLElement, _ name: String) -> String? { node.attribute(forName: name)?.stringValue }
        func reference(_ node: XMLElement, _ name: String = "source") throws -> String {
            guard let value = attribute(node, name), value.hasPrefix("#"), value.count > 1 else { throw invalid("missing local reference.") }
            return String(value.dropFirst())
        }
        func identified(_ nodes: [XMLElement]) throws -> [String: XMLElement] {
            var result: [String: XMLElement] = [:]
            for node in nodes {
                guard let id = attribute(node, "id"), !id.isEmpty, result[id] == nil else { throw invalid("missing or duplicate identifier.") }
                result[id] = node
            }
            return result
        }
        let geometries = try identified(descendants(root, "geometry"))
        let referenced = try Set(descendants(root, "instance_geometry").map { try reference($0, "url") })
        for id in referenced {
            guard let geometry = geometries[id], let mesh = geometry.elements(forName: "mesh").first else { throw invalid("unresolved or unsupported mesh reference.") }
            let sources = try identified(mesh.elements(forName: "source"))
            let vertices = try identified(mesh.elements(forName: "vertices"))
            var decoded: [String: Stream] = [:]
            func stream(_ id: String) throws -> Stream {
                if let cached = decoded[id] { return cached }
                guard let source = sources[id], let accessor = source.elements(forName: "technique_common").first?.elements(forName: "accessor").first else { throw invalid("unresolved source/accessor.") }
                let arrayID = try reference(accessor)
                guard let array = source.elements(forName: "float_array").first(where: { attribute($0, "id") == arrayID }) else { throw invalid("accessor does not reference a float array.") }
                let values = (array.stringValue ?? "").split(whereSeparator: { $0.isWhitespace })
                let declared = try integer(attribute(array, "count"))
                guard values.count == declared, values.allSatisfy({ Double($0)?.isFinite == true }) else { throw invalid("invalid or nonfinite float table.") }
                let count = try integer(attribute(accessor, "count"))
                let stride = try integer(attribute(accessor, "stride"), default: 1)
                let offset = try integer(attribute(accessor, "offset"), default: 0)
                let params = accessor.elements(forName: "param")
                // These mesh streams contain scalar position, normal and UV components.
                guard !params.isEmpty, params.allSatisfy({ attribute($0, "type") == "float" }), stride >= params.count,
                      offset <= declared, count == 0 || offset + (count - 1) * stride + params.count <= declared else { throw invalid("accessor exceeds its float table or uses unsupported components.") }
                let result = Stream(count: count)
                decoded[id] = result
                return result
            }
            func vertexStreams(_ id: String) throws -> [Stream] {
                guard let vertex = vertices[id] else { throw invalid("unresolved vertex source.") }
                let inputs = vertex.elements(forName: "input")
                guard inputs.contains(where: { attribute($0, "semantic") == "POSITION" }) else { throw invalid("vertices have no positions.") }
                return try inputs.map { try stream(reference($0)) }
            }
            for primitive in (mesh.children ?? []).compactMap({ $0 as? XMLElement }) {
                guard let kind = primitive.name, !["source", "vertices", "extra"].contains(kind) else { continue }
                guard ["triangles", "lines", "polylist", "polygons", "tristrips"].contains(kind) else { throw invalid("unsupported primitive \(kind).") }
                let declared = try integer(attribute(primitive, "count"))
                let rawInputs = primitive.elements(forName: "input")
                guard rawInputs.contains(where: { attribute($0, "semantic") == "VERTEX" }) else { throw invalid("primitive has no vertex input.") }
                let inputs = try rawInputs.map { input -> Input in
                    let offset = try integer(attribute(input, "offset"), default: 0)
                    let id = try reference(input)
                    return Input(offset: offset, streams: try attribute(input, "semantic") == "VERTEX" ? vertexStreams(id) : [stream(id)])
                }
                let tupleSize = (inputs.map(\.offset).max() ?? 0) + 1
                func indices(_ node: XMLElement) throws -> Int {
                    let tokens = (node.stringValue ?? "").split(whereSeparator: { $0.isWhitespace })
                    guard tokens.count % tupleSize == 0 else { throw invalid("incomplete primitive index tuple.") }
                    let values = try tokens.map { try integer(String($0)) }
                    for start in stride(from: 0, to: values.count, by: tupleSize) {
                        for input in inputs {
                            guard input.streams.allSatisfy({ values[start + input.offset] < $0.count }) else { throw invalid("primitive index is outside its source accessor.") }
                        }
                    }
                    return values.count / tupleSize
                }
                let lists = primitive.elements(forName: "p")
                let counts = try lists.map(indices)
                switch kind {
                case "triangles", "lines":
                    guard (declared == 0 && counts.isEmpty) || (counts.count == 1 && counts[0] == declared * (kind == "triangles" ? 3 : 2)) else { throw invalid("primitive count does not match index table.") }
                case "polylist":
                    guard let vcount = primitive.elements(forName: "vcount").first, counts.count == 1 else { throw invalid("missing polylist vertex counts.") }
                    let sizes = try (vcount.stringValue ?? "").split(whereSeparator: { $0.isWhitespace }).map { try integer(String($0)) }
                    guard sizes.count == declared, sizes.allSatisfy({ $0 >= 3 }), sizes.reduce(0, +) == counts[0] else { throw invalid("invalid polylist vertex counts.") }
                default:
                    // Polygon holes have nested index rings, which this static importer cannot retain reliably.
                    guard primitive.elements(forName: "ph").isEmpty, counts.count == declared,
                          counts.allSatisfy({ $0 >= 3 }) else { throw invalid("invalid polygon or strip index lists.") }
                }
            }
        }
    }
}

/// Reads admitted local texture bytes itself, then removes all resource-loading constructs
/// before the native SceneKit decoder is invoked. No external URL reaches SceneKit.
private enum ColladaAppearance {
    static func prepare(data: Data, baseURL: URL) throws -> (data: Data, materials: [String: SurfaceMaterial]) {
        let document = try XMLDocument(data:data,options:[])
        guard let root=document.rootElement() else { throw GeometryIOError.invalid("Missing COLLADA root.") }
        try ColladaGeometryValidation.validate(root)
        var imageData: [String:Data] = [:]
        let imageNodes = descendants(root,named:"image")
        guard imageNodes.count <= 200 else { throw GeometryIOError.invalid("COLLADA contains more than 200 material images.") }
        var totalBytes=0
        for image in imageNodes {
            guard image.parent?.name == "library_images", let id=image.attribute(forName:"id")?.stringValue, !id.isEmpty, imageData[id] == nil,
                  let path=image.elements(forName:"init_from").first?.stringValue else { throw GeometryIOError.unsupported("COLLADA images must be named local PNG/JPEG sidecars.") }
            let bytes=try readImage(path,relativeTo:baseURL)
            totalBytes += bytes.count
            guard totalBytes <= 50*1024*1024 else { throw GeometryIOError.invalid("COLLADA textures exceed the 50 MB import limit.") }
            imageData[id]=bytes
        }
        var effects: [String:SurfaceMaterial] = [:]
        for effect in descendants(root,named:"effect") {
            guard let id=effect.attribute(forName:"id")?.stringValue, !id.isEmpty, effects[id] == nil else { throw GeometryIOError.invalid("COLLADA material effects need unique identifiers.") }
            var surface=SurfaceMaterial(name:id)
            let diffuse=descendants(effect,named:"diffuse").first
            if let color=diffuse?.elements(forName:"color").first?.stringValue { surface.colorHex=try parseColor(color) }
            let ownTechnique=descendants(effect,named:"technique").first { $0.attribute(forName:"profile")?.stringValue == "SKETCHMAKE" }
            if let fallback=ownTechnique?.elements(forName:"fallback_color").first?.stringValue { surface.colorHex=fallback }
            if let scale=ownTechnique?.elements(forName:"texture_scale").first?.stringValue {
                guard let value=Double(scale) else { throw GeometryIOError.invalid("Invalid COLLADA texture scale.") }; surface.textureScale=value
            }
            if let rotation=ownTechnique?.elements(forName:"texture_rotation").first?.stringValue {
                guard let value=Double(rotation) else { throw GeometryIOError.invalid("Invalid COLLADA texture rotation.") }; surface.textureRotation=value
            }
            let textures=descendants(effect,named:"texture")
            if !textures.isEmpty {
                guard textures.count == 1, let texture=diffuse?.elements(forName:"texture").first,
                      let samplerID=texture.attribute(forName:"texture")?.stringValue else { throw GeometryIOError.unsupported("Only diffuse COLLADA image textures are supported.") }
                let params=descendants(effect,named:"newparam")
                guard let sampler=params.first(where:{$0.attribute(forName:"sid")?.stringValue==samplerID}),
                      let source=descendants(sampler,named:"sampler2D").first?.elements(forName:"source").first?.stringValue,
                      let plane=params.first(where:{$0.attribute(forName:"sid")?.stringValue==source}),
                      let imageID=descendants(plane,named:"surface").first?.elements(forName:"init_from").first?.stringValue,
                      let bytes=imageData[imageID] else { throw GeometryIOError.unsupported("A COLLADA texture has an unresolved image/surface/sampler binding.") }
                surface.textureData=bytes
                let replacement=XMLElement(name:"color",stringValue:colorFloats(surface.colorHex)+" 1")
                texture.detach(); diffuse?.addChild(replacement)
            }
            try surface.validate()
            effects[id]=surface
            for param in descendants(effect,named:"newparam") { param.detach() }
        }
        var materials: [String:SurfaceMaterial] = [:]
        for material in descendants(root,named:"material") {
            guard let id=material.attribute(forName:"id")?.stringValue,!id.isEmpty,materials[id]==nil,
                  let effectRef=material.elements(forName:"instance_effect").first?.attribute(forName:"url")?.stringValue,
                  effectRef.hasPrefix("#"),var surface=effects[String(effectRef.dropFirst())] else { throw GeometryIOError.unsupported("A COLLADA material has an unresolved effect binding.") }
            surface.name=material.attribute(forName:"name")?.stringValue ?? id
            if surface.name.isEmpty { surface.name=id }
            surface.name=String(surface.name.prefix(200))
            materials[id]=surface
            // A unique native material name lets decoded elements recover their original appearance.
            material.removeAttribute(forName:"name")
            material.addAttribute(XMLNode.attribute(withName:"name",stringValue:id) as! XMLNode)
        }
        for library in descendants(root,named:"library_images") { library.detach() }
        guard descendants(root,named:"image").isEmpty,descendants(root,named:"texture").isEmpty,descendants(root,named:"init_from").isEmpty else { throw GeometryIOError.unsupported("Unrecognized COLLADA image resources are not supported.") }
        return (document.xmlData(options:[]),materials)
    }

    private static func descendants(_ node:XMLElement,named name:String) -> [XMLElement] {
        var result:[XMLElement]=[]
        for child in node.children ?? [] {
            guard let element=child as? XMLElement else { continue }
            if element.name==name { result.append(element) }
            result += descendants(element,named:name)
        }
        return result
    }
    private static func readImage(_ raw:String,relativeTo url:URL) throws -> Data {
        let encoded=raw.trimmingCharacters(in:.whitespacesAndNewlines)
        guard let path=encoded.removingPercentEncoding,!path.isEmpty,path.utf8.count<=4096,
              !path.hasPrefix("/"),!path.contains(":"),!path.contains("\\"),!path.contains("\0"),
              !path.split(separator:"/",omittingEmptySubsequences:false).contains(where:{$0==".." || $0=="." || $0.isEmpty}) else { throw GeometryIOError.unsupported("Texture paths must be relative local files without traversal or URLs.") }
        let base=url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let candidate=base.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(base.path+"/") else { throw GeometryIOError.unsupported("Texture path escapes the COLLADA directory.") }
        let values=try candidate.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
        guard values.isRegularFile==true,let size=values.fileSize,size>0,size<=SurfaceMaterial.maximumTextureBytes else { throw GeometryIOError.invalid("COLLADA textures must be regular PNG/JPEG files no larger than 10 MB.") }
        let bytes=try Data(contentsOf:candidate)
        try SurfaceMaterial(textureData:bytes).validate()
        return bytes
    }
    private static func parseColor(_ text:String) throws -> String {
        let values=text.split(whereSeparator:{$0.isWhitespace}).compactMap { Double($0) }
        guard values.count==4,values.allSatisfy({$0.isFinite && $0>=0 && $0<=1}) else { throw GeometryIOError.invalid("COLLADA diffuse color must contain four normalized finite values.") }
        return String(format:"#%02X%02X%02X",Int((values[0]*255).rounded()),Int((values[1]*255).rounded()),Int((values[2]*255).rounded()))
    }
    private static func colorFloats(_ hex:String) -> String {
        let value=UInt32(hex.dropFirst(),radix:16) ?? 0xE7DCC8
        return [Double(value>>16 & 255)/255,Double(value>>8 & 255)/255,Double(value & 255)/255].map { String(format:"%.9g",locale:Locale(identifier:"en_US_POSIX"),$0) }.joined(separator:" ")
    }
}
