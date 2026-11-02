import Foundation

/// Clipboard payloads are ordinary validated model documents containing only the copied geometry.
public enum ClipboardOperations {
    public static func copy(document: ModelDocument, ids: Set<UUID>, editingGroupID: UUID? = nil, editableOnly: Bool = false) throws -> ModelDocument {
        try document.validate()
        let contextIDs = document.effectiveSelection(Set(document.entities.map(\.id)), editingGroupID: editingGroupID)
        let entities = document.entities.filter { ids.contains($0.id) && contextIDs.contains($0.id) && (!editableOnly || $0.isEditable(in: document)) }
        let selected = Set(entities.map(\.id)), groups = document.editor?.groups ?? []
        let groupMap = Dictionary(uniqueKeysWithValues: groups.map { ($0.id,$0) })
        var totals:[UUID:Int]=[:],selectedTotals:[UUID:Int]=[:]
        for entity in document.entities {
            var current=entity.metadata?.groupID,seen=Set<UUID>()
            while let id=current,seen.insert(id).inserted {
                totals[id,default:0]+=1
                if selected.contains(entity.id){selectedTotals[id,default:0]+=1}
                current=groupMap[id]?.parentID
            }
        }
        var enclosingGroups=Set<UUID>(),context=editingGroupID
        while let id=context,enclosingGroups.insert(id).inserted {context=groupMap[id]?.parentID}
        let completeGroups=Set(groups.filter{!enclosingGroups.contains($0.id) && (totals[$0.id] ?? 0)>0 && totals[$0.id]==selectedTotals[$0.id]}.map(\.id))
        var copiedGroups=groups.filter { completeGroups.contains($0.id) }
        for i in copiedGroups.indices {
            if copiedGroups[i].parentID.map({completeGroups.contains($0)}) != true {copiedGroups[i].parentID=nil}
        }
        var copied=entities
        for i in copied.indices {
            if let id=copied[i].metadata?.groupID,!completeGroups.contains(id) {
                copied[i].metadata?.groupID=nil;copied[i].metadata?.componentPartID=nil
            }
        }
        let layers=Set(copied.compactMap { $0.metadata?.layerID })
        let editor=EditorState(layers:(document.editor?.layers ?? []).filter { layers.contains($0.id) },groups:copiedGroups)
        let result=ModelDocument(entities:copied,name:"Copied Geometry",editor:editor)
        try result.validate();return result
    }

    public static func paste(payload: ModelDocument, into document: ModelDocument, editingGroupID: UUID? = nil) throws -> ModelDocument {
        try payload.validate();try document.validate()
        if let context=editingGroupID,!(document.editor?.groups.contains { $0.id==context } ?? false) {throw GeometryIOError.invalid("The destination editing group no longer exists.")}
        guard document.entities.count+payload.entities.count<=50_000 else {throw GeometryIOError.invalid("Pasting would exceed the object limit.")}
        var result=document,editor=document.editor ?? EditorState()
        let sourceGroups=payload.editor?.groups ?? [],sourceLayers=payload.editor?.layers ?? []
        let groupIDs=Dictionary(uniqueKeysWithValues:sourceGroups.map { ($0.id,UUID()) })
        let layerIDs=Dictionary(uniqueKeysWithValues:sourceLayers.map { ($0.id,UUID()) })
        let componentIDs=Dictionary(uniqueKeysWithValues:Set(sourceGroups.compactMap(\.componentID)).map { ($0,UUID()) })
        let partIDs=Dictionary(uniqueKeysWithValues:Set(payload.entities.compactMap { $0.metadata?.componentPartID }).map { ($0,UUID()) })
        for source in sourceLayers {var layer=source;layer.id=layerIDs[source.id]!;editor.layers.append(layer)}
        for source in sourceGroups {
            var group=source;group.id=groupIDs[source.id]!
            group.parentID=source.parentID.flatMap { groupIDs[$0] } ?? editingGroupID
            group.componentID=source.componentID.flatMap { componentIDs[$0] }
            editor.groups.append(group)
        }
        for source in payload.entities {
            var entity=source;entity.id=UUID()
            if entity.metadata != nil || editingGroupID != nil {
                var metadata=entity.metadata ?? EntityMetadata()
                metadata.layerID=metadata.layerID.flatMap { layerIDs[$0] }
                metadata.groupID=metadata.groupID.flatMap { groupIDs[$0] } ?? editingGroupID
                metadata.componentPartID=metadata.componentPartID.flatMap { partIDs[$0] }
                entity.metadata=metadata
            }
            result.entities.append(entity)
        }
        if document.editor != nil || !sourceGroups.isEmpty || !sourceLayers.isEmpty || editingGroupID != nil { result.editor=editor }
        try result.validate();return result
    }
}

