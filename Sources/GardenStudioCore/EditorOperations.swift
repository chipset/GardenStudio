import Foundation

public enum EditorOperations {
    private static func checked(_ document: ModelDocument) throws -> ModelDocument { try document.validate(); return document }
    private static func editable(_ document: ModelDocument, _ ids: Set<UUID>, editingGroupID: UUID? = nil) -> Set<UUID> {
        let expanded = document.effectiveSelection(ids,editingGroupID:editingGroupID)
        return Set(document.entities.filter { expanded.contains($0.id) && $0.isEditable(in: document) }.map(\.id))
    }
    private static func finite(_ vector: Vec3) -> Bool { [vector.x,vector.y,vector.z].allSatisfy(\.isFinite) }
    private static func add(_ a: Vec3,_ b: Vec3) -> Vec3 { Vec3(a.x+b.x,a.y+b.y,a.z+b.z) }
    private static func subtract(_ a: Vec3,_ b: Vec3) -> Vec3 { Vec3(a.x-b.x,a.y-b.y,a.z-b.z) }
    private static func rotatePoint(_ p: Vec3, _ radians: Double) -> Vec3 {
        Vec3(cos(radians)*p.x+sin(radians)*p.z,p.y,-sin(radians)*p.x+cos(radians)*p.z)
    }
    /// Compose bounded trigonometric phases before addition. Adding a small
    /// edit directly to a large stored angle can round away the entire edit.
    private static func rotationPhase(_ radians: Double) -> Double { atan2(sin(radians),cos(radians)) }
    private static func composedRotation(_ first: Double, _ second: Double) -> Double {
        rotationPhase(rotationPhase(first)+rotationPhase(second))
    }
    private static func nearestComponent(_ groupID:UUID?,in groups:[ModelGroup])->ModelGroup? {
        let byID=Dictionary(groups.map{($0.id,$0)},uniquingKeysWith:{first,_ in first})
        var current=groupID,visited=Set<UUID>()
        while let id=current,visited.insert(id).inserted,let group=byID[id] {
            if group.componentID != nil{return group}
            current=group.parentID
        }
        return nil
    }
    private static func center(_ document: ModelDocument, _ ids: Set<UUID>) throws -> Vec3 {
        var low = Vec3(.infinity,.infinity,.infinity), high = Vec3(-.infinity,-.infinity,-.infinity)
        for entity in document.entities where ids.contains(entity.id) {
            for p in try entity.triangulatedMesh().vertices {
                low = Vec3(min(low.x,p.x),min(low.y,p.y),min(low.z,p.z))
                high = Vec3(max(high.x,p.x),max(high.y,p.y),max(high.z,p.z))
            }
        }
        return low.x.isFinite ? Vec3((low.x+high.x)/2,(low.y+high.y)/2,(low.z+high.z)/2) : Vec3(0,0,0)
    }
    private static func affectedGroups(_ document: ModelDocument, _ ids: Set<UUID>, editingGroupID: UUID? = nil) -> Set<UUID> {
        let groups = document.editor?.groups ?? []
        var result = Set<UUID>(), contextAncestors = Set<UUID>()
        var current = editingGroupID
        while let id = current, contextAncestors.insert(id).inserted { current = groups.first { $0.id == id }?.parentID }
        for group in groups where !contextAncestors.contains(group.id) {
            let members = document.entities.filter { entity in
                var next = entity.metadata?.groupID, visited = Set<UUID>()
                while let id = next, visited.insert(id).inserted {
                    if id == group.id { return true }
                    next = groups.first { $0.id == id }?.parentID
                }
                return false
            }
            if !members.isEmpty && members.allSatisfy({ ids.contains($0.id) }) { result.insert(group.id) }
        }
        return result
    }

    public static func translate(document: ModelDocument, ids: Set<UUID>, delta: Vec3, editingGroupID: UUID? = nil) throws -> ModelDocument {
        guard finite(delta) else { throw GeometryIOError.invalid("Translation must contain finite distances.") }
        try document.validate()
        let selected = editable(document,ids,editingGroupID:editingGroupID), groups = affectedGroups(document,editable(document,ids,editingGroupID:editingGroupID),editingGroupID:editingGroupID)
        var result = document
        for index in result.entities.indices where selected.contains(result.entities[index].id) { result.entities[index].origin = add(result.entities[index].origin,delta) }
        if var editor = result.editor {
            for i in editor.groups.indices where groups.contains(editor.groups[i].id) { editor.groups[i].origin = add(editor.groups[i].origin,delta) }
            result.editor = editor
        }
        return try checked(result)
    }

