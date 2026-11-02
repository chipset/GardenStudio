import Foundation
import CryptoKit
import SketchCore

/// Shared bounded geometry conversion for the plain mesh exchange formats.
enum PlainMesh {
    static func units(_ scale: Double) throws { guard scale.isFinite, scale > 0 else { throw GeometryIOError.invalid("Meters per unit must be positive and finite.") } }
    static func data(_ url: URL) throws -> Data {
        guard url.isFileURL, let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 128 * 1024 * 1024 else { throw GeometryIOError.invalid("Mesh input must be a local file no larger than 128 MB.") }
        return try Data(contentsOf: url)
    }
    static func decode(_ p: Vec3, _ s: Double, _ z: Bool) -> Vec3 { z ? Vec3(p.x*s,p.z*s,-p.y*s) : Vec3(p.x*s,p.y*s,p.z*s) }
    static func encode(_ p: Vec3, _ s: Double, _ z: Bool) throws -> Vec3 {
        let value = z ? Vec3(p.x/s,-p.z/s,p.y/s) : Vec3(p.x/s,p.y/s,p.z/s)
        guard [value.x,value.y,value.z].allSatisfy(\.isFinite) else { throw GeometryIOError.invalid("Export coordinates overflow at the selected unit scale.") }; return value
    }
    static func number(_ text: String) throws -> Double { guard let d = Double(text), d.isFinite else { throw GeometryIOError.invalid("Mesh contains an invalid or non-finite number.") }; return d }
    static func integer(_ text: String) throws -> Int { guard let i = Int(text) else { throw GeometryIOError.invalid("Mesh contains an invalid integer.") }; return i }
    static func polygon(_ indices: [Int], vertices: [Vec3]) throws -> [Int] {
        guard indices.count >= 3, indices.count <= 10_000, indices.allSatisfy({ vertices.indices.contains($0) }), Set(indices).count == indices.count else { throw GeometryIOError.invalid("Polygon contains missing, repeated or excessive vertex indices.") }
        if indices.count == 3 { return indices }
        let points = indices.map { vertices[$0] }
        guard let mesh = try GeometryTools.face(points: points).mesh else { throw GeometryIOError.invalid("Polygon could not be triangulated.") }
        let mapped = try mesh.vertices.map { p -> Int in
            guard let i = points.firstIndex(where: { abs($0.x-p.x) < 1e-8 && abs($0.y-p.y) < 1e-8 && abs($0.z-p.z) < 1e-8 }) else { throw GeometryIOError.invalid("Polygon triangulation changed its boundary.") }
            return indices[i]
        }
        return mesh.triangles.map { mapped[$0] }
    }
    static func entity(_ mesh: MeshData, name: String, surface: SurfaceMaterial? = nil) throws -> SketchEntity {
        try mesh.validate()
        return SketchEntity(name: String(name.prefix(200)), kind: .mesh, origin: Vec3(0,0,0), width: mesh.vertices.map(\.x).max()! - mesh.vertices.map(\.x).min()!, depth: mesh.vertices.map(\.z).max()! - mesh.vertices.map(\.z).min()!, height: mesh.vertices.map(\.y).max()! - mesh.vertices.map(\.y).min()!, colorHex: surface?.colorHex ?? "#E7DCC8", mesh: mesh, surface: surface)
    }
    static func flattened(_ document: ModelDocument) throws -> (MeshData, [String]) {
        try document.validate()
        var result = MeshData(), colors: [String] = []
        for e in document.entities {
            let m = try e.triangulatedMesh(), offset = result.vertices.count
            guard m.lineIndices.isEmpty else { throw GeometryIOError.unsupported("This mesh format exports faces only; remove line objects first.") }
            result.vertices += m.vertices; result.triangles += m.triangles.map { $0 + offset }
            var c = Array(repeating: e.surface?.colorHex ?? e.colorHex, count: m.triangles.count/3)
            for override in e.surface?.faceOverrides ?? [] { for i in override.triangleIndices { c[i] = override.colorHex } }
            colors += c
        }
        try result.validate(); return (result, colors)
    }
    static func rgb(_ hex: String) -> [UInt8] { let s = String(hex.dropFirst()); return stride(from: 0, to: 6, by: 2).map { UInt8(s.dropFirst($0).prefix(2),radix:16) ?? 0 } }
    static func hex(_ values: [Double]) throws -> String { guard values.count == 3, values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 255 && $0.rounded() == $0 }) else { throw GeometryIOError.invalid("RGB channels must be integers from 0 to 255.") }; return "#" + values.map { String(format:"%02X",Int($0)) }.joined() }
    static func colored(_ mesh: MeshData, colors: [String], name: String) throws -> ModelDocument {
        var surface = SurfaceMaterial()
        for color in Set(colors).sorted() { surface.faceOverrides.append(FaceSurface(triangleIndices: colors.indices.filter { colors[$0] == color }, colorHex: color)) }
        let doc = ModelDocument(entities: [try entity(mesh,name:name,surface:colors.isEmpty ? nil : surface)],name:name)
        try doc.validate(); return doc
    }
}

