import AppKit
import SceneKit
import SketchCore
import SketchIO
import UniformTypeIdentifiers

final class ToolRail: NSStackView { override var isFlipped: Bool { true } }

extension ModelingTool {
    var displayName: String {
        switch self {
        case .select:return "Select"
        case .line:return "Line"
        case .rectangle:return "Rectangle"
        case .circle:return "Circle"
        case .pushPull:return "Push / Pull"
        case .move:return "Move"
        case .paint:return "Paint"
        case .erase:return "Erase"
        case .orbit:return "Orbit"
        case .pan:return "Pan"
        case .polygon:return "Polygon"
        case .arc:return "Arc"
        case .freehand:return "Freehand"
        case .rotate:return "Rotate"
        case .scale:return "Scale"
        case .offset:return "Offset"
        case .followMe:return "Follow Me"
        case .tapeMeasure:return "Tape Measure / Guide"
        case .dimension:return "Dimension"
        case .text:return "Text"
        case .section:return "Section Plane"
        case .axes:return "Drawing Axes"
        case .rotatedRectangle:return "Rotated Rectangle"
        }
    }
    var symbolName: String {
        switch self {
        case .select:return "cursorarrow"
        case .line:return "pencil.tip"
        case .rectangle,.rotatedRectangle:return "rectangle"
        case .circle:return "circle"
        case .pushPull:return "arrow.up.square"
        case .move:return "arrow.up.and.down.and.arrow.left.and.right"
        case .paint:return "paintbrush.pointed"
        case .erase:return "eraser"
        case .orbit:return "rotate.3d"
        case .pan:return "hand.draw"
        case .polygon:return "pentagon"
        case .arc:return "arrow.up.right"
        case .freehand:return "scribble.variable"
        case .rotate:return "rotate.right"
        case .scale:return "arrow.up.left.and.arrow.down.right"
        case .offset:return "square.on.square"
        case .followMe:return "point.topleft.down.curvedto.point.bottomright.up"
        case .tapeMeasure,.dimension:return "ruler"
        case .text:return "textformat"
        case .section:return "square.split.2x1"
        case .axes:return "move.3d"
        }
    }
}