    public static func rotate(document: ModelDocument, ids: Set<UUID>, radians: Double, editingGroupID: UUID? = nil) throws -> ModelDocument {
        guard radians.isFinite else { throw GeometryIOError.invalid("Rotation must be finite.") }
        try document.validate()
        let selected = editable(document,ids,editingGroupID:editingGroupID), pivot = try center(document,editable(document,ids,editingGroupID:editingGroupID)), groups = affectedGroups(document,editable(document,ids,editingGroupID:editingGroupID),editingGroupID:editingGroupID)
        var result = document
        for index in result.entities.indices where selected.contains(result.entities[index].id) {
            result.entities[index].origin = add(pivot,rotatePoint(subtract(result.entities[index].origin,pivot),radians))
            result.entities[index].rotation = composedRotation(result.entities[index].rotation,radians)
        }
        if var editor = result.editor {
            for i in editor.groups.indices where groups.contains(editor.groups[i].id) {
                editor.groups[i].origin = add(pivot,rotatePoint(subtract(editor.groups[i].origin,pivot),radians))
                editor.groups[i].rotation = composedRotation(editor.groups[i].rotation,radians)
            }
            result.editor = editor
        }
        return try checked(result)
    }

    public static func scale(document: ModelDocument, ids: Set<UUID>, factors: Vec3, editingGroupID: UUID? = nil) throws -> ModelDocument {
        guard finite(factors), [factors.x,factors.y,factors.z].allSatisfy({ abs($0) >= 0.000001 && abs($0) <= 1_000_000 }) else {
            throw GeometryIOError.invalid("Scale factors must be finite, nonzero values between 0.000001 and 1000000 in magnitude.")
        }
        try document.validate()
        // Identity scaling must preserve editable primitives, profile metadata
        // and component links instead of baking them into a new mesh instance.
        if factors == Vec3(1,1,1) { return document }
        let selected = editable(document,ids,editingGroupID:editingGroupID), pivot = try center(document,editable(document,ids,editingGroupID:editingGroupID))
        var result = document
        for index in result.entities.indices where selected.contains(result.entities[index].id) {
            var entity = result.entities[index]
            var mesh = try entity.meshForTransformBaking()
            mesh.vertices = mesh.vertices.map { p in Vec3(pivot.x+(p.x-pivot.x)*factors.x,pivot.y+(p.y-pivot.y)*factors.y,pivot.z+(p.z-pivot.z)*factors.z) }
            if factors.x*factors.y*factors.z < 0 {
                for start in stride(from:0,to:mesh.triangles.count,by:3) { mesh.triangles.swapAt(start+1,start+2) }
            }
            let origin = Vec3(pivot.x+(entity.origin.x-pivot.x)*factors.x,pivot.y+(entity.origin.y-pivot.y)*factors.y,pivot.z+(entity.origin.z-pivot.z)*factors.z)
            mesh.vertices = mesh.vertices.map { subtract($0,origin) }
            let xs = mesh.vertices.map(\.x), ys = mesh.vertices.map(\.y), zs = mesh.vertices.map(\.z)
            entity.kind = .mesh; entity.mesh = mesh; entity.origin = origin; entity.rotation = 0
            entity.width = (xs.max() ?? 0)-(xs.min() ?? 0); entity.height = (ys.max() ?? 0)-(ys.min() ?? 0); entity.depth = (zs.max() ?? 0)-(zs.min() ?? 0)
            // Baked geometry remains exact, including holes; profile editing resumes by drawing a new profile.
            entity.profile = nil; entity.profileExtrusion = nil
            result.entities[index] = entity
        }
        if var editor = result.editor {
            let groups = affectedGroups(document,selected,editingGroupID:editingGroupID)
            for i in editor.groups.indices where groups.contains(editor.groups[i].id) {
                let p = editor.groups[i].origin
                editor.groups[i].origin = Vec3(pivot.x+(p.x-pivot.x)*factors.x,pivot.y+(p.y-pivot.y)*factors.y,pivot.z+(p.z-pivot.z)*factors.z)
                // Instance frames retain translation/rotation, not affine scale. Baking a whole
                // component makes that instance unique so later linked edits cannot erase it.
                // The active editing context is excluded by affectedGroups, retaining part links.
                if editor.groups[i].componentID != nil { editor.groups[i].componentID = UUID() }
            }
            result.editor = editor
        }
        return try checked(result)
    }

