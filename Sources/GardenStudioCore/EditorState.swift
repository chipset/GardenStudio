import Foundation

public struct EntityMetadata: Codable, Equatable {
    public var isHidden: Bool
    public var isLocked: Bool
    public var layerID: UUID?
    public var groupID: UUID?
    public var componentPartID: UUID?
    public init(isHidden: Bool = false, isLocked: Bool = false, layerID: UUID? = nil, groupID: UUID? = nil, componentPartID: UUID? = nil) {
        self.isHidden = isHidden; self.isLocked = isLocked; self.layerID = layerID
        self.groupID = groupID; self.componentPartID = componentPartID
    }
}

public struct ModelLayer: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var isVisible: Bool
    public init(id: UUID = UUID(), name: String, isVisible: Bool = true) { self.id = id; self.name = name; self.isVisible = isVisible }
}

public struct ModelGroup: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var parentID: UUID?
    public var componentID: UUID?
    public var origin: Vec3
    public var rotation: Double
    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil, componentID: UUID? = nil, origin: Vec3 = Vec3(0,0,0), rotation: Double = 0) {
        self.id = id; self.name = name; self.parentID = parentID; self.componentID = componentID; self.origin = origin; self.rotation = rotation
    }
}

public struct EditorState: Codable, Equatable {
    public var snapStep: Double
    public var units: String
    public var layers: [ModelLayer]
    public var groups: [ModelGroup]
    public init(snapStep: Double = 0.001, units: String = "m", layers: [ModelLayer] = [], groups: [ModelGroup] = []) {
        self.snapStep = snapStep; self.units = units; self.layers = layers; self.groups = groups
    }
}

extension ModelDocument {
    public func effectiveSelection(_ ids: Set<UUID>) -> Set<UUID> {
        let groups = Dictionary((editor?.groups ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func root(_ group: UUID) -> UUID {
            var current = group, visited = Set<UUID>()
            while let parent = groups[current]?.parentID, visited.insert(current).inserted { current = parent }
            return current
        }
        let selectedGroups = Set(entities.filter { ids.contains($0.id) }.compactMap { $0.metadata?.groupID }.map(root))
        return Set(entities.filter { ids.contains($0.id) || $0.metadata?.groupID.map { selectedGroups.contains(root($0)) } == true }.map(\.id))
    }

    /// Resolves selection inside a group without selecting its ancestors or unrelated geometry.
    public func effectiveSelection(_ ids: Set<UUID>, editingGroupID: UUID?) -> Set<UUID> {
        guard let context = editingGroupID else { return effectiveSelection(ids) }
        let groups = Dictionary((editor?.groups ?? []).map { ($0.id,$0) }, uniquingKeysWith: { first,_ in first })
        guard groups[context] != nil else { return [] }
        func branch(_ entity: GardenEntity) -> UUID? {
            guard var current = entity.metadata?.groupID else { return nil }
            if current == context { return nil }
            var seen = Set<UUID>()
            while seen.insert(current).inserted, let parent = groups[current]?.parentID {
                if parent == context { return current }
                current = parent
            }
            return nil
        }
        let selectedBranches = Set(entities.filter { ids.contains($0.id) }.compactMap(branch))
        return Set(entities.filter { entity in
            if entity.metadata?.groupID == context { return ids.contains(entity.id) }
            return branch(entity).map { selectedBranches.contains($0) } ?? false
        }.map(\.id))
    }

    public func validateEditorState() throws {
        let layers = editor?.layers ?? [], groups = editor?.groups ?? []
        guard (editor?.snapStep ?? 0.001).isFinite, (editor?.snapStep ?? 0.001) > 0,
              ["m", "cm", "mm", "in", "ft"].contains(editor?.units ?? "m"), layers.count <= 10_000, groups.count <= 50_000,
              Set(layers.map(\.id)).count == layers.count, Set(groups.map(\.id)).count == groups.count else {
            throw GeometryIOError.invalid("Editor settings contain invalid units, snapping, or duplicate organization identifiers.")
        }
        let groupMap = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        let layerIDs = Set(layers.map(\.id))
        var groupDepths:[UUID:Int]=[:]
        for group in groups {
            guard [group.origin.x,group.origin.y,group.origin.z,group.rotation].allSatisfy(\.isFinite) else { throw GeometryIOError.invalid("Group transformation is invalid.") }
            var seen = Set<UUID>(), path:[UUID]=[], current: UUID? = group.id
            while let id = current, groupDepths[id] == nil {
                guard seen.insert(id).inserted, let node = groupMap[id] else { throw GeometryIOError.invalid("Group hierarchy contains a cycle or a missing parent.") }
                path.append(id)
                guard path.count<=256 else {throw GeometryIOError.invalid("Group hierarchy exceeds the 256-level nesting limit.")}
                current = node.parentID
            }
            var depth=current.flatMap{groupDepths[$0]} ?? 0
            for id in path.reversed() {
                depth+=1
                guard depth<=256 else {throw GeometryIOError.invalid("Group hierarchy exceeds the 256-level nesting limit.")}
                groupDepths[id]=depth
            }
        }
        var componentParts:[UUID:Set<UUID>]=[:]
        for entity in entities {
            if let layer = entity.metadata?.layerID, !layerIDs.contains(layer) { throw ModelValidationError.invalidEntity(entity.id,"Object refers to a missing layer.") }
            if let group = entity.metadata?.groupID, groupMap[group] == nil { throw ModelValidationError.invalidEntity(entity.id,"Object refers to a missing group.") }
            if let part=entity.metadata?.componentPartID {
                var current=entity.metadata?.groupID
                while let id=current,let group=groupMap[id] {
                    if group.componentID != nil {
                        guard componentParts[id,default:[]].insert(part).inserted else {
                            throw ModelValidationError.invalidEntity(entity.id,"A component instance contains duplicate part identifiers.")
                        }
                        break
                    }
                    current=group.parentID
                }
            }
            if let amount = entity.profileExtrusion, (!amount.isFinite || abs(amount) > 1_000_000) { throw ModelValidationError.invalidEntity(entity.id,"Profile extrusion must be finite and within one million meters.") }
        }
    }
}

extension GardenEntity {
    public func isVisible(in document: ModelDocument) -> Bool {
        if metadata?.isHidden == true { return false }
        if let layerID = metadata?.layerID { return document.editor?.layers.first { $0.id == layerID }?.isVisible ?? false }
        return true
    }
    public func isEditable(in document: ModelDocument) -> Bool { metadata?.isLocked != true }
}