extension AppDelegate {
    func installWorkspaceMenus(on bar: NSMenu) {
        func menu(_ title:String,_ entries:[(String,Selector)]) {
            let item=NSMenuItem();let sub=NSMenu(title:title);item.submenu=sub;bar.addItem(item)
            for (name,action) in entries {let entry=NSMenuItem(title:name,action:action,keyEquivalent:"");entry.target=self;sub.addItem(entry)}
        }
        let draw=NSMenuItem();let drawMenu=NSMenu(title:"Draw");draw.submenu=drawMenu;bar.addItem(draw)
        for (index,tool) in ModelingTool.allCases.enumerated(){let item=NSMenuItem(title:tool.displayName,action:#selector(toolMenuClicked(_:)),keyEquivalent:"");item.tag=index;item.target=self;drawMenu.addItem(item)}
        menu("Modify",[("Move Precisely…",#selector(translateSelection)),("Rotate…",#selector(rotateSelection)),("Scale…",#selector(scaleSelection)),("Mirror X",#selector(mirrorX)),("Mirror Y",#selector(mirrorY)),("Mirror Z",#selector(mirrorZ)),("Array Copies…",#selector(arraySelection)),("Generate Planar UVs for Selection",#selector(generatePlanarUVs)),("Offset Profile…",#selector(offsetSelection)),("Create Face from Closed Profile",#selector(faceFromSelection)),("Extrude Profile…",#selector(extrudeSelection)),("Split Face with Selected Line",#selector(splitSelectedFace)),("Cut Hole with Selected Profile",#selector(holeSelectedFace)),("Follow Me Along Selected Path",#selector(sweepSelection)),("Reverse Faces",#selector(reverseSelection)),("Update Linked Components",#selector(syncComponents))])
        menu("Organize",[("Make Group…",#selector(groupSelection)),("Make Component…",#selector(componentSelection)),("Edit Selected Group",#selector(editGroupSelection)),("Exit Group",#selector(exitGroup)),("Explode Group / Component",#selector(explodeSelection)),("Hide Selection",#selector(hideSelection)),("Show All",#selector(showAll)),("Lock Selection",#selector(lockSelection)),("Unlock Selection",#selector(unlockSelection)),("Layers…",#selector(layersPanel)),("Assign Selection to Layer…",#selector(assignLayer)),("Select All Geometry",#selector(selectAllGeometry)),("Model Units & Snap…",#selector(modelSettings))])
        menu("View",[("Parallel Projection",#selector(toggleOrthographic)),("Perspective",#selector(perspective)),("Scenes…",#selector(scenesPanel)),("Save Scene…",#selector(saveScene)),("Solid Style",#selector(solidStyle)),("Monochrome Style",#selector(monochromeStyle)),("Wireframe Style",#selector(wireframeStyle)),("X-Ray Style",#selector(xrayStyle)),("Toggle Shadows",#selector(toggleShadows)),("Section Plane…",#selector(sectionPanel)),("Toggle Section Cut",#selector(toggleSection)),("Set Drawing Axes…",#selector(drawingAxesPanel)),("Ground Drawing Plane",#selector(groundPlane)),("Front Drawing Plane",#selector(frontPlane)),("Right Drawing Plane",#selector(rightPlane)),("Walk / Position Camera…",#selector(walkCamera)),("Export View as PNG…",#selector(exportPNG)),("Print View…",#selector(printView))])
        menu("Annotate",[("Dimension Selected Endpoints",#selector(dimensionSelection)),("Add Text…",#selector(textSelection)),("Add 3D Text…",#selector(text3DSelection)),("Clear Annotations",#selector(clearAnnotations)),("Clear Guides",#selector(clearGuides))])
        menu("Extensions",[("Materials & Textures…",#selector(showMaterials)),("Install SketchUp Make Bridge…",#selector(installModelScriptBridge)),("SketchUp Bridge Instructions",#selector(bridgeHelp)),("Run Ruby Script…",#selector(runRubyScript))])
    }
    @objc func toolMenuClicked(_ sender:NSMenuItem){setTool(ModelingTool.allCases[sender.tag])}
    func input(_ title:String,message:String,initial:String="")->String? {
        let alert=NSAlert();alert.messageText=title;alert.informativeText=message
        let field=NSTextField(string:initial);field.frame=NSRect(x:0,y:0,width:380,height:26);alert.accessoryView=field
        alert.addButton(withTitle:"Apply");alert.addButton(withTitle:"Cancel");alert.window.initialFirstResponder=field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue:nil
    }
    func length(_ text:String)throws->Double {
        var value=text.trimmingCharacters(in:.whitespacesAndNewlines).lowercased();var scale=1.0
        for (suffix,factor) in [("mm",0.001),("cm",0.01),("ft",0.3048),("in",0.0254),("m",1.0)] where value.hasSuffix(suffix){value.removeLast(suffix.count);scale=factor;break}
        guard let number=Double(value.trimmingCharacters(in:.whitespaces)),number.isFinite,abs(number*scale)<=100_000 else{throw GeometryIOError.invalid("Enter a finite number, optionally followed by mm, cm, m, ft or in.")}
        return number*scale
    }
    func vector(_ text:String)throws->Vec3 {
        let parts=text.split(separator:",",omittingEmptySubsequences:false);guard parts.count==3 else{throw GeometryIOError.invalid("Enter X, Y, Z as three comma-separated values.")}
        return try Vec3(length(String(parts[0])),length(String(parts[1])),length(String(parts[2])))
    }
    func editSelection(_ action:(ModelDocument,Set<UUID>)throws->ModelDocument){
        guard !selection.isEmpty else{status.stringValue="Select one or more objects first.";return}
        do{suppressLinkedSync=true;defer{suppressLinkedSync=false};commit(try action(document,selection));setSelection(selection)}catch{showError(error)}
    }
    func synchronizeLinkedEdits(in next:inout ModelDocument)throws {
        // Transaction intent controls synchronization; the active tool can be unrelated
        // to a material or geometry command invoked from a menu or panel.
        guard !suppressLinkedSync || viewport.editingGroupID != nil else{return}
        let hasLinkedParts=document.entities.contains{$0.metadata?.componentPartID != nil}
            || next.entities.contains{$0.metadata?.componentPartID != nil}
        let hasComponentInstances=(document.editor?.groups ?? []).contains{$0.componentID != nil}
            || (next.editor?.groups ?? []).contains{$0.componentID != nil}
        guard hasLinkedParts || (viewport.editingGroupID != nil && hasComponentInstances) else{return}
        next=try EditorOperations.synchronizeComponentTopology(original:document,proposed:next,editingGroupID:viewport.editingGroupID)
        // Commit runs for ordinary interactive edits, so avoid an O(n²) search
        // through the old document when many unlinked objects are selected.
        var previousByID:[UUID:SketchEntity]=[:]
        previousByID.reserveCapacity(document.entities.count)
        for entity in document.entities {previousByID[entity.id]=entity}
        for entity in next.entities {
            guard let previous=previousByID[entity.id],let _=entity.metadata?.groupID else{continue}
            if previous.mesh != entity.mesh || previous.profile != entity.profile || previous.colorHex != entity.colorHex || previous.surface != entity.surface || previous.width != entity.width || previous.depth != entity.depth || previous.height != entity.height || (viewport.editingGroupID != nil && (previous.origin != entity.origin || previous.rotation != entity.rotation)) {
                next=try EditorOperations.synchronizeComponents(document:next,sourceID:entity.id)
            }
        }
    }
    @objc func translateSelection(){guard let raw=input("Move",message:"X, Y, Z displacement. Lengths accept units.",initial:"10mm, 0, 0") else{return};do{let delta=try vector(raw);editSelection{try EditorOperations.translate(document:$0,ids:$1,delta:delta,editingGroupID:viewport.editingGroupID)}}catch{showError(error)}}
    @objc func rotateSelection(){guard let raw=input("Rotate",message:"Degrees around the selection center and blue axis.",initial:"90"),let angle=Double(raw),angle.isFinite else{return};editSelection{try EditorOperations.rotate(document:$0,ids:$1,radians:angle * .pi/180,editingGroupID:viewport.editingGroupID)}}
    @objc func scaleSelection(){guard let raw=input("Scale",message:"X, Y, Z scale factors.",initial:"2, 2, 2") else{return};do{let factors=try vector(raw);editSelection{try EditorOperations.scale(document:$0,ids:$1,factors:factors,editingGroupID:viewport.editingGroupID)}}catch{showError(error)}}
    @objc func mirrorX(){editSelection{try EditorOperations.mirror(document:$0,ids:$1,axis:"x",editingGroupID:viewport.editingGroupID)}}
    @objc func mirrorY(){editSelection{try EditorOperations.mirror(document:$0,ids:$1,axis:"y",editingGroupID:viewport.editingGroupID)}}
    @objc func mirrorZ(){editSelection{try EditorOperations.mirror(document:$0,ids:$1,axis:"z",editingGroupID:viewport.editingGroupID)}}
    @objc func arraySelection(){guard let raw=input("Array Copies",message:"Number of copies, then X, Y, Z step.",initial:"4, 100mm, 0, 0") else{return};let parts=raw.split(separator:",");guard parts.count==4,let count=Int(parts[0].trimmingCharacters(in:.whitespaces)) else{return};do{let delta=try vector(parts.dropFirst().joined(separator:","));editSelection{try EditorOperations.duplicate(document:$0,ids:$1,count:count,delta:delta,editingGroupID:viewport.editingGroupID)}}catch{showError(error)}}
    @objc func groupSelection(){guard let name=input("Make Group",message:"Group name",initial:"Group") else{return};editSelection{try EditorOperations.group(document:$0,ids:$1,name:name,component:false,editingGroupID:viewport.editingGroupID)}}
    @objc func componentSelection(){guard let name=input("Make Component",message:"Copies share geometry edits; transform instances separately.",initial:"Component") else{return};editSelection{try EditorOperations.group(document:$0,ids:$1,name:name,component:true,editingGroupID:viewport.editingGroupID)}}
    @objc func editGroupSelection(){guard let id=selected,let entity=document.entities.first(where:{$0.id==id}),let groupID=entity.metadata?.groupID else{status.stringValue="Select a grouped object first.";return};viewport.editingGroupID=groupID;setSelection([id]);status.stringValue="Editing group. Escape or Organize → Exit Group leaves it."}
    @objc func exitGroup(){if let id=viewport.editingGroupID{viewport.editingGroupID=document.editor?.groups.first(where:{$0.id==id})?.parentID};setSelection([]);status.stringValue="Group editing context closed."}
    @objc func explodeSelection(){editSelection{try EditorOperations.explode(document:$0,ids:$1,editingGroupID:viewport.editingGroupID)}}
    @objc func syncComponents(){guard let id=selected else{return};editSelection{ doc, _ in try EditorOperations.synchronizeComponents(document:doc,sourceID:id)}}
    @objc func hideSelection(){editSelection{try EditorOperations.setHidden(document:$0,ids:$1,hidden:true,editingGroupID:viewport.editingGroupID)}}
    @objc func showAll(){do{commit(try EditorOperations.setHidden(document:document,ids:Set(document.entities.map(\.id)),hidden:false))}catch{showError(error)}}
    @objc func lockSelection(){editSelection{try EditorOperations.setLocked(document:$0,ids:$1,locked:true,editingGroupID:viewport.editingGroupID)}}
    @objc func unlockSelection(){editSelection{try EditorOperations.setLocked(document:$0,ids:$1,locked:false,editingGroupID:viewport.editingGroupID)}}
    @objc func selectAllGeometry(){setSelection(Set(document.entities.filter{$0.isVisible(in:document)}.map(\.id)))}
    func transformSelectedProfile(_ action:(SketchEntity)throws->SketchEntity){
        guard let id=selected,let index=document.entities.firstIndex(where:{$0.id==id}),document.entities[index].isEditable(in:document) else{return}
        do{var next=document;next.entities[index]=try action(next.entities[index]);commit(next);select(id)}catch{showError(error)}
    }
    @objc func faceFromSelection(){transformSelectedProfile{try GeometryTools.faceFromWire(entity:$0)}}
    @objc func extrudeSelection(){guard let raw=input("Extrude Face",message:"Absolute extrusion along the face normal.",initial:"25mm") else{return};do{let distance=try length(raw);transformSelectedProfile{try GeometryTools.extrude(entity:$0,distance:distance)}}catch{showError(error)}}
    @objc func offsetSelection(){guard let raw=input("Offset Profile",message:"Positive expands, negative contracts.",initial:"5mm") else{return};do{viewport.performOffset(try length(raw))}catch{showError(error)}}
    @objc func sweepSelection(){viewport.performSweepAlongSelectedPath()}
    @objc func splitSelectedFace(){
        let items=document.entities.filter{selection.contains($0.id)}
        guard items.allSatisfy({$0.isEditable(in:document)}),let face=items.first(where:{(try? GeometryTools.worldProfile(of:$0)) != nil}),let line=items.first(where:{$0.kind == .line}) else{status.stringValue="Select a planar face and a cutting line.";return}
        do{let mesh=try line.triangulatedMesh();let faces=try GeometryTools.split(entity:face,lineStart:mesh.vertices[0],lineEnd:mesh.vertices[1]);var next=document;next.entities.removeAll{$0.id==face.id};next.entities+=faces;commit(next);setSelection(Set(faces.map(\.id)))}catch{showError(error)}
    }
    @objc func holeSelectedFace(){
        let items=document.entities.filter{selection.contains($0.id) && (try? GeometryTools.worldProfile(of:$0)) != nil};guard items.count==2,items.allSatisfy({$0.isEditable(in:document)}) else{status.stringValue="Select an outer face and a smaller coplanar profile.";return}
        do{let sorted=items.sorted{($0.width*$0.depth+$0.width*$0.height+$0.depth*$0.height)>($1.width*$1.depth+$1.width*$1.height+$1.depth*$1.height)};let cutter=sorted[1];let profile=try GeometryTools.worldProfile(of:cutter);var next=document;let result=try GeometryTools.addHole(entity:sorted[0],points:profile.outer);next.entities.removeAll{$0.id==sorted[0].id || $0.id==cutter.id};next.entities.append(result);commit(next);select(result.id)}catch{showError(error)}
    }
    @objc func reverseSelection(){
        var next=document
        do{
            for i in next.entities.indices where selection.contains(next.entities[i].id) && next.entities[i].isEditable(in:document){
                var mesh:MeshData
                if let existing=next.entities[i].mesh{mesh=existing}
                else{mesh=try next.entities[i].triangulatedMesh();next.entities[i].kind = .mesh;next.entities[i].origin=Vec3(0,0,0);next.entities[i].rotation=0}
                guard !mesh.triangles.isEmpty else{continue}
                for j in stride(from:0,to:mesh.triangles.count,by:3){mesh.triangles.swapAt(j+1,j+2)}
                next.entities[i].mesh=mesh
                if var profile=next.entities[i].profile{profile.outer.reverse();profile.holes=profile.holes.map{Array($0.reversed())};next.entities[i].profile=profile;if let amount=next.entities[i].profileExtrusion{next.entities[i].profileExtrusion = -amount}}
            }
            commit(next)
        }catch{showError(error)}
    }
    static func snapSpacingForEditing(_ value:Double)->String {String(value)+" m"}
    @objc func modelSettings(){
        let alert=NSAlert();alert.messageText="Model Units & Snap";alert.informativeText="Snap spacing accepts units; point and axis inference remains active."
        let step=NSTextField(string:Self.snapSpacingForEditing(document.editor?.snapStep ?? 0.001));step.widthAnchor.constraint(equalToConstant:250).isActive=true
        let units=NSPopUpButton();units.addItems(withTitles:["m","mm","cm","ft","in"]);units.selectItem(withTitle:document.editor?.units ?? "m")
        alert.accessoryView=stack([label("Snap spacing"),step,label("Display units"),units],vertical:true);alert.addButton(withTitle:"Apply");alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else{return};do{let value=try length(step.stringValue);guard value>0 else{throw GeometryIOError.invalid("Snap spacing must be positive.")};var next=document;var editor=next.editor ?? EditorState();editor.snapStep=value;editor.units=units.titleOfSelectedItem ?? "m";next.editor=editor;var p=next.presentation ?? PresentationState();p.units=["m":"meters","mm":"millimeters","cm":"centimeters","ft":"feet","in":"inches"][editor.units] ?? "meters";next.presentation=p;commit(next)}catch{showError(error)}
    }
    @objc func layersPanel(){
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:340,height:400),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);panel.title="Layers";panel.isReleasedWhenClosed=false
        let root=stack([button("New Layer…",#selector(createLayer)),button("Assign Selection…",#selector(assignLayer))],vertical:true,spacing:12)
        for (i,layer) in (document.editor?.layers ?? []).enumerated(){let toggle=NSButton(checkboxWithTitle:layer.name,target:self,action:#selector(layerVisibilityChanged(_:)));toggle.tag=i;toggle.state=layer.isVisible ? .on:.off;root.addArrangedSubview(toggle)}
        root.edgeInsets=NSEdgeInsets(top:16,left:16,bottom:16,right:16);root.frame=panel.contentView!.bounds;root.autoresizingMask=[.width,.height];panel.contentView?.addSubview(root);auxiliaryPanels.append(panel);panel.center();panel.makeKeyAndOrderFront(nil)
    }
    @objc func createLayer(){guard let name=input("New Layer",message:"Layer name",initial:"Layer") else{return};do{commit(try EditorOperations.createLayer(document:document,name:name));status.stringValue="Layer created. Reopen Layers to toggle it."}catch{showError(error)}}
    @objc func layerVisibilityChanged(_ sender:NSButton){var next=document;guard next.editor?.layers.indices.contains(sender.tag)==true else{return};next.editor?.layers[sender.tag].isVisible=sender.state == .on;commit(next)}
    @objc func assignLayer(){let alert=NSAlert();alert.messageText="Assign Layer";let picker=NSPopUpButton(frame:NSRect(x:0,y:0,width:300,height:26));picker.addItem(withTitle:"Default / unassigned");picker.addItems(withTitles:(document.editor?.layers ?? []).map(\.name));alert.accessoryView=picker;alert.addButton(withTitle:"Assign");alert.addButton(withTitle:"Cancel");guard alert.runModal() == .alertFirstButtonReturn else{return};let id=picker.indexOfSelectedItem==0 ? nil:document.editor?.layers[picker.indexOfSelectedItem-1].id;editSelection{try EditorOperations.assignLayer(document:$0,ids:$1,layerID:id,editingGroupID:viewport.editingGroupID)}}
    @objc func generatePlanarUVs(){
        let indexes=document.entities.indices.filter{selection.contains(document.entities[$0].id) && document.entities[$0].kind == .mesh && document.entities[$0].isEditable(in:document)}
        guard !indexes.isEmpty else{status.stringValue="Select at least one editable mesh.";return}
        do{var next=document;for index in indexes{guard let mesh=next.entities[index].mesh else{continue};next.entities[index].mesh=try TextureTools.generatePlanarUVs(mesh)};commit(next);status.stringValue="Generated per-face planar UVs for \(indexes.count) mesh(es)."}catch{showError(error)}
    }
    func updatePresentation(_ action:(inout PresentationState)->Void){var next=document;let units=["m":"meters","mm":"millimeters","cm":"centimeters","ft":"feet","in":"inches"][next.editor?.units ?? "m"] ?? "meters";var state=next.presentation ?? PresentationState(units:units);action(&state);next.presentation=state;commit(next)}
    @objc func toggleOrthographic(){updatePresentation{$0.orthographic.toggle()};viewport.setOrthographic(document.presentation?.orthographic ?? false)}
    @objc func perspective(){updatePresentation{$0.orthographic=false};viewport.setOrthographic(false)}
    @objc func solidStyle(){updatePresentation{$0.style="solid"}}
    @objc func monochromeStyle(){updatePresentation{$0.style="monochrome"}}
    @objc func wireframeStyle(){updatePresentation{$0.style="wireframe"}}
    @objc func xrayStyle(){updatePresentation{$0.style="xray"}}
    @objc func toggleShadows(){updatePresentation{$0.shadows.toggle()}}
    @objc func saveScene(){guard let name=input("Save Scene",message:"Scene name",initial:"Scene \((document.presentation?.scenes.count ?? 0)+1)") else{return};let camera=viewport.captureCamera();let hidden=document.entities.filter{$0.metadata?.isHidden == true}.map(\.id);updatePresentation{$0.scenes.append(SavedScene(name:name,camera:camera,hiddenIDs:hidden,visibleLayerIDs:document.editor?.layers.filter(\.isVisible).map(\.id) ?? []))}}
    @objc func scenesPanel(){
        let alert=NSAlert();alert.messageText="Scenes";let picker=NSPopUpButton(frame:NSRect(x:0,y:0,width:320,height:28));let scenes=document.presentation?.scenes ?? [];picker.addItems(withTitles:scenes.map(\.name));alert.accessoryView=picker;alert.addButton(withTitle:"Restore");alert.addButton(withTitle:"New Scene…");alert.addButton(withTitle:"Delete");alert.addButton(withTitle:"Cancel")
        let result=alert.runModal();if result == .alertSecondButtonReturn{saveScene();return};guard scenes.indices.contains(picker.indexOfSelectedItem) else{return};let scene=scenes[picker.indexOfSelectedItem]
        if result == .alertFirstButtonReturn{restoreScene(scene)}else if result == .alertThirdButtonReturn{updatePresentation{$0.scenes.removeAll{$0.id==scene.id}}}
    }
    @objc func groundPlane(){viewport.setDrawingPlane("ground")}
    @objc func frontPlane(){viewport.setDrawingPlane("front")}
    @objc func rightPlane(){viewport.setDrawingPlane("right")}
    @objc func drawingAxesPanel(){
        guard let raw=input("Drawing Axes",message:"Origin X,Y,Z; X direction; plane normal (nine values).",initial:"0, 0, 0, 1, 0, 0, 0, 1, 0") else{return}
        let parts=raw.split(separator:",",omittingEmptySubsequences:false)
        guard parts.count==9 else{status.stringValue="Enter nine comma-separated coordinates.";return}
        do {
            let origin=try vector(parts[0..<3].joined(separator:",")),x=try vector(parts[3..<6].joined(separator:",")),normal=try vector(parts[6..<9].joined(separator:","))
            viewport.setDrawingAxes(try DrawingAxes(origin:origin,xAxis:x,normal:normal));status.stringValue="Drawing axes saved to this model."
        } catch {showError(error)}
    }
    @objc func walkCamera(){let camera=viewport.captureCamera();guard let raw=input("Position Camera / Walk",message:"Target X, Y, Z, yaw degrees, pitch degrees, distance. Use Orbit/Pan to navigate.",initial:"\(camera.target.x), \(camera.target.y), \(camera.target.z), 0, 0, 1m") else{return};let parts=raw.split(separator:",");guard parts.count==6 else{return};do{let target=try vector(parts.prefix(3).joined(separator:","));guard let yaw=Double(parts[3].trimmingCharacters(in:.whitespaces)),let pitch=Double(parts[4].trimmingCharacters(in:.whitespaces)),yaw.isFinite,pitch.isFinite else{return};let distance=try length(String(parts[5]));let camera=CameraState(target:target,yaw:yaw * .pi/180,pitch:pitch * .pi/180,distance:distance,orthographic:false);try camera.validate();changeCamera(to:camera)}catch{showError(error)}}
    func addMeasurement(start:Vec3,end:Vec3,dimension:Bool){if dimension{updatePresentation{$0.annotations.append(ModelAnnotation(kind:"dimension",start:start,end:end))}}else{updatePresentation{$0.guides.append(GuideLine(start:start,end:end))}}}
    func addText(at point:Vec3,threeD:Bool){
        guard let text=input(threeD ? "3D Text":"Text Label",message:"Text",initial:"Label") else{return}
        if threeD {
            guard let raw=input("3D Text Size",message:"Height, depth (lengths accept units). The result is exportable geometry.",initial:"100mm, 10mm") else{return}
            let values=raw.split(separator:",");guard values.count==2 else{return}
            do{var entity=try TextGeometry.make(text:text,height:length(String(values[0])),depth:length(String(values[1])),origin:point);if let group=viewport.editingGroupID{entity.metadata=EntityMetadata(groupID:group)};var next=document;next.entities.append(entity);commit(next);select(entity.id)}catch{showError(error)}
        }else{updatePresentation{$0.annotations.append(ModelAnnotation(kind:"text",start:point,text:text))}}
    }
    func selectionPoint()->Vec3{document.entities.first(where:{$0.id==selected})?.origin ?? Vec3(0,0,0)}
    @objc func textSelection(){addText(at:selectionPoint(),threeD:false)}
    @objc func text3DSelection(){addText(at:selectionPoint(),threeD:true)}
    @objc func dimensionSelection(){guard let entity=document.entities.first(where:{$0.id==selected}),let mesh=try? entity.triangulatedMesh(),mesh.vertices.count>=2 else{return};addMeasurement(start:mesh.vertices[0],end:mesh.vertices[1],dimension:true)}
    @objc func clearAnnotations(){updatePresentation{$0.annotations=[]}}
    @objc func clearGuides(){updatePresentation{$0.guides=[]}}
    func setSection(point:Vec3,normal:Vec3){updatePresentation{$0.section=SectionPlane(point:point,normal:normal)}}
    @objc func sectionPanel(){guard let raw=input("Section Plane",message:"Point X, Y, Z, normal X, Y, Z; positive side is clipped.",initial:"0, 1m, 0, 0, 1, 0") else{return};let parts=raw.split(separator:",");guard parts.count==6 else{return};do{setSection(point:try vector(parts.prefix(3).joined(separator:",")),normal:try vector(parts.suffix(3).joined(separator:",")))}catch{showError(error)}}
    @objc func toggleSection(){updatePresentation{if var section=$0.section{section.enabled.toggle();$0.section=section}else{$0.section=SectionPlane(point:Vec3(0,0,0),normal:Vec3(0,1,0))}}}
    @objc func exportPNG(){let panel=NSSavePanel();panel.allowedContentTypes=[.png];panel.nameFieldStringValue="\(document.name).png";guard panel.runModal() == .OK,let url=panel.url,let data=viewport.snapshot().tiffRepresentation,let rep=NSBitmapImageRep(data:data),let png=rep.representation(using:.png,properties:[:]) else{return};do{try png.write(to:url,options:.atomic);status.stringValue="View exported as PNG."}catch{showError(error)}}
    @objc func printView(){let image=viewport.snapshot();let view=NSImageView(frame:NSRect(x:0,y:0,width:720,height:450));view.image=image;view.imageScaling = .scaleProportionallyUpOrDown;NSPrintOperation(view:view).run()}
    @objc func showMaterials(){if materialsPanel==nil{materialsPanel=MaterialsPanelController()};materialsPanel?.onApply={[weak self] material,faceOnly in try self?.applySurface(material,faceOnly:faceOnly)};materialsPanel?.show(for:window,current:document.entities.first(where:{$0.id==selected})?.surface)}
    func applySurface(_ material:SurfaceMaterial,faceOnly:Bool) throws {
        try material.validate()
        let editable=document.entities.indices.filter{selection.contains(document.entities[$0].id) && document.entities[$0].isEditable(in:document)}
        guard !editable.isEmpty else{throw GeometryIOError.invalid("Select an unlocked object before applying a material.")}
        if faceOnly,selection.count != 1 {throw GeometryIOError.invalid("Enter the group and select one face owner before assigning a face material.")}
        var next=document
        for i in editable {
            if faceOnly {
                let count=try next.entities[i].triangulatedMesh().triangles.count/3
                let indices=Array(viewport.selectedFaceIndices)
                guard !indices.isEmpty else{throw GeometryIOError.invalid("Click a face in the viewport first.")}
                let surface=next.entities[i].surface ?? SurfaceMaterial(name:"Material",colorHex:next.entities[i].colorHex)
                next.entities[i].surface=try surface.assigning(material,toTriangleIndices:indices,triangleCount:count)
            } else {next.entities[i].surface=material;next.entities[i].colorHex=material.colorHex}
        }
        try next.validate()
        commit(next)
    }
    @objc func installModelScriptBridge(){let panel=NSSavePanel();panel.title="Save SketchUp Make Bridge";panel.allowedContentTypes=[UTType(filenameExtension:"rb") ?? .data];panel.nameFieldStringValue="sketchmake_bridge.rb";guard panel.runModal() == .OK,let url=panel.url else{return};do{try ModelScriptBridge.writeExtension(to:url);bridgeHelp()}catch{showError(error)}}
    @objc func bridgeHelp(){let alert=NSAlert();alert.messageText="SketchUp Make Bridge";alert.informativeText="Save the bridge .rb into SketchUp Make's Plugins folder, then restart Make. Its Extensions menu can import/export Sketch Make JSON. Make opens and saves native SKP/SKM files itself.\n\nRuby scripts here use a supported automation subset; full SketchUp extensions still run in Make.";alert.runModal()}
    @objc func runRubyScript(){
        let panel=NSOpenPanel();panel.allowedContentTypes=[UTType(filenameExtension:"rb") ?? .data];panel.message="Choose a trusted local Ruby script. It runs with your file/network permissions using the supported Sketch Make automation API."
        guard panel.runModal() == .OK,let url=panel.url else{return};let original=document,revision=documentRevision,context=viewport.editingGroupID;status.stringValue="Running Ruby script…"
        DispatchQueue.global(qos:.userInitiated).async{let result=Result{try ModelScriptBridge.runRubyScript(at:url,document:original,timeout:10)};DispatchQueue.main.async{switch result{case .success(let next):guard self.importContextIsCurrent(revision:revision,groupID:context) else{self.status.stringValue="Model changed while script ran; result was not applied.";return};self.commit(next);self.viewport.zoomExtents();self.status.stringValue="Ruby script completed; changes are undoable.";case .failure(let error):self.showError(error)}}}
    }
}