    public static func mirror(document: ModelDocument, ids: Set<UUID>, axis: String, editingGroupID: UUID? = nil) throws -> ModelDocument {
        let factors: Vec3
        switch axis.lowercased() { case "x": factors = Vec3(-1,1,1); case "y": factors = Vec3(1,-1,1); case "z": factors = Vec3(1,1,-1); default: throw GeometryIOError.invalid("Mirror axis must be x, y or z.") }
        return try scale(document:document,ids:ids,factors:factors,editingGroupID:editingGroupID)
    }

    /// Moves coincident selected mesh vertices in world space without changing face or UV indices.
    public static func moveVertex(document:ModelDocument,ids:Set<UUID>,at point:Vec3,delta:Vec3,tolerance:Double=1e-6,editingGroupID:UUID?=nil)throws->ModelDocument {
        try document.validate()
        guard finite(point),finite(delta),tolerance.isFinite,tolerance>0,tolerance<=0.01 else{throw GeometryIOError.invalid("Vertex edits need finite coordinates and a tolerance between zero and 10 mm.")}
        let selected=editable(document,ids,editingGroupID:editingGroupID)
        var result=document,changed=false
        for index in result.entities.indices where selected.contains(result.entities[index].id) {
            let source=document.entities[index]
            guard source.kind == .mesh,source.isEditable(in:document),var world=try? source.triangulatedMesh() else{continue}
            let matches=world.vertices.indices.filter{let d=subtract(world.vertices[$0],point);return hypot(hypot(d.x,d.y),d.z)<=tolerance}
            guard !matches.isEmpty else{continue}
            for vertex in matches {world.vertices[vertex]=add(world.vertices[vertex],delta)}
            world.vertices=world.vertices.map{rotatePoint(subtract($0,source.origin),-source.rotation)}
            var replacement=source
            replacement.mesh=world;replacement.profile=nil;replacement.profileExtrusion=nil
            result.entities[index]=replacement;changed=true
        }
        guard changed else{throw GeometryIOError.unsupported("Control-drag a vertex on a selected editable mesh.")}
        return try checked(result)
    }

    public static func duplicate(document: ModelDocument, ids: Set<UUID>, count: Int, delta: Vec3, editingGroupID: UUID? = nil) throws -> ModelDocument {
        try document.validate()
        guard count > 0, count <= 1000, finite(delta) else { throw GeometryIOError.invalid("An array needs 1–1000 copies and a finite offset.") }
        let selected = editable(document,ids,editingGroupID:editingGroupID), originals = document.entities.filter { selected.contains($0.id) }
        guard document.entities.count + originals.count*count <= 50_000 else { throw GeometryIOError.invalid("The array exceeds the 50,000 object limit.") }
        let groupIDs = affectedGroups(document,selected,editingGroupID:editingGroupID)
        let groupsByID=Dictionary(uniqueKeysWithValues:(document.editor?.groups ?? []).map{($0.id,$0)})
        func componentOwner(_ entity: GardenEntity) -> UUID? {
            var current=entity.metadata?.groupID
            while let id=current,let group=groupsByID[id] {
                if group.componentID != nil {return id}
                current=group.parentID
            }
            return nil
        }
        var result = document
        for copy in 1...count {
            let offset = Vec3(delta.x*Double(copy),delta.y*Double(copy),delta.z*Double(copy))
            let remap = Dictionary(uniqueKeysWithValues: groupIDs.map { ($0,UUID()) })
            for original in originals {
                var entity = original; entity.id = UUID(); entity.origin = add(entity.origin,offset)
                if let group = entity.metadata?.groupID {
                    entity.metadata?.groupID = remap[group] ?? editingGroupID
                    // A copied ordinary subgroup remains in the same enclosing
                    // component instance. Its new entities need new part IDs;
                    // only copying the owning component creates a linked peer.
                    if let owner=componentOwner(original),remap[owner] == nil,entity.metadata?.componentPartID != nil {
                        entity.metadata?.componentPartID = UUID()
                    }
                }
                // Ungrouped copies are independent objects, grouped component copies keep their part identities.
                if entity.metadata?.groupID == nil { entity.metadata?.componentPartID = nil }
                result.entities.append(entity)
            }
            if var editor = result.editor {
                for original in document.editor?.groups ?? [] where groupIDs.contains(original.id) {
                    var group = original; group.id = remap[original.id]!
                    group.parentID = original.parentID.flatMap { remap[$0] } ?? editingGroupID
                    group.origin = add(group.origin,offset)
                    editor.groups.append(group)
                }
                result.editor = editor
            }
        }
        return try checked(result)
    }