/// OBJ uses bottom-left UVs; model UVs use the renderer/glTF top-left convention.
public enum OBJFormat {
    public static func read(url: URL, metersPerUnit: Double = 1, zUp: Bool = false) throws -> ModelDocument {
        try PlainMesh.units(metersPerUnit)
        guard let text = String(data: try PlainMesh.data(url), encoding: .utf8) else { throw GeometryIOError.invalid("OBJ must be UTF-8 text.") }
        var positions: [Vec3] = [], uv: [TextureCoordinate] = [], normals = 0
        var mesh = MeshData(), tuples: [String:Int] = [:], materials: [String:SurfaceMaterial] = [:], faces: [String:[Int]] = [:]
        var libraries = Set<URL>(), lineGroups: [String:[Int]] = [:]
        var active = "", name = url.deletingPathExtension().lastPathComponent, entities: [SketchEntity] = [], totalTriangles = 0, totalVertices = 0, totalLineIndices = 0
        func compact(triangles: [Int] = [], lines: [Int] = []) -> MeshData {
            let used = Set(triangles + lines).sorted()
            let remap = Dictionary(uniqueKeysWithValues: used.enumerated().map { ($0.element,$0.offset) })
            return MeshData(vertices:used.map { mesh.vertices[$0] },triangles:triangles.map { remap[$0]! },lineIndices:lines.map { remap[$0]! },textureCoordinates:mesh.textureCoordinates.map { coordinates in used.map { coordinates[$0] } })
        }
        func append(_ geometry: MeshData, surface: SurfaceMaterial?, name: String) throws {
            totalVertices += geometry.vertices.count
            guard totalVertices <= 250_000, entities.count < 50_000 else { throw GeometryIOError.invalid("OBJ exceeds 250,000 expanded vertices or 50,000 objects.") }
            entities.append(try PlainMesh.entity(geometry,name:name,surface:surface))
        }
        func flush() throws {
            guard !mesh.triangles.isEmpty || !mesh.lineIndices.isEmpty else { return }
            if !mesh.triangles.isEmpty {
                var surface = SurfaceMaterial()
                for key in faces.keys.sorted() where !key.isEmpty {
                    guard let m = materials[key] else { throw GeometryIOError.invalid("OBJ refers to an undefined material: \(key)") }
                    surface.faceOverrides.append(FaceSurface(triangleIndices:faces[key]!,colorHex:m.colorHex,textureData:m.textureData))
                }
                try append(compact(triangles:mesh.triangles),surface:surface.faceOverrides.isEmpty ? nil : surface,name:name)
            }
            // The model stores one appearance per wire mesh; split material groups instead of dropping paint.
            for key in lineGroups.keys.sorted() {
                let material: SurfaceMaterial?
                if key.isEmpty { material = nil }
                else {
                    guard let found = materials[key] else { throw GeometryIOError.invalid("OBJ refers to an undefined line material: \(key)") }
                    material = found
                }
                try append(compact(lines:lineGroups[key]!),surface:material,name:mesh.triangles.isEmpty && lineGroups.count == 1 ? name : name + " lines " + (key.isEmpty ? "default" : key))
            }
            mesh = MeshData(); tuples = [:]; faces = [:]; lineGroups = [:]
        }
        func index(_ token: String, count: Int) throws -> Int { let n = try PlainMesh.integer(token); let i = n > 0 ? n-1 : count+n; guard n != 0, i >= 0, i < count else { throw GeometryIOError.invalid("OBJ index is outside its vertex/UV/normal array.") }; return i }
        for line in text.components(separatedBy:.newlines) {
            let f = line.split(separator:"#",maxSplits:1,omittingEmptySubsequences:false)[0].split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let op = f.first else { continue }; let a = Array(f.dropFirst())
            switch op {
            case "v":
                guard a.count == 3 || a.count == 4, positions.count < 250_000 else { throw GeometryIOError.invalid("OBJ vertex size or count is unsupported.") }
                let values = try a.map(PlainMesh.number); guard values.count == 3 || values[3] == 1 else { throw GeometryIOError.unsupported("OBJ rational vertices are unsupported.") }
                positions.append(PlainMesh.decode(Vec3(values[0],values[1],values[2]),metersPerUnit,zUp))
            case "vt":
                guard a.count >= 2, a.count <= 3, uv.count < 1_500_000 else { throw GeometryIOError.invalid("Invalid OBJ UV coordinates.") }; let values = try a.map(PlainMesh.number); uv.append(TextureCoordinate(u:values[0],v:1-values[1]))
            case "vn": guard a.count == 3, normals < 250_000 else { throw GeometryIOError.invalid("Invalid OBJ normal.") }; _ = try a.map(PlainMesh.number); normals += 1
            case "o", "g": try flush(); name = a.joined(separator:" "); if name.isEmpty { name = "Object" }
            case "mtllib":
                guard !a.isEmpty else { throw GeometryIOError.invalid("Missing OBJ material library.") }
                for path in a {
                    let library = try local(path,relativeTo:url)
                    if libraries.insert(library).inserted {
                        guard libraries.count <= 64 else { throw GeometryIOError.invalid("OBJ exceeds 64 material libraries.") }
                        materials.merge(try readMaterials(library),uniquingKeysWith: { _,new in new })
                        guard materials.count <= 10_000, materials.values.reduce(0, { $0 + ($1.textureData?.count ?? 0) }) <= 50*1024*1024 else { throw GeometryIOError.invalid("OBJ materials exceed the 10,000 material or 50 MB texture limit.") }
                    }
                }
            case "usemtl": guard !a.isEmpty else { throw GeometryIOError.invalid("Missing material name.") }; active = a.joined(separator:" ")
            case "f", "l":
                guard a.count >= (op == "f" ? 3 : 2), a.count <= 10_000 else { throw GeometryIOError.invalid("Invalid OBJ face/line.") }
                var indices: [Int] = []
                for token in a {
                    let bits = token.split(separator:"/",omittingEmptySubsequences:false).map(String.init)
                    guard bits.count <= 3, !bits[0].isEmpty else { throw GeometryIOError.invalid("Invalid OBJ face tuple.") }
                    let p = try index(bits[0],count:positions.count)
                    let t = bits.count > 1 && !bits[1].isEmpty ? try index(bits[1],count:uv.count) : nil
                    if bits.count > 2 && !bits[2].isEmpty { _ = try index(bits[2],count:normals) }
                    let key = "\(p)/\(t ?? -1)/\(bits.count > 2 ? bits[2] : "")"
                    if let i = tuples[key] { indices.append(i) } else {
                        guard mesh.vertices.count < 250_000 else { throw GeometryIOError.invalid("OBJ exceeds the expanded vertex limit.") }
                        let i = mesh.vertices.count; tuples[key] = i; mesh.vertices.append(positions[p]); indices.append(i)
                        if t != nil && mesh.textureCoordinates == nil { mesh.textureCoordinates = Array(repeating:TextureCoordinate(u:0,v:0),count:i) }
                        if mesh.textureCoordinates != nil { mesh.textureCoordinates!.append(t.map { uv[$0] } ?? TextureCoordinate(u:0,v:0)) }
                    }
                }
                if op == "f" {
                    let triangles = try PlainMesh.polygon(indices,vertices:mesh.vertices), start = mesh.triangles.count/3
                    totalTriangles += triangles.count/3; guard totalTriangles <= 500_000 else { throw GeometryIOError.invalid("OBJ exceeds 500,000 triangles.") }
                    mesh.triangles += triangles; faces[active,default:[]] += Array(start..<mesh.triangles.count/3)
                } else {
                    totalLineIndices += (indices.count-1)*2
                    guard totalLineIndices <= 1_000_000 else { throw GeometryIOError.invalid("OBJ exceeds 500,000 line segments.") }
                    for i in 1..<indices.count {
                        let edge = [indices[i-1],indices[i]]
                        mesh.lineIndices += edge; lineGroups[active,default:[]] += edge
                    }
                }
            case "s", "#": break
            default: throw GeometryIOError.unsupported("Unsupported OBJ directive: \(op). Curves, surfaces and holes are not supported.")
            }
        }
        try flush(); guard !entities.isEmpty else { throw GeometryIOError.invalid("OBJ contains no faces or lines.") }
        let doc = ModelDocument(entities:entities,name:url.deletingPathExtension().lastPathComponent); try doc.validate(); return doc
    }
    private static func local(_ path: String, relativeTo url: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(":"), !path.contains("\\"), !path.split(separator:"/").contains("..") else { throw GeometryIOError.invalid("OBJ sidecars must use safe local relative paths.") }
        let base = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let result = base.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard result.path.hasPrefix(base.path + "/") else { throw GeometryIOError.invalid("OBJ sidecar escapes its directory.") }; return result
    }
    private static func readMaterials(_ url: URL) throws -> [String:SurfaceMaterial] {
        let data = try PlainMesh.data(url); guard data.count <= 4*1024*1024, let text = String(data:data,encoding:.utf8) else { throw GeometryIOError.invalid("MTL must be UTF-8 text no larger than 4 MB.") }
        var result: [String:SurfaceMaterial] = [:], key = "", textureBytes = 0
        var diffuse: [String:[Double]] = [:], fallbackColors: [String:String] = [:]
        for line in text.components(separatedBy:.newlines) {
            let trimmed = line.trimmingCharacters(in:.whitespaces)
            let marker = "# SketchMakeFallbackColor "
            if trimmed.hasPrefix(marker) {
                let color = String(trimmed.dropFirst(marker.count))
                guard !key.isEmpty, color.range(of:"^#[0-9a-fA-F]{6}$",options:.regularExpression) != nil else { throw GeometryIOError.invalid("Invalid SketchMake MTL fallback color.") }
                fallbackColors[key] = color; continue
            }
            let f = line.split(separator:"#",maxSplits:1,omittingEmptySubsequences:false)[0].split(whereSeparator:{$0.isWhitespace}).map(String.init); guard let op = f.first else { continue }; let a = Array(f.dropFirst())
            if op == "newmtl" { key = a.joined(separator:" "); guard !key.isEmpty, key.count <= 200, result.count < 10_000 else { throw GeometryIOError.invalid("Invalid MTL material count/name.") }; result[key] = SurfaceMaterial(name:key); diffuse[key] = nil; fallbackColors[key] = nil }
            else if op == "Kd" { guard !key.isEmpty, a.count == 3 else { throw GeometryIOError.invalid("Invalid MTL diffuse color.") }; let rgb = try a.map(PlainMesh.number); guard rgb.allSatisfy({$0 >= 0 && $0 <= 1}) else { throw GeometryIOError.invalid("MTL diffuse channels must be between zero and one.") }; diffuse[key] = rgb; result[key]!.colorHex = try PlainMesh.hex(rgb.map { ($0*255).rounded() }) }
            else if op == "d" || op == "Tr" {
                guard !key.isEmpty,a.count==1 else {throw GeometryIOError.unsupported("MTL opacity needs one scalar; halo opacity is unsupported.")}
                let opacity=try PlainMesh.number(a[0])
                guard (0...1).contains(opacity) else {throw GeometryIOError.invalid("MTL opacity must be between zero and one.")}
                guard opacity == (op == "d" ? 1:0) else {throw GeometryIOError.unsupported("MTL material opacity cannot be preserved. Use opaque paint or an embedded-alpha diffuse PNG texture.")}
            }
            else if op == "map_d" {throw GeometryIOError.unsupported("Separate MTL opacity maps are unsupported. Combine alpha into the diffuse PNG texture.")}
            else if op == "map_Kd" { guard !key.isEmpty, a.count == 1 else { throw GeometryIOError.unsupported("MTL texture options or spaced paths are unsupported.") }; let bytes = try PlainMesh.data(local(a[0],relativeTo:url)); guard bytes.count <= SurfaceMaterial.maximumTextureBytes else { throw GeometryIOError.invalid("MTL texture exceeds 10 MB.") }; textureBytes += bytes.count; guard textureBytes <= 50*1024*1024 else { throw GeometryIOError.invalid("MTL textures exceed the 50 MB total limit.") }; result[key]!.textureData = bytes }
        }
        var embeddedBytes = 0
        for materialKey in result.keys.sorted() {
            var material = result[materialKey]!
            try material.validate()
            if let texture = material.textureData {
                let factor = (diffuse[materialKey] ?? [1,1,1]) + [1]
                material.textureData = try GLTFFormat.bakedTexture(texture,factor:factor,mode:"BLEND",cutoff:0.5)
                if let fallback = fallbackColors[materialKey] { material.colorHex = fallback }
            }
            embeddedBytes += material.textureData?.count ?? 0
            guard embeddedBytes <= 50*1024*1024 else { throw GeometryIOError.invalid("MTL transformed textures exceed the 50 MB total limit.") }
            result[materialKey] = material
        }
        return result
    }
    public static func write(_ document: ModelDocument, to url: URL, metersPerUnit: Double = 1, zUp: Bool = false, includeMaterials: Bool = true) throws {
        try PlainMesh.units(metersPerUnit); try document.validate()
        var text = "# SketchMake OBJ\n", mtl = "", offset = 1, uvOffset = 1, materialNumber = 0, vertices = 0, triangles = 0
        var textureFiles:[String:Data]=[:]
        let stem=url.deletingPathExtension().lastPathComponent
        let safeStem=stem.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? String($0) : "_" }.joined()
        // Preserve ordinary filenames, but do not let punctuation/Unicode
        // replacement or truncation alias another model's material resources.
        let basename:String
        if safeStem==stem,!safeStem.isEmpty,safeStem.utf8.count<=120 {basename=safeStem}
        else {basename=String(safeStem.prefix(100))+"_"+SHA256.hash(data:Data(stem.utf8)).prefix(8).map{String(format:"%02x",$0)}.joined()}
        let library = basename + ".mtl"
        if includeMaterials { text += "mtllib \(library)\n" }
        for (eIndex,e) in document.entities.enumerated() {
            let mesh = try e.triangulatedMesh(); vertices += mesh.vertices.count; triangles += mesh.triangles.count/3
            guard vertices <= 250_000, triangles <= 500_000 else { throw GeometryIOError.invalid("OBJ export exceeds geometry limits.") }
            let safeName = e.name.components(separatedBy: .whitespacesAndNewlines).joined(separator: "_").replacingOccurrences(of:"#",with:"_")
            text += "o \(safeName.isEmpty ? "Object_\(eIndex+1)" : safeName)\n"
            for v in mesh.vertices { let p = try PlainMesh.encode(v,metersPerUnit,zUp); text += "v \(p.x) \(p.y) \(p.z)\n" }
            if let uv = mesh.textureCoordinates { for t in uv { text += "vt \(t.u) \(1-t.v)\n" } }
            let base = e.surface ?? SurfaceMaterial(colorHex:e.colorHex)
            var assignment = Array(repeating:0,count:mesh.triangles.count/3)
            let appearances = [(base.colorHex,base.textureData,base.textureScale,base.textureRotation)] + base.faceOverrides.map { ($0.colorHex,$0.textureData,$0.textureScale,$0.textureRotation) }
            for (i,f) in base.faceOverrides.enumerated() { for t in f.triangleIndices { assignment[t] = i+1 } }
            var names: [String] = []
            if includeMaterials {
                for appearance in appearances {
                    materialNumber += 1; let name = "material_\(materialNumber)"; names.append(name); let rgb = PlainMesh.rgb(appearance.0)
                    mtl += "newmtl \(name)\n"
                    if appearance.1 != nil {
                        // Native images replace the fallback color; external OBJ consumers multiply Kd.
                        mtl += "# SketchMakeFallbackColor \(appearance.0)\nKd 1 1 1\n"
                    } else { mtl += "Kd \(Double(rgb[0])/255) \(Double(rgb[1])/255) \(Double(rgb[2])/255)\n" }
                    if let data = appearance.1 { let ext = data.starts(with:[0x89,0x50,0x4e,0x47]) ? "png" : "jpg"; let path = "\(basename)_\(name).\(ext)"; textureFiles[path]=data; mtl += "map_Kd \(path)\n" }
                }
            }
            var nextUV = uvOffset + (mesh.textureCoordinates?.count ?? 0)
            var generatedUV: [String:Int] = [:]
            var localEntity = e; localEntity.origin = Vec3(0,0,0); localEntity.rotation = 0
            let local = try localEntity.triangulatedMesh()
            for i in stride(from:0,to:mesh.triangles.count,by:3) {
                if includeMaterials { text += "usemtl \(names[assignment[i/3]])\n" }
                let appearance = appearances[assignment[i/3]]
                var uvIndices: [Int]? = mesh.textureCoordinates == nil ? nil : mesh.triangles[i..<i+3].map { $0 + uvOffset }
                if includeMaterials, appearance.1 != nil, mesh.textureCoordinates == nil || appearance.2 != 1 || appearance.3 != 0 {
                    let ids = Array(mesh.triangles[i..<i+3]), a = local.vertices[ids[0]], b = local.vertices[ids[1]], c = local.vertices[ids[2]]
                    let nx = (b.y-a.y)*(c.z-a.z)-(b.z-a.z)*(c.y-a.y)
                    let ny = (b.z-a.z)*(c.x-a.x)-(b.x-a.x)*(c.z-a.z)
                    let nz = (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)
                    uvIndices = []
                    for id in ids {
                        let p = local.vertices[id]
                        let t: TextureCoordinate
                        if let explicit = mesh.textureCoordinates { t = explicit[id] }
                        else if abs(nx) >= abs(ny) && abs(nx) >= abs(nz) { t = TextureCoordinate(u:p.z,v:p.y) }
                        else if abs(ny) >= abs(nz) { t = TextureCoordinate(u:p.x,v:p.z) }
                        else { t = TextureCoordinate(u:p.x,v:p.y) }
                        let cosine = cos(appearance.3), sine = sin(appearance.3)
                        let u = (cosine*t.u-sine*t.v)/appearance.2, v = (sine*t.u+cosine*t.v)/appearance.2
                        let key = "\(id)/\(u.bitPattern)/\(v.bitPattern)"
                        if let previous = generatedUV[key] { uvIndices!.append(previous) }
                        else { text += "vt \(u) \(1-v)\n"; generatedUV[key] = nextUV; uvIndices!.append(nextUV); nextUV += 1 }
                    }
                }
                text += "f " + mesh.triangles[i..<i+3].enumerated().map { corner,id in uvIndices.map { "\(id+offset)/\($0[corner])" } ?? "\(id+offset)" }.joined(separator:" ") + "\n"
            }
            if includeMaterials, !mesh.lineIndices.isEmpty { text += "usemtl \(names[0])\n" }
            for i in stride(from:0,to:mesh.lineIndices.count,by:2) { text += "l \(mesh.lineIndices[i]+offset) \(mesh.lineIndices[i+1]+offset)\n" }
            offset += mesh.vertices.count; uvOffset = nextUV
        }
        guard vertices > 0 else { throw GeometryIOError.invalid("No geometry to export.") }
        var files=try textureFiles.keys.sorted().map{(try local($0,relativeTo:url),textureFiles[$0]!)}
        if includeMaterials {files.append((try local(library,relativeTo:url),Data(mtl.utf8)))}
        files.append((url,Data(text.utf8)))
        try writeBundle(files)
    }

    /// Stage the complete validated bundle before changing existing files. Keep
    /// backups until the OBJ itself commits, so sidecars cannot corrupt a prior
    /// export when a later filesystem operation fails.
    private static func writeBundle(_ files:[(URL,Data)])throws {
        let manager=FileManager.default
        guard files.allSatisfy({$0.0.isFileURL}),Set(files.map{$0.0.resolvingSymlinksInPath().standardizedFileURL}).count==files.count,
              let destination=files.last?.0 else {throw GeometryIOError.invalid("OBJ bundle destinations must be distinct local files.")}
        var permissions:[URL:NSNumber]=[:]
        for (target,_) in files where manager.fileExists(atPath:target.path) {
            let attributes=try manager.attributesOfItem(atPath:target.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {throw GeometryIOError.invalid("An OBJ export destination is not a regular file.")}
            permissions[target]=attributes[.posixPermissions] as? NSNumber
        }
        let work=destination.deletingLastPathComponent().appendingPathComponent(".sketchmake-obj-"+UUID().uuidString,isDirectory:true)
        try manager.createDirectory(at:work,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var retainRecovery=false
        defer{if !retainRecovery {try? manager.removeItem(at:work)}}
        for (index,file) in files.enumerated() {
            let staged=work.appendingPathComponent("new-\(index)")
            try file.1.write(to:staged,options:.atomic)
            if let mode=permissions[file.0] {try manager.setAttributes([.posixPermissions:mode],ofItemAtPath:staged.path)}
        }
        var changed:[(target:URL,backup:URL?,installed:Bool)]=[]
        do {
            for (index,file) in files.enumerated() {
                var backup:URL?
                if manager.fileExists(atPath:file.0.path) {
                    let saved=work.appendingPathComponent("old-\(index)")
                    try manager.moveItem(at:file.0,to:saved);backup=saved
                }
                changed.append((file.0,backup,false))
                try manager.moveItem(at:work.appendingPathComponent("new-\(index)"),to:file.0)
                changed[changed.count-1].installed=true
            }
        } catch {
            for item in changed.reversed() {
                do {
                    if item.installed,manager.fileExists(atPath:item.target.path) {try manager.removeItem(at:item.target)}
                    if let backup=item.backup {try manager.moveItem(at:backup,to:item.target)}
                } catch {retainRecovery=true}
            }
            if retainRecovery {throw GeometryIOError.invalid("OBJ export failed and could not restore every file. Recovery copies remain in \(work.path).")}
            throw error
        }
    }
}