/// Welds and orders every selected wire segment; no disconnected or branched segments are discarded.
public enum GeometryPath {
    public static func orderedOpenPath(entities: [SketchEntity], tolerance: Double = 1e-6) throws -> [Vec3] {
        guard !entities.isEmpty,tolerance.isFinite,tolerance>0 else {throw GeometryIOError.invalid("Select a nonempty path with a positive tolerance.")}
        var vertices:[Vec3]=[],edges:[(Int,Int)]=[],buckets:[String:[Int]]=[:]
        func key(_ x:Double,_ y:Double,_ z:Double)->String {"\(x),\(y),\(z)"}
        func index(_ vertex:Vec3) throws -> Int {
            let x=floor(vertex.x/tolerance),y=floor(vertex.y/tolerance),z=floor(vertex.z/tolerance)
            guard [x,y,z].allSatisfy(\.isFinite) else {throw GeometryIOError.invalid("Path coordinates exceed the supported welding range.")}
            for dx in -1...1 {for dy in -1...1 {for dz in -1...1 {
                for i in buckets[key(x+Double(dx),y+Double(dy),z+Double(dz))] ?? [] {
                    let a=vertices[i]
                    if hypot(hypot(a.x-vertex.x,a.y-vertex.y),a.z-vertex.z)<=tolerance{return i}
                }
            }}}
            let result=vertices.count;vertices.append(vertex);buckets[key(x,y,z),default:[]].append(result);return result
        }
        var seen=Set<String>()
        for entity in entities {
            let mesh=try entity.triangulatedMesh()
            guard mesh.triangles.isEmpty,!mesh.lineIndices.isEmpty else {throw GeometryIOError.invalid("A sweep path must contain only line or wire geometry.")}
            guard edges.count+mesh.lineIndices.count/2<=8000 else {throw GeometryIOError.invalid("The path exceeds the 8,000 segment limit.")}
            for i in stride(from:0,to:mesh.lineIndices.count,by:2) {
                let a=try index(mesh.vertices[mesh.lineIndices[i]]),b=try index(mesh.vertices[mesh.lineIndices[i+1]])
                guard a != b else {throw GeometryIOError.invalid("The path contains a zero-length segment.")}
                guard seen.insert("\(min(a,b)):\(max(a,b))").inserted else {throw GeometryIOError.invalid("The path contains duplicate segments.")}
                edges.append((a,b))
            }
        }
        var adjacency=Array(repeating:[Int](),count:vertices.count)
        for (a,b) in edges {adjacency[a].append(b);adjacency[b].append(a)}
        let ends=vertices.indices.filter {adjacency[$0].count==1}
        guard ends.count==2,adjacency.allSatisfy({$0.count<=2}) else {throw GeometryIOError.invalid("Follow Me needs one open, nonbranching path; branches and closed loops are unsupported.")}
        let start=ends.min {a,b in
            let p=vertices[a],q=vertices[b]
            return p.x != q.x ? p.x<q.x : (p.y != q.y ? p.y<q.y : p.z<q.z)
        }!
        var ordered=[start],previous:Int?,current=start
        while let next=adjacency[current].first(where:{$0 != previous}) {
            guard !ordered.contains(next) else {throw GeometryIOError.invalid("The path contains a loop.")}
            ordered.append(next);previous=current;current=next
        }
        guard ordered.count==vertices.count,ordered.count==edges.count+1 else {throw GeometryIOError.invalid("Every selected path segment must be connected.")}
        return ordered.map {vertices[$0]}
    }
}