    /// Part IDs belong to the nearest component instance, independent of ordinary group nesting.
    /// Hierarchy changes preserve IDs only while that owner stays the same. Moving geometry into
    /// a different definition needs fresh identities to avoid linking unrelated siblings.
    private static func reconcilePartIdentities(original: ModelDocument, result: inout ModelDocument, ids: Set<UUID>) {
        let oldGroups = Dictionary(uniqueKeysWithValues:(original.editor?.groups ?? []).map { ($0.id,$0) })
        let newGroups = Dictionary(uniqueKeysWithValues:(result.editor?.groups ?? []).map { ($0.id,$0) })
        let oldEntities = Dictionary(uniqueKeysWithValues:original.entities.map { ($0.id,$0) })
        func owner(_ entity: GardenEntity, groups: [UUID:ModelGroup]) -> UUID? {
            var current = entity.metadata?.groupID, seen = Set<UUID>()
            while let id = current, seen.insert(id).inserted, let group = groups[id] {
                if group.componentID != nil { return id }
                current = group.parentID
            }
            return nil
        }
        for index in result.entities.indices where ids.contains(result.entities[index].id) {
            let entity = result.entities[index]
            let previousOwner = oldEntities[entity.id].flatMap { owner($0,groups:oldGroups) }
            let nextOwner = owner(entity,groups:newGroups)
            if nextOwner == nil { result.entities[index].metadata?.componentPartID = nil }
            else if previousOwner != nextOwner || entity.metadata?.componentPartID == nil {
                result.entities[index].metadata?.componentPartID = UUID()
            }
        }
    }

    public static func group(document: ModelDocument, ids: Set<UUID>, name: String, component: Bool, editingGroupID: UUID? = nil) throws -> ModelDocument {
        try document.validate()
        let selected = editable(document,ids,editingGroupID:editingGroupID)
        guard !selected.isEmpty else { return document }
        let groupIDs = affectedGroups(document,selected,editingGroupID:editingGroupID)
        let newGroup = ModelGroup(name:name.isEmpty ? (component ? "Component" : "Group") : name,parentID:editingGroupID,componentID:component ? UUID() : nil,origin:try center(document,selected))
        var result = document, editor = document.editor ?? EditorState()
        let roots = groupIDs.filter { id in !groupIDs.contains(editor.groups.first { $0.id == id }?.parentID ?? UUID()) }
        for index in editor.groups.indices where roots.contains(editor.groups[index].id) { editor.groups[index].parentID = newGroup.id }
        editor.groups.append(newGroup)
        for index in result.entities.indices where selected.contains(result.entities[index].id) {
            var metadata = result.entities[index].metadata ?? EntityMetadata()
            if metadata.groupID == nil || !groupIDs.contains(metadata.groupID!) { metadata.groupID = newGroup.id }
            result.entities[index].metadata = metadata
        }
        result.editor = editor
        reconcilePartIdentities(original:document,result:&result,ids:selected)
        return try checked(result)
    }

