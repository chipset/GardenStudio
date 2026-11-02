import Foundation

public struct Vec3: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    /// SceneKit geometry and transforms are ultimately stored as Float32.
    var isRendererRepresentable: Bool {
        x.isFinite && y.isFinite && z.isFinite && Float(x).isFinite && Float(y).isFinite && Float(z).isFinite
    }
}

public enum ShapeKind: String, Codable, CaseIterable { case rectangle, circle, line, mesh }

public struct SketchEntity: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var kind: ShapeKind
    public var origin: Vec3
    public var width: Double
    public var depth: Double
    public var height: Double
    public var colorHex: String
    public var rotation: Double
    public var mesh: MeshData?
    public var metadata: EntityMetadata?
    public var profile: FaceProfile?
    public var profileExtrusion: Double?
    public var surface: SurfaceMaterial?
    public var woodworkItem: WoodworkItemRecord?

    public init(id: UUID = UUID(), name: String = "Shape", kind: ShapeKind, origin: Vec3, width: Double, depth: Double, height: Double = 0, colorHex: String = "#E7DCC8", rotation: Double = 0, mesh: MeshData? = nil, metadata: EntityMetadata? = nil, profile: FaceProfile? = nil, profileExtrusion: Double? = nil, surface: SurfaceMaterial? = nil, woodworkItem: WoodworkItemRecord? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.origin = origin
        self.width = width; self.depth = depth; self.height = height
        self.colorHex = colorHex; self.rotation = rotation; self.mesh = mesh
        self.metadata = metadata; self.profile = profile; self.profileExtrusion = profileExtrusion; self.surface = surface; self.woodworkItem = woodworkItem
    }
}

public enum ModelValidationError: Error, Equatable, LocalizedError {
    case invalidEntity(UUID, String)
    case duplicateIdentity(UUID)
    public var errorDescription: String? {
        switch self {
        case let .invalidEntity(_, reason): return reason
        case .duplicateIdentity: return "The document contains duplicate object identifiers."
        }
    }
}

public struct ModelDocument: Codable, Equatable {
    public var entities: [SketchEntity]
    public var name: String
    public var editor: EditorState?
    public var presentation: PresentationState?
    public init(entities: [SketchEntity] = [], name: String = "Untitled", editor: EditorState? = nil, presentation: PresentationState? = nil) { self.entities = entities; self.name = name; self.editor = editor; self.presentation = presentation }

    public func validate() throws {
        try validateEditorState()
        try presentation?.validate()
        guard entities.count <= 50_000 else { throw GeometryIOError.invalid("The document exceeds the 50,000 object limit.") }
        var identities = Set<UUID>()
        for entity in entities {
            guard identities.insert(entity.id).inserted else { throw ModelValidationError.duplicateIdentity(entity.id) }
            guard [entity.origin.x, entity.origin.y, entity.origin.z, entity.width, entity.depth, entity.height, entity.rotation].allSatisfy(\.isFinite) else {
                throw ModelValidationError.invalidEntity(entity.id, "Object coordinates and dimensions must be finite numbers.")
            }
            if entity.kind == .mesh {
                guard let mesh = entity.mesh, !mesh.vertices.isEmpty, (!mesh.triangles.isEmpty || !mesh.lineIndices.isEmpty),
                      mesh.vertices.count <= 250_000, mesh.triangles.count <= 1_500_000, mesh.lineIndices.count <= 1_000_000,
                      mesh.triangles.count % 3 == 0, mesh.lineIndices.count % 2 == 0,
                      mesh.vertices.allSatisfy({ [$0.x, $0.y, $0.z].allSatisfy(\.isFinite) }),
                      (mesh.triangles + mesh.lineIndices).allSatisfy({ mesh.vertices.indices.contains($0) }),
                      entity.width >= 0, entity.depth >= 0, entity.height >= 0 else {
                    throw ModelValidationError.invalidEntity(entity.id, "Imported mesh contains missing, invalid or oversized geometry.")
                }
                try mesh.validate()
            } else if entity.kind == .line {
                guard abs(entity.width) + abs(entity.depth) + abs(entity.height) > 0.000001 else {
                    throw ModelValidationError.invalidEntity(entity.id, "A line must have nonzero length.")
                }
            } else {
                guard entity.width > 0, entity.depth > 0, entity.height >= 0 else {
                    throw ModelValidationError.invalidEntity(entity.id, "Faces need positive width and depth; height cannot be negative.")
                }
            }
            try entity.validateRenderCoordinates()
            try entity.profile?.validate()
            try entity.woodworkItem?.validate()
            let triangleCount: Int
            switch entity.kind {
            case .mesh: triangleCount = (entity.mesh?.triangles.count ?? 0) / 3
            case .rectangle: triangleCount = entity.height > 0 ? 12 : 2
            case .circle: triangleCount = entity.height > 0 ? 188 : 46
            case .line: triangleCount = 0
            }
            try entity.surface?.validate(triangleCount: triangleCount)
            try entity.validateTextureTransformCoordinates()
            if entity.kind != .mesh && entity.mesh != nil {
                throw ModelValidationError.invalidEntity(entity.id, "Primitive objects cannot contain imported mesh geometry.")
            }
            guard entity.colorHex.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else {
                throw ModelValidationError.invalidEntity(entity.id, "Object colors must use #RRGGBB notation.")
            }
        }
    }

