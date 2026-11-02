import AppKit
import Foundation
import ModelIO
import SceneKit
import SceneKit.ModelIO
import Darwin

import GardenStudioCore

/// Static triangle meshes through the installed Apple asset codecs. Native geometry is meters/Y-up.
public enum AppleAssetFormat {
    private static let extensions = ["usd", "usda", "usdc", "usdz"]
    public static var supportedImportExtensions: [String] { extensions.filter { MDLAsset.canImportFileExtension($0) && FileManager.default.isExecutableFile(atPath: "/usr/bin/usdcat") } }
    public static var supportedExportExtensions: [String] { extensions.filter { MDLAsset.canExportFileExtension($0) && $0 != "usdz" && FileManager.default.isExecutableFile(atPath: "/usr/bin/usdcat") } }

    public static func read(url: URL, metersPerUnit: Double? = nil, zUp: Bool? = nil) throws -> ModelDocument {
        let ext = url.pathExtension.lowercased()
        guard supportedImportExtensions.contains(ext) else { throw GeometryIOError.unsupported("The installed Apple asset reader does not support this extension.") }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 64*1024*1024 else { throw GeometryIOError.invalid("Apple assets must be smaller than 64 MB.") }
        if ext == "usdz" { try KMZFormat.validateArchive(Data(contentsOf: url)) }
        var unit = 1.0, up = false
        if ext != "abc" {
            let text = try usdText(url)
            guard !text.contains(".timeSamples"), !text.contains("SkelRoot"), !text.contains("Skeleton"), !text.contains("skel:"), !text.contains("clips ="), !text.contains("subLayers ="), !text.contains("references ="), !text.contains("payload ="), capture("\\b(references|payload|subLayers)\\s*=", text) == nil, capture("def\\s+(BasisCurves|NurbsCurves|Points|PointInstancer|Volume)\\b", text) == nil else { throw GeometryIOError.unsupported("Animated, skinned and composed USD stages are unsupported; export a flattened static mesh.") }
            let refs = try NSRegularExpression(pattern: "@([^@]*)@").matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in refs {
                let path = String(text[Range(match.range(at: 1), in: text)!])
                let target = url.deletingLastPathComponent().appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
                guard !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("%"), !path.contains(":"), !path.contains("\\"), !path.components(separatedBy: "/").contains(".."), target.path.hasPrefix(url.deletingLastPathComponent().resolvingSymlinksInPath().path + "/"), ["png","jpg","jpeg"].contains(target.pathExtension.lowercased()), (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap({ $0 }) ?? Int.max <= 10*1024*1024 else { throw GeometryIOError.unsupported("USD supports only contained local PNG/JPEG image references.") }
            }
            let preflight = try USDStaticPreflight(text)
            let metadata = try preflight.metadata()
            unit = metadata.unit; up = metadata.zUp
            try preflight.validateOpacity()
            try preflight.validateMeshes()

        }
        unit = metersPerUnit ?? unit; up = zUp ?? up
        guard unit.isFinite && unit > 0 && unit <= 1e9 else { throw GeometryIOError.invalid("Asset units must be finite and positive.") }
        let scene = try SCNScene(url: url, options: [.convertToYUp: false, .animationImportPolicy: SCNSceneSource.AnimationImportPolicy.doNotPlay])
        var entities: [GardenEntity] = [], total = 0
        func visit(_ node: SCNNode) throws {
            guard node.skinner == nil, node.morpher == nil, node.animationKeys.isEmpty else { throw GeometryIOError.unsupported("Skinned or animated meshes are unsupported.") }
            if let geometry = node.geometry {
                guard let source = geometry.sources(for: .vertex).first, source.usesFloatComponents, source.bytesPerComponent == 4, source.componentsPerVector >= 3, source.vectorCount <= 250_000 else { throw GeometryIOError.unsupported("Unsupported Apple asset vertex layout.") }
                func components(_ source: SCNGeometrySource, _ index: Int, _ count: Int) throws -> [Double] {
                    let offset = source.dataOffset + index*source.dataStride
                    guard source.usesFloatComponents, source.bytesPerComponent == 4, source.componentsPerVector >= count, offset >= 0, offset+count*4 <= source.data.count else { throw GeometryIOError.invalid("Invalid asset vertex buffer.") }
                    return (0..<count).map { component in source.data.withUnsafeBytes { Double($0.loadUnaligned(fromByteOffset: offset+component*4, as: Float.self)) } }
                }
                var vertices: [Vec3] = []
                for i in 0..<source.vectorCount {
                    let v = try components(source,i,3), p = node.convertPosition(SCNVector3(v[0],v[1],v[2]), to: nil)
                    vertices.append(up ? Vec3(Double(p.x)*unit,Double(p.z)*unit,-Double(p.y)*unit) : Vec3(Double(p.x)*unit,Double(p.y)*unit,Double(p.z)*unit))
                }
                var uv: [TextureCoordinate]? = nil
                if let s = geometry.sources(for: .texcoord).first {
                    guard s.vectorCount == vertices.count else { throw GeometryIOError.unsupported("Asset UVs must match the vertex layout.") }
                    uv = try (0..<s.vectorCount).map { let a = try components(s,$0,2); return TextureCoordinate(u:a[0],v:a[1]) }
                }
                for (part, element) in geometry.elements.enumerated() {
                    guard element.primitiveType == .triangles, [1,2,4].contains(element.bytesPerIndex), element.primitiveCount*3 <= 1_500_000, element.data.count >= element.primitiveCount*3*element.bytesPerIndex else { throw GeometryIOError.unsupported("Apple assets must contain triangulated static meshes.") }
                    var indices = (0..<(element.primitiveCount*3)).map { i -> Int in let p=i*element.bytesPerIndex; return (0..<element.bytesPerIndex).reduce(0) { $0 | Int(element.data[p+$1]) << ($1*8) } }
                    let m=node.simdWorldTransform
                    if simd_determinant(m) < 0 { for i in stride(from:0,to:indices.count,by:3) { indices.swapAt(i+1,i+2) } }
                    let material = geometry.materials.isEmpty ? nil : geometry.materials[part % geometry.materials.count]
                    if let material {
                        guard material.transparency.isFinite,material.transparency==1 else {throw GeometryIOError.unsupported("Scalar USD material opacity cannot be preserved; use opaque diffuse materials.")}
                        if let opacity=material.transparent.contents as? NSNumber {
                            guard opacity.doubleValue==1 else {throw GeometryIOError.unsupported("Scalar USD material opacity cannot be preserved; use opaque diffuse materials.")}
                        }
                    }
                    var paint = SurfaceMaterial(colorHex: "#B8B8B8")
                    if let color = material?.diffuse.contents as? NSColor {
                        // SceneKit tags USD shader floats as its display working space; USD Preview Surface uses linear RGB.
                        func channel(_ v: CGFloat) -> Int { let n = Double(v); let encoded = n <= 0.0031308 ? n*12.92 : 1.055*pow(n,1/2.4)-0.055; return Int((min(1,max(0,encoded))*255).rounded()) }
                        paint.colorHex=String(format:"#%02X%02X%02X",channel(color.redComponent),channel(color.greenComponent),channel(color.blueComponent))
                    }
                    else if let image = material?.diffuse.contents as? NSImage, let tiff=image.tiffRepresentation, let bitmap=NSBitmapImageRep(data:tiff), let png=bitmap.representation(using:.png,properties:[:]) { paint.textureData=png }
                    else if let resource = localTextureURL(material?.diffuse.contents, relativeTo: url.deletingLastPathComponent()) {
                        let image = resource.resolvingSymlinksInPath().standardizedFileURL
                        guard image.isFileURL, image.path.hasPrefix(url.deletingLastPathComponent().resolvingSymlinksInPath().path + "/"), ["png","jpg","jpeg"].contains(image.pathExtension.lowercased()), (try image.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 10*1024*1024 else { throw GeometryIOError.unsupported("Asset image must be a contained PNG/JPEG sidecar.") }
                        paint.textureData = try Data(contentsOf: image)
                    }
                    else if material?.diffuse.contents != nil { throw GeometryIOError.unsupported("The Apple asset uses an unsupported diffuse material layout.") }
                    let mesh=MeshData(vertices:vertices,triangles:indices,textureCoordinates:uv); try mesh.validate()
                    total += vertices.count
                    guard total <= 1_000_000, entities.count < 50_000 else { throw GeometryIOError.invalid("Apple asset exceeds supported mesh limits.") }
                    entities.append(GardenEntity(name:node.name ?? "Asset mesh",kind:.mesh,origin:Vec3(0,0,0),width:vertices.map(\.x).max()!-vertices.map(\.x).min()!,depth:vertices.map(\.z).max()!-vertices.map(\.z).min()!,height:vertices.map(\.y).max()!-vertices.map(\.y).min()!,colorHex:paint.colorHex,mesh:mesh,surface:paint))
                }
            }
            for child in node.childNodes { try visit(child) }
        }
        try visit(scene.rootNode)
        guard !entities.isEmpty else { throw GeometryIOError.invalid("Apple asset contains no supported mesh geometry.") }
        let result=ModelDocument(entities:entities,name:url.deletingPathExtension().lastPathComponent); try result.validate(); return result
    }

    public static func write(_ document: ModelDocument, to url: URL) throws {
        guard supportedExportExtensions.contains(url.pathExtension.lowercased()) else { throw GeometryIOError.unsupported("The installed Apple asset exporter does not support this extension.") }
        guard document.entities.allSatisfy({ $0.surface?.textureData == nil && ($0.surface?.faceOverrides.allSatisfy { $0.textureData == nil } ?? true) }) else { throw GeometryIOError.unsupported("Apple asset texture export is unavailable in the installed codec. Use COLLADA, KMZ, OBJ or glTF to preserve images.") }
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let dae=directory.appendingPathComponent("model.dae")
        try ColladaFormat.write(document,to:dae)
        guard let source = SCNSceneSource(data: try Data(contentsOf: dae), options: nil) else { throw GeometryIOError.invalid("Canonical COLLADA could not be decoded.") }
        let scene = try source.scene(options: [.convertToYUp: true, .convertUnitsToMeters: 1, .assetDirectoryURLs: [directory]])
        let asset=MDLAsset(); asset.upAxis=SIMD3<Float>(0,1,0)
        var nodes: [SCNNode] = []
        scene.rootNode.enumerateChildNodes { node, _ in if node.geometry != nil { nodes.append(node) } }
        guard nodes.count == document.entities.count else { throw GeometryIOError.unsupported("Apple export requires one static surface mesh per object.") }
        for (index, node) in nodes.enumerated() {
            let entity = document.entities[index]
            let original = try entity.triangulatedMesh()
            guard original.lineIndices.isEmpty else { throw GeometryIOError.unsupported("Apple asset export supports triangle surfaces; use COLLADA or KMZ for lines.") }
            let mesh = MDLMesh(scnGeometry: node.geometry!)
            mesh.name = node.name ?? "Mesh"
            mesh.transform = MDLTransform(matrix: node.simdWorldTransform)
            let base = entity.surface ?? SurfaceMaterial(colorHex: entity.colorHex)
            var paints = [base]
            paints += base.faceOverrides.map { SurfaceMaterial(colorHex: $0.colorHex, textureData: $0.textureData) }
            var assignment = Array(repeating: 0, count: original.triangles.count / 3)
            for (i, override) in base.faceOverrides.enumerated() { for face in override.triangleIndices { assignment[face] = i+1 } }
            let used = Set(assignment).sorted().map { paints[$0] }
            let submeshes = (mesh.submeshes as? [MDLSubmesh]) ?? []
            guard used.count == submeshes.count else { throw GeometryIOError.unsupported("Apple asset material groups could not be preserved.") }
            for (part, submesh) in submeshes.enumerated() {
                let paint = used[part]
                let hex = UInt32(paint.colorHex.dropFirst(), radix: 16)!
                func linear(_ value: UInt32) -> Float { let v = Float(value)/255; return v <= 0.04045 ? v/12.92 : pow((v+0.055)/1.055, 2.4) }
                let material = MDLMaterial(name: paint.name, scatteringFunction: MDLScatteringFunction())
                material.setProperty(MDLMaterialProperty(name: "baseColor", semantic: .baseColor, float3: SIMD3(linear((hex>>16)&255),linear((hex>>8)&255),linear(hex&255))))
                material.setProperty(MDLMaterialProperty(name: "emission", semantic: .emission, float3: SIMD3<Float>(repeating: 0)))
                submesh.material = material
            }
            asset.add(mesh)
        }
        let nativeOutput = directory.appendingPathComponent("native." + url.pathExtension).resolvingSymlinksInPath()
        try asset.export(to:nativeOutput)
        try Data(contentsOf: nativeOutput).write(to: url, options: .atomic)
        // Set explicit USD units/up-axis; ModelIO's static USD exports use centimeters metadata despite meter-valued vertices.
        if ["usd","usda","usdc"].contains(url.pathExtension.lowercased()) {
            var text=try usdText(url)
            // ModelIO emits generic float3 here; UsdPreviewSurface requires the color3f role.
            text=text.replacingOccurrences(of:"(?m)^(\\s*)float3 (inputs:(?:diffuseColor|emissiveColor))\\b",with:"$1color3f $2",options:.regularExpression)
            text=text.replacingOccurrences(of:"metersPerUnit\\s*=\\s*[0-9eE+.-]+",with:"metersPerUnit = 1",options:.regularExpression)
            if !text.contains("metersPerUnit") {
                if let opening = text.range(of: "(\n") { text.insert(contentsOf: "    metersPerUnit = 1\n", at: opening.upperBound) }
                else { text=text.replacingOccurrences(of:"#usda 1.0",with:"#usda 1.0\n( metersPerUnit = 1 )") }
            }
            let ascii=directory.appendingPathComponent("output.usda"); try text.write(to:ascii,atomically:true,encoding:.utf8)
            try convertUSD(ascii,to:url)
        }
    }
    private static func localTextureURL(_ contents: Any?, relativeTo directory: URL) -> URL? {
        if let url = contents as? URL { return url }
        if let path = contents as? String {
            // Native SceneKit returns filesystem paths as NSString for USD texture shaders.
            // The caller still checks resolved containment, file type and byte limits before reading.
            return URL(fileURLWithPath: path, relativeTo: directory)
        }
        return nil
    }
    private static func capture(_ pattern: String, _ text: String) -> String? {
        guard let match=try? NSRegularExpression(pattern:pattern).firstMatch(in:text,range:NSRange(text.startIndex...,in:text)), let range=Range(match.range(at:1),in:text) else { return nil }; return String(text[range])
    }
    private static func usdText(_ url: URL) throws -> String {
        if let text=try? String(contentsOf:url,encoding:.utf8),text.hasPrefix("#usda") { return text }
        let output=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".usda")
        defer { try? FileManager.default.removeItem(at:output) }
        try convertUSD(url,to:output)
        return try String(contentsOf:output,encoding:.utf8)
    }
    static func convertUSD(_ input: URL, to output: URL, maximumOutputBytes:Int = 128*1024*1024) throws {
        guard maximumOutputBytes>0 else {throw GeometryIOError.invalid("USD output byte limit must be positive.")}
        let p=Process(); p.executableURL=URL(fileURLWithPath:"/usr/bin/usdcat"); p.arguments=[input.path,"-o",output.path]; p.standardOutput=FileHandle.nullDevice; p.standardError=FileHandle.nullDevice
        func outputSize()->Int {((try? FileManager.default.attributesOfItem(atPath:output.path)[.size]) as? NSNumber)?.intValue ?? 0}
        func stop() {
            p.terminate()
            let deadline=Date().addingTimeInterval(0.2)
            while p.isRunning && Date()<deadline {Thread.sleep(forTimeInterval:0.01)}
            if p.isRunning {Darwin.kill(p.processIdentifier,SIGKILL)}
            p.waitUntilExit()
        }
        try p.run(); let deadline=Date().addingTimeInterval(20)
        while p.isRunning && Date()<deadline {
            if outputSize()>maximumOutputBytes {stop();throw GeometryIOError.invalid("Expanded USD exceeds its output byte limit.")}
            Thread.sleep(forTimeInterval:0.02)
        }
        if p.isRunning {stop();throw GeometryIOError.invalid("USD conversion timed out.")}
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw GeometryIOError.invalid("USD layer could not be inspected safely.") }
        guard outputSize()<=maximumOutputBytes else {throw GeometryIOError.invalid("Expanded USD exceeds its output byte limit.")}
    }
}