    public static func explode(document: ModelDocument, ids: Set<UUID>, editingGroupID: UUID? = nil) throws -> ModelDocument {
        try document.validate()
        let selected = editable(document,ids,editingGroupID:editingGroupID), affected = affectedGroups(document,editable(document,ids,editingGroupID:editingGroupID),editingGroupID:editingGroupID)
        var result = document
        guard var editor = result.editor else { return document }
        let roots = editor.groups.filter { affected.contains($0.id) && ($0.parentID == nil || !affected.contains($0.parentID!)) }
        for root in roots {
            for i in result.entities.indices where selected.contains(result.entities[i].id) && result.entities[i].metadata?.groupID == root.id {
                result.entities[i].metadata?.groupID = root.parentID
            }
            for i in editor.groups.indices where editor.groups[i].parentID == root.id { editor.groups[i].parentID = root.parentID }
        }
        let removed = Set(roots.map(\.id)); editor.groups.removeAll { removed.contains($0.id) }; result.editor = editor
        reconcilePartIdentities(original:document,result:&result,ids:selected)
        return try checked(result)
    }

    public static func synchronizeComponents(document: ModelDocument, sourceID: UUID) throws -> ModelDocument {
        try document.validate()
        guard let source = document.entities.first(where: { $0.id == sourceID }), source.isEditable(in:document),
              let part = source.metadata?.componentPartID, let sourceGroupID = source.metadata?.groupID else { return document }
        let groups = document.editor?.groups ?? []
        func componentGroup(_ id: UUID) -> ModelGroup? {
            var next: UUID? = id, visited = Set<UUID>()
            while let current = next, visited.insert(current).inserted {
                guard let group = groups.first(where: { $0.id == current }) else { return nil }
                if group.componentID != nil { return group }; next = group.parentID
            }
            return nil
        }
        guard let sourceGroup = componentGroup(sourceGroupID), let definition = sourceGroup.componentID else { return document }
        var result = document
        for index in result.entities.indices {
            let target = result.entities[index]
            guard target.id != sourceID, target.metadata?.componentPartID == part, target.isEditable(in:document),
                  let targetID = target.metadata?.groupID, let targetGroup = componentGroup(targetID), targetGroup.componentID == definition, targetGroup.id != sourceGroup.id else { continue }
            var replacement = source
            replacement.id = target.id; replacement.metadata = target.metadata
            let local = rotatePoint(subtract(source.origin,sourceGroup.origin),-sourceGroup.rotation)
            replacement.origin = add(targetGroup.origin,rotatePoint(local,targetGroup.rotation))
            replacement.rotation = composedRotation(rotationPhase(source.rotation)-rotationPhase(sourceGroup.rotation),targetGroup.rotation)
            result.entities[index] = replacement
        }
        return try checked(result)
    }