    public static var demo: ModelDocument {
        func block(_ name: String, _ x: Double, _ y: Double, _ z: Double, _ w: Double, _ d: Double, _ h: Double, _ color: String) -> SketchEntity {
            SketchEntity(name: name, kind: .rectangle, origin: Vec3(x, y, z), width: w, depth: d, height: h, colorHex: color)
        }
        return ModelDocument(entities: [
            block("Site", 0, -0.14, 0, 13, 11, 0.12, "#A9B59A"),
            block("Concrete terrace", 0.5, 0, 0.5, 9, 7, 0.18, "#D3CEC2"),
            block("Studio", -0.8, 0.18, -0.9, 5.4, 3.8, 2.9, "#E7DCC8"),
            block("Roof slab", -0.8, 3.08, -0.9, 5.8, 4.2, 0.18, "#EDEBE5"),
            block("Window left", -2.05, 1.0, 1.015, 1.4, 0.035, 1.5, "#7FABB5"),
            block("Window right", 0.45, 1.0, 1.015, 1.4, 0.035, 1.5, "#7FABB5"),
            block("Entry door", 1.92, 0.18, -0.2, 0.035, 1.0, 2.4, "#A27650"),
            block("Path", 0.8, -0.01, 3.6, 1.7, 3.6, 0.05, "#E6DFD2"),
            block("Planter", -4.5, 0, 2.6, 1.1, 1.7, 0.5, "#AB8764"),
            SketchEntity(name: "Tree canopy", kind: .circle, origin: Vec3(-4.5, 0.5, 2.6), width: 1.6, depth: 1.6, height: 1.9, colorHex: "#6F8F6C")
        ], name: "Garden Studio")
    }
}

/// A history transition carries the action's view intent separately from its
/// document snapshot. A captured camera is not evidence that geometry edited it.
public struct ModelHistoryChange {
    public let document: ModelDocument
    public let restoresCamera: Bool
}

public struct ModelHistory {
    private var undoStack: [ModelHistoryChange] = []
    private var redoStack: [ModelHistoryChange] = []
    public init() {}
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public mutating func record(_ document: ModelDocument, restoresCamera: Bool = false) {
        if undoStack.last?.document != document || undoStack.last?.restoresCamera != restoresCamera {
            undoStack.append(ModelHistoryChange(document: document, restoresCamera: restoresCamera))
        }
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    public mutating func undoChange(current: ModelDocument) -> ModelHistoryChange? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(ModelHistoryChange(document: current, restoresCamera: previous.restoresCamera))
        return previous
    }

    public mutating func redoChange(current: ModelDocument) -> ModelHistoryChange? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(ModelHistoryChange(document: current, restoresCamera: next.restoresCamera))
        return next
    }

    public mutating func undo(current: ModelDocument) -> ModelDocument? {
        undoChange(current: current)?.document
    }

    public mutating func redo(current: ModelDocument) -> ModelDocument? {
        redoChange(current: current)?.document
    }
}
