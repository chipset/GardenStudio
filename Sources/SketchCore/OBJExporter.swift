import Foundation

extension ModelDocument {
    /// Exports geometry in meters, with globally indexed polygon faces and line elements.
    public func objString() throws -> String {
        try validate()
        var output = ["# Sketch Make OBJ — meters, Y up"]
        var vertexOffset = 1
        func number(_ value: Double) -> String {
            let clean = abs(value) < 0.0000005 ? 0 : value
            return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), clean)
                .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
        }
        for entity in entities {
            let safeName = entity.name.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: "_")
            output.append("o \(safeName.isEmpty ? entity.id.uuidString : safeName)")
            var vertices: [Vec3] = []
            var faces: [[Int]] = []
            if entity.kind == .mesh, let mesh = entity.mesh {
                vertices = mesh.vertices
                faces = stride(from: 0, to: mesh.triangles.count, by: 3).map { Array(mesh.triangles[$0..<$0+3]) }
            } else if entity.kind == .line {
                vertices = [Vec3(0, 0, 0), Vec3(entity.width, entity.height, entity.depth)]
            } else {
                let base: [Vec3]
                if entity.kind == .rectangle {
                    base = [Vec3(-entity.width / 2, 0, -entity.depth / 2), Vec3(entity.width / 2, 0, -entity.depth / 2), Vec3(entity.width / 2, 0, entity.depth / 2), Vec3(-entity.width / 2, 0, entity.depth / 2)]
                } else {
                    base = (0..<32).map { index in
                        let angle = Double(index) * .pi * 2 / 32
                        return Vec3(cos(angle) * entity.width / 2, 0, sin(angle) * entity.depth / 2)
                    }
                }
                vertices = base
                let count = base.count
                if entity.height > 0 {
                    vertices += base.map { Vec3($0.x, entity.height, $0.z) }
                    faces.append(Array(0..<count))
                    faces.append(Array(count..<(count * 2)).reversed())
                    for index in 0..<count {
                        let next = (index + 1) % count
                        faces.append([index, index + count, next + count, next])
                    }
                } else {
                    faces.append(Array(0..<count).reversed())
                }
            }
            let cosine = cos(entity.rotation), sine = sin(entity.rotation)
            for vertex in vertices {
                let x = entity.origin.x + cosine * vertex.x + sine * vertex.z
                let z = entity.origin.z - sine * vertex.x + cosine * vertex.z
                output.append("v \(number(x)) \(number(entity.origin.y + vertex.y)) \(number(z))")
            }
            if entity.kind == .line {
                output.append("l \(vertexOffset) \(vertexOffset + 1)")
            } else {
                output += faces.map { "f " + $0.map { String($0 + vertexOffset) }.joined(separator: " ") }
            }
            if entity.kind == .mesh, let mesh = entity.mesh {
                for index in stride(from: 0, to: mesh.lineIndices.count, by: 2) {
                    output.append("l \(mesh.lineIndices[index] + vertexOffset) \(mesh.lineIndices[index + 1] + vertexOffset)")
                }
            }
            vertexOffset += vertices.count
        }
        return output.joined(separator: "\n") + "\n"
    }
}