    /// Mirrors topology changes made in one linked component instance. Instances
    /// keep their own rigid frame; local part geometry follows the edited definition.
    public static func synchronizeComponentTopology(original:ModelDocument,proposed:ModelDocument,editingGroupID:UUID?) throws -> ModelDocument {
        guard let context=editingGroupID,let oldEditor=original.editor,let newEditor=proposed.editor,
              let sourceRoot=nearestComponent(context,in:newEditor.groups),
              oldEditor.groups.contains(where:{$0.id==sourceRoot.id && $0.componentID==sourceRoot.componentID}) else{return proposed}
        let definition=sourceRoot.componentID!
        let originalGroups=Dictionary(uniqueKeysWithValues:oldEditor.groups.map{($0.id,$0)})
        let instances=newEditor.groups.filter{$0.componentID==definition && originalGroups[$0.id]?.componentID==definition}.map(\.id)
        guard instances.count>1 else{return proposed}
        var result=proposed
        var editor=newEditor
        var groups=Dictionary(uniqueKeysWithValues:editor.groups.map{($0.id,$0)})
        func owner(_ entity:GardenEntity)->UUID? {nearestComponent(entity.metadata?.groupID,in:Array(groups.values))?.id}
        func mappedPoint(_ point:Vec3,from sourceFrame:ModelGroup,to peerFrame:ModelGroup)->Vec3 {
            add(peerFrame.origin,rotatePoint(subtract(point,sourceFrame.origin),rotationPhase(peerFrame.rotation-sourceFrame.rotation)))
        }
        func mappedRotation(_ angle:Double,from sourceFrame:ModelGroup,to peerFrame:ModelGroup)->Double {composedRotation(angle,rotationPhase(peerFrame.rotation-sourceFrame.rotation))}
        let previousIDs=Set(original.entities.map(\.id)),currentIDs=Set(result.entities.map(\.id))
        let removedParts=Set(original.entities.filter{$0.metadata?.componentPartID != nil && owner($0)==sourceRoot.id && !currentIDs.contains($0.id)}.compactMap{$0.metadata?.componentPartID})
        if !removedParts.isEmpty {
            result.entities.removeAll{entity in guard let part=entity.metadata?.componentPartID,removedParts.contains(part),let root=owner(entity) else{return false};return root != sourceRoot.id && instances.contains(root)}
        }
        // Match each source descendant by its position among same-named siblings.
        // This preserves separate ordinary groups inside every component instance.
        func descendants(_ root:UUID)->[ModelGroup] {
            var output:[ModelGroup]=[],queue=[root]
            while !queue.isEmpty {let parent=queue.removeFirst();let kids=editor.groups.filter{$0.parentID==parent}.sorted{$0.id.uuidString<$1.id.uuidString};output+=kids;queue+=kids.map(\.id)}
            return output
        }
        func contains(_ groupID:UUID,in entity:GardenEntity)->Bool {
            var current=entity.metadata?.groupID,visited=Set<UUID>()
            while let id=current,visited.insert(id).inserted,let group=groups[id] {
                if id==groupID{return true};current=group.parentID
            }
            return false
        }
        func partSignature(_ groupID:UUID,rootID:UUID)->Set<UUID> {
            Set(result.entities.compactMap{entity in
                guard owner(entity)==rootID,contains(groupID,in:entity) else{return nil}
                return entity.metadata?.componentPartID
            })
        }
        let sourceDescendants=descendants(sourceRoot.id)
        var groupMaps:[UUID:[UUID:UUID]]=[:]
        for peerID in instances where peerID != sourceRoot.id {
            guard let peerRoot=groups[peerID] else{continue}
            var map:[UUID:UUID]=[sourceRoot.id:peerID]
            for sourceGroup in sourceDescendants {
                guard let sourceParent=sourceGroup.parentID,let peerParent=map[sourceParent] else{throw GeometryIOError.invalid("Linked component group hierarchy cannot be matched.")}
                let sourceSiblings=editor.groups.filter{$0.parentID==sourceParent && $0.name==sourceGroup.name}.sorted{$0.id.uuidString<$1.id.uuidString}
                guard let sourceOrdinal=sourceSiblings.firstIndex(where:{$0.id==sourceGroup.id}) else{throw GeometryIOError.invalid("Linked component group hierarchy is inconsistent.")}
                let peerSiblings=editor.groups.filter{$0.parentID==peerParent && $0.name==sourceGroup.name}.sorted{$0.id.uuidString<$1.id.uuidString}
                let targetID:UUID
                let signature=partSignature(sourceGroup.id,rootID:sourceRoot.id)
                let matching=signature.isEmpty ? [] : peerSiblings.filter{partSignature($0.id,rootID:peerID)==signature}
                if matching.count==1 {targetID=matching[0].id}
                else if signature.isEmpty && sourceOrdinal<peerSiblings.count {targetID=peerSiblings[sourceOrdinal].id}
                else {
                    var copy=sourceGroup;copy.id=UUID();copy.parentID=peerParent;copy.origin=mappedPoint(sourceGroup.origin,from:sourceRoot,to:peerRoot);copy.rotation=mappedRotation(sourceGroup.rotation,from:sourceRoot,to:peerRoot)
                    editor.groups.append(copy);groups[copy.id]=copy;targetID=copy.id
                }
                map[sourceGroup.id]=targetID
            }
            groupMaps[peerID]=map
        }
        result.editor=editor
        groups=Dictionary(uniqueKeysWithValues:editor.groups.map{($0.id,$0)})
        func resultOwner(_ entity:GardenEntity)->UUID? {nearestComponent(entity.metadata?.groupID,in:Array(groups.values))?.id}
        var additions:[GardenEntity]=[]
        for index in result.entities.indices where !previousIDs.contains(result.entities[index].id) && resultOwner(result.entities[index])==sourceRoot.id {
            if result.entities[index].metadata==nil {result.entities[index].metadata=EntityMetadata()}
            let part=result.entities[index].metadata?.componentPartID ?? UUID();result.entities[index].metadata?.componentPartID=part
            let source=result.entities[index]
            for peerID in instances where peerID != sourceRoot.id {
                guard let map=groupMaps[peerID],groups[peerID] != nil else{throw GeometryIOError.invalid("Linked component instance is missing its matching groups.")}
                var copy=source;copy.id=UUID();copy.metadata?.groupID=source.metadata?.groupID.flatMap{map[$0]};copy.metadata?.componentPartID=part
                guard let sourceGroupID=source.metadata?.groupID,let sourceFrame=groups[sourceGroupID],let targetGroupID=map[sourceGroupID],let targetFrame=groups[targetGroupID] else{throw GeometryIOError.invalid("Linked component part has no matching group frame.")}
                copy.origin=mappedPoint(source.origin,from:sourceFrame,to:targetFrame);copy.rotation=mappedRotation(source.rotation,from:sourceFrame,to:targetFrame);additions.append(copy)
            }
        }
        let oldByID=Dictionary(uniqueKeysWithValues:original.entities.map{($0.id,$0)})
        let peerByPart=Dictionary(grouping:result.entities.filter{resultOwner($0) != sourceRoot.id && resultOwner($0).map(instances.contains)==true},by:{$0.metadata?.componentPartID})
        for index in result.entities.indices where oldByID[result.entities[index].id] != nil && resultOwner(result.entities[index])==sourceRoot.id {
            guard let part=result.entities[index].metadata?.componentPartID,
                  oldByID[result.entities[index].id]?.metadata?.groupID != result.entities[index].metadata?.groupID,
                  let sourceGroup=result.entities[index].metadata?.groupID else{continue}
            for peer in peerByPart[part] ?? [] {
                guard let peerIndex=result.entities.firstIndex(where:{$0.id==peer.id}),let peerRoot=resultOwner(peer),let map=groupMaps[peerRoot] else{continue}
                result.entities[peerIndex].metadata?.groupID=map[sourceGroup]
            }
        }
        guard editor.groups.count<=50_000,result.entities.count+additions.count<=50_000 else{throw GeometryIOError.invalid("Linked component edit exceeds the document entity limit.")}
        result.entities+=additions
        return try checked(result)
    }