/// Lexical preflight runs before SceneKit, which may otherwise omit malformed USD prims.
private struct USDStaticPreflight {
    private struct Token { let text: String; let quoted: Bool }
    private let tokens: [Token]
    init(_ text: String) throws {
        let chars = Array(text)
        var result: [Token] = [], index = 0
        let punctuation = Set("[]{}()=,;")
        while index < chars.count {
            let c = chars[index]
            if c.isWhitespace { index += 1; continue }
            if c == "#" { while index < chars.count && chars[index] != "\n" { index += 1 }; continue }
            if c == "\"" || c == "'" || c == "@" {
                let delimiter = c
                let triple = c != "@" && index+2 < chars.count && chars[index+1] == c && chars[index+2] == c
                index += triple ? 3 : 1
                var value = "", closed = false
                while index < chars.count {
                    if chars[index] == delimiter && (!triple || (index+2 < chars.count && chars[index+1] == delimiter && chars[index+2] == delimiter)) {
                        index += triple ? 3 : 1; closed = true; break
                    }
                    if chars[index] == "\\" {
                        guard index+1 < chars.count else { throw GeometryIOError.invalid("Unterminated USD string.") }
                        index += 1
                    }
                    value.append(chars[index]); index += 1
                }
                guard closed else { throw GeometryIOError.invalid("Unterminated USD string or asset path.") }
                result.append(Token(text: value, quoted: true)); continue
            }
            if punctuation.contains(c) { result.append(Token(text: String(c), quoted: false)); index += 1; continue }
            let start = index
            while index < chars.count && !chars[index].isWhitespace && !punctuation.contains(chars[index]) && chars[index] != "#" && chars[index] != "\"" && chars[index] != "'" && chars[index] != "@" { index += 1 }
            result.append(Token(text: String(chars[start..<index]), quoted: false))
        }
        tokens = result
    }
    private func isToken(_ i: Int, _ text: String) -> Bool { tokens.indices.contains(i) && !tokens[i].quoted && tokens[i].text == text }
    private func closing(_ start: Int, _ open: String, _ close: String) throws -> Int {
        var depth = 0
        for i in start..<tokens.count {
            if isToken(i,open) { depth += 1 }
            if isToken(i,close) { depth -= 1; if depth == 0 { return i } }
        }
        throw GeometryIOError.invalid("Unbalanced USD delimiters.")
    }
    func metadata() throws -> (unit: Double, zUp: Bool) {
        var unit = 0.01, zUp = false
        guard isToken(0,"(") else { return (unit,zUp) }
        let end = try closing(0,"(",")")
        var nesting = 0, seen = Set<String>()
        for i in 1..<end {
            if ["(","[","{"].contains(tokens[i].text) && !tokens[i].quoted { nesting += 1 }
            if [")","]","}"].contains(tokens[i].text) && !tokens[i].quoted { nesting -= 1 }
            guard nesting == 0, !tokens[i].quoted, ["metersPerUnit","upAxis"].contains(tokens[i].text), isToken(i+1,"=") else { continue }
            guard i+2 < end, seen.insert(tokens[i].text).inserted else { throw GeometryIOError.invalid("Duplicate or incomplete USD stage metadata.") }
            if tokens[i].text == "metersPerUnit" {
                guard !tokens[i+2].quoted, let number = Double(tokens[i+2].text), number.isFinite, number > 0 else { throw GeometryIOError.invalid("Invalid USD stage units.") }
                unit = number
            } else {
                guard tokens[i+2].quoted, ["Y","Z"].contains(tokens[i+2].text) else { throw GeometryIOError.unsupported("USD upAxis must be Y or Z.") }
                zUp = tokens[i+2].text == "Z"
            }
        }
        return (unit,zUp)
    }
    private func numericArray(_ start: Int, dimension: Int) throws -> (values: [Double], end: Int) {
        guard isToken(start,"[") else { throw GeometryIOError.unsupported("USD mesh attributes must be explicit numeric arrays.") }
        let end = try closing(start,"[","]")
        var values: [Double] = [], tupleCount: Int? = nil
        for i in (start+1)..<end {
            if isToken(i,",") { continue }
            if isToken(i,"(") { guard dimension > 1, tupleCount == nil else { throw GeometryIOError.invalid("Malformed USD vector tuple.") }; tupleCount = 0; continue }
            if isToken(i,")") { guard tupleCount == dimension else { throw GeometryIOError.invalid("Malformed USD vector dimensions.") }; tupleCount = nil; continue }
            guard !tokens[i].quoted, let value = Double(tokens[i].text), value.isFinite, (dimension == 1 || tupleCount != nil) else { throw GeometryIOError.invalid("USD mesh contains invalid numeric data.") }
            values.append(value)
            if tupleCount != nil { tupleCount! += 1 }
            guard values.count <= 4_500_000 else { throw GeometryIOError.invalid("USD mesh attribute exceeds supported limits.") }
        }
        guard tupleCount == nil, values.count % dimension == 0 else { throw GeometryIOError.invalid("Incomplete USD vector data.") }
        return (values,end)
    }
    private func integers(_ values: [Double]) throws -> [Int] {
        try values.map { value in
            guard value >= 0, value <= 4_500_000, value.rounded() == value else { throw GeometryIOError.invalid("USD mesh indices/counts must be bounded nonnegative integers.") }
            return Int(value)
        }
    }
    /// Scalar/vertex opacity is not represented by SurfaceMaterial. Preserve alpha
    /// embedded in diffuse PNGs, but reject independent USD opacity/shader inputs.
    func validateOpacity() throws {
        for i in tokens.indices where !tokens[i].quoted {
            let name=tokens[i].text
            if name=="inputs:opacity.connect" || name=="inputs:opacityThreshold.connect" {
                throw GeometryIOError.unsupported("Connected USD opacity inputs cannot be preserved; use opaque diffuse materials.")
            }
            guard isToken(i+1,"=") else {continue}
            if name=="inputs:opacity" || name=="inputs:opacityThreshold" {
                guard tokens.indices.contains(i+2),!tokens[i+2].quoted,let value=Double(tokens[i+2].text),value.isFinite,(0...1).contains(value) else {throw GeometryIOError.invalid("USD opacity inputs need finite values between zero and one.")}
                guard value == (name=="inputs:opacity" ? 1:0) else {throw GeometryIOError.unsupported("Scalar or masked USD opacity cannot be preserved; use opaque diffuse materials.")}
            } else if name=="primvars:displayOpacity" {
                let values=try numericArray(i+2,dimension:1).values
                guard !values.isEmpty,values.allSatisfy({$0>=0 && $0<=1}) else {throw GeometryIOError.invalid("USD display opacity needs values between zero and one.")}
                guard values.allSatisfy({$0==1}) else {throw GeometryIOError.unsupported("USD display opacity cannot be preserved; use opaque diffuse materials.")}
            }
        }
    }
    func validateMeshes() throws {
        var cursor = 0, totalPoints = 0, meshCount = 0
        while cursor+2 < tokens.count {
            guard (isToken(cursor,"def") || isToken(cursor,"class") || isToken(cursor,"over")), isToken(cursor+1,"Mesh"), tokens[cursor+2].quoted else { cursor += 1; continue }
            var start = cursor+3
            if isToken(start,"(") { start = try closing(start,"(",")")+1 }
            guard isToken(start,"{") else { throw GeometryIOError.invalid("USD mesh has no body.") }
            let end = try closing(start,"{","}")
            var arrays: [String: [Double]] = [:], interpolations: [String:String] = [:]
            var i = start+1, nested = 0
            while i < end {
                if isToken(i,"{") || isToken(i,"(") { nested += 1 }
                if isToken(i,"}") || isToken(i,")") { nested -= 1 }
                if nested == 0, isToken(i,"="), i > start+1, !tokens[i-1].quoted {
                    let name = tokens[i-1].text
                    let uv = name.hasPrefix("primvars:") && (name == "primvars:st" || name == "primvars:uv" || name.hasSuffix(":indices") || (i >= 5 && ["texCoord2f","float2","double2","half2"].contains(tokens[i-4].text)))
                    if ["points","faceVertexCounts","faceVertexIndices"].contains(name) || uv {
                        guard arrays[name] == nil else { throw GeometryIOError.invalid("Duplicate USD mesh attribute.") }
                        let dimension = name == "points" ? 3 : (uv && !name.hasSuffix(":indices") ? 2 : 1)
                        let array = try numericArray(i+1,dimension:dimension)
                        arrays[name] = array.values; i = array.end
                        if isToken(i+1,"(") {
                            let metadataEnd = try closing(i+1,"(",")")
                            if i+2 < metadataEnd { for j in (i+2)..<metadataEnd where isToken(j,"interpolation") && isToken(j+1,"=") && j+2 < metadataEnd { interpolations[name] = tokens[j+2].text } }
                            i = metadataEnd
                        }
                    }
                }
                i += 1
            }
            guard let points = arrays["points"], !points.isEmpty, points.count/3 <= 250_000, let rawCounts = arrays["faceVertexCounts"], let rawIndices = arrays["faceVertexIndices"] else { throw GeometryIOError.invalid("USD mesh is missing explicit points or face tables.") }
            let counts = try integers(rawCounts), indices = try integers(rawIndices), pointCount = points.count/3
            guard !counts.isEmpty, counts.allSatisfy({ $0 >= 3 }), counts.reduce(0,+) == indices.count, indices.count <= 1_500_000, indices.allSatisfy({ $0 < pointCount }) else { throw GeometryIOError.invalid("USD face tables reference missing vertices or incomplete faces.") }
            for (name, values) in arrays where name.hasPrefix("primvars:") && !name.hasSuffix(":indices") {
                let count = values.count/2
                let indexed = arrays[name+":indices"]
                let interpolation = interpolations[name] ?? "constant"
                let expected: Int
                switch interpolation { case "constant": expected = 1; case "uniform": expected = counts.count; case "vertex","varying": expected = pointCount; case "faceVarying": expected = indices.count; default: throw GeometryIOError.unsupported("Unsupported USD UV interpolation.") }
                if let indexed {
                    let table = try integers(indexed)
                    guard table.count == expected, table.allSatisfy({ $0 < count }) else { throw GeometryIOError.invalid("USD UV indices reference missing coordinates.") }
                } else { guard count == expected else { throw GeometryIOError.invalid("USD UV count does not match its interpolation.") } }
            }
            for name in arrays.keys where name.hasPrefix("primvars:") && name.hasSuffix(":indices") {
                guard arrays[String(name.dropLast(8))] != nil else { throw GeometryIOError.unsupported("Indexed USD primvars require explicit supported coordinate data.") }
            }
            totalPoints += pointCount; meshCount += 1
            guard totalPoints <= 1_000_000, meshCount <= 50_000 else { throw GeometryIOError.invalid("USD stage exceeds geometry limits.") }
            cursor = start+1
        }
    }
}
