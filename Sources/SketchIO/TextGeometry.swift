import AppKit
import Foundation
import ModelIO
import SceneKit
import SceneKit.ModelIO
import SketchCore

/// Bakes system-font glyph outlines and counters into an ordinary exportable mesh.
public enum TextGeometry {
    /// The lower-left-front of the text is placed at origin. Height is the actual
    /// glyph bounding height, not a font point size. Extrusion runs along local +Z.
    public static func make(text: String, height: Double, depth: Double, origin: Vec3, colorHex: String = "#353B3C") throws -> SketchEntity {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 2000,
              height.isFinite, depth.isFinite, height > 0, depth > 0, height <= 1000, depth <= 1000,
              [origin.x, origin.y, origin.z].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }),
              colorHex.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else {
            throw GeometryIOError.invalid("3D text needs 1–2000 characters, a positive finite height/depth up to 1000 m, a finite position and a #RRGGBB color.")
        }
        let generated = SCNText(string: text, extrusionDepth: 1)
        generated.font = NSFont.systemFont(ofSize: 100, weight: .regular)
        generated.flatness = 0.25
        generated.chamferRadius = 0
        // SCNText exposes an empty lazy vertex source until tessellated. The
        // system ModelIO bridge forces that tessellation on CPU, including holes.
        let baked = SCNGeometry(mdlMesh: MDLMesh(scnGeometry: generated))
        guard let source = baked.sources(for: .vertex).first, source.vectorCount > 0, source.vectorCount <= 250_000,
              source.usesFloatComponents, [4,8].contains(source.bytesPerComponent), source.componentsPerVector >= 3,
              source.dataStride >= source.bytesPerComponent * 3, source.dataOffset >= 0,
              source.dataOffset + (source.vectorCount-1) * source.dataStride + source.bytesPerComponent * 3 <= source.data.count else {
            throw GeometryIOError.invalid("The system font could not produce a supported 3D text mesh. Use fewer characters or another label.")
        }
        let positions: [Vec3] = source.data.withUnsafeBytes { buffer in
            func value(_ offset: Int) -> Double {
                if source.bytesPerComponent == 4 { return Double(Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))) }
                return Double(bitPattern: UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self)))
            }
            return (0..<source.vectorCount).map { index in
                let offset = source.dataOffset + index * source.dataStride
                return Vec3(value(offset),value(offset+source.bytesPerComponent),value(offset+source.bytesPerComponent*2))
            }
        }
        guard positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { throw GeometryIOError.invalid("The system text mesh contains invalid coordinates.") }
        let minX=positions.map(\.x).min()!,maxX=positions.map(\.x).max()!
        let minY=positions.map(\.y).min()!,maxY=positions.map(\.y).max()!
        let minZ=positions.map(\.z).min()!,maxZ=positions.map(\.z).max()!
        guard maxY-minY > 1e-9, maxZ-minZ > 1e-9, maxX-minX > 1e-9 else { throw GeometryIOError.invalid("This text has no usable glyph area or extrusion.") }
        let scale=height/(maxY-minY)
        let vertices=positions.map{Vec3(($0.x-minX)*scale,($0.y-minY)*scale,($0.z-minZ)*depth/(maxZ-minZ))}
        var triangles:[Int]=[]
        for element in baked.elements {
            guard element.primitiveType == .triangles,[1,2,4,8].contains(element.bytesPerIndex),element.data.count == element.primitiveCount*3*element.bytesPerIndex,
                  triangles.count + element.primitiveCount*3 <= 1_500_000 else { throw GeometryIOError.invalid("The system text mesh uses unsupported or excessive tessellation.") }
            for offset in stride(from:0,to:element.data.count,by:element.bytesPerIndex) {
                var index:UInt64=0
                for byte in 0..<element.bytesPerIndex { index |= UInt64(element.data[offset+byte]) << (byte*8) }
                guard index<UInt64(vertices.count) else {throw GeometryIOError.invalid("The system text mesh references a missing vertex.")}
                triangles.append(Int(index))
            }
        }
        let mesh=MeshData(vertices:vertices,triangles:triangles)
        try mesh.validate()
        let entity=SketchEntity(name: "3D Text: " + String(text.prefix(60)),kind:.mesh,origin:origin,width:(maxX-minX)*scale,depth:depth,height:height,colorHex:colorHex,mesh:mesh)
        try ModelDocument(entities:[entity]).validate()
        return entity
    }
}