    public static func setHidden(document: ModelDocument, ids: Set<UUID>, hidden: Bool, editingGroupID: UUID? = nil) throws -> ModelDocument {
        var result = document
        let selected = hidden ? editable(document,ids,editingGroupID:editingGroupID) : document.effectiveSelection(ids,editingGroupID:editingGroupID)
        for i in result.entities.indices where selected.contains(result.entities[i].id) {
            if result.entities[i].metadata == nil { result.entities[i].metadata = EntityMetadata() }
            result.entities[i].metadata?.isHidden = hidden
        }
        return try checked(result)
    }
    public static func setLocked(document: ModelDocument, ids: Set<UUID>, locked: Bool, editingGroupID: UUID? = nil) throws -> ModelDocument {
        var result = document
        let selected = document.effectiveSelection(ids,editingGroupID:editingGroupID)
        for i in result.entities.indices where selected.contains(result.entities[i].id) {
            if result.entities[i].metadata == nil { result.entities[i].metadata = EntityMetadata() }
            result.entities[i].metadata?.isLocked = locked
        }
        return try checked(result)
    }
    public static func assignLayer(document: ModelDocument, ids: Set<UUID>, layerID: UUID?, editingGroupID: UUID? = nil) throws -> ModelDocument {
        if let layerID, document.editor?.layers.contains(where: { $0.id == layerID }) != true { throw GeometryIOError.invalid("The requested layer does not exist.") }
        var result = document
        let selected = editable(document,ids,editingGroupID:editingGroupID)
        for i in result.entities.indices where selected.contains(result.entities[i].id) {
            if result.entities[i].metadata == nil { result.entities[i].metadata = EntityMetadata() }
            result.entities[i].metadata?.layerID = layerID
        }
        return try checked(result)
    }
    public static func createLayer(document: ModelDocument, name: String) throws -> ModelDocument {
        var result = document, editor = document.editor ?? EditorState()
        editor.layers.append(ModelLayer(name:name.isEmpty ? "Layer \(editor.layers.count+1)" : name)); result.editor = editor
        return try checked(result)
    }
}
