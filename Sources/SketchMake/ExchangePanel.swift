import AppKit
import CoreGraphics
import SketchCore
import SketchIO
import UniformTypeIdentifiers

/// Some CAD installations register conflicting UTIs for the same extension.
/// Filter by the codec's extension contract instead of LaunchServices identity.
final class ExchangeImportFilter:NSObject,NSOpenSavePanelDelegate {
    let extensions:Set<String>
    init(extensions:[String]) {self.extensions=Set(extensions)}
    func panel(_ sender:Any,shouldEnable url:URL)->Bool {
        url.hasDirectoryPath || extensions.contains(url.pathExtension.lowercased())
    }
}

extension AppDelegate {
    func importContextIsCurrent(revision:UUID,groupID:UUID?)->Bool {
        documentRevision == revision && viewport.editingGroupID == groupID
    }
    private func prepareNativeExchange(_ continuation:@escaping()->Void)->Bool {
        if nativeExchangeReady {return true}
        guard !exchangeBusy else{return false}
        exchangeBusy=true;status.stringValue="Checking installed native SketchUp support…"
        DispatchQueue.global(qos:.userInitiated).async {
            let available = NativeModelFormat.isAvailable
            DispatchQueue.main.async {
                self.nativeExchangeReady=true;self.exchangeBusy=false
                self.status.stringValue=available ? "Native SketchUp exchange is available." : "Native SketchUp SDK unavailable; other exchange formats remain available."
                continuation()
            }
        }
        return false
    }
    private var exchangeScales:[Double?] {[nil,1,0.001,0.01,0.0254,0.3048]}
    private func unitPicker()->NSPopUpButton {
        let picker=NSPopUpButton(frame:NSRect(x:0,y:0,width:280,height:26))
        picker.addItems(withTitles:["Format default / declared units","Meters","Millimeters","Centimeters","Inches","Feet"])
        return picker
    }
    private func axisPicker()->NSPopUpButton {
        let picker=NSPopUpButton(frame:NSRect(x:0,y:0,width:280,height:26))
        picker.addItems(withTitles:["Format default / declared up-axis","Y up","Z up"])
        return picker
    }

    @objc func importGeometry() {
        guard !exchangeBusy else{status.stringValue="A file operation is already running.";return}
        guard prepareNativeExchange({self.importGeometry()}) else{return}
        let panel=NSOpenPanel();panel.title="Import Geometry / Reference Image"
        panel.message="Add geometry or a scaled reference image. Native SKP uses an installed SketchUp SDK; CRV requires VCarve. Import SKM paints through Materials & Textures."
        let filter=ExchangeImportFilter(extensions:ExchangeCatalog.importExtensions)
        panel.allowedContentTypes=[];panel.allowsOtherFileTypes=true;panel.delegate=filter
        panel.allowsMultipleSelection=false
        let units=unitPicker(),axis=axisPicker()
        let mode=NSPopUpButton(frame:NSRect(x:0,y:0,width:280,height:26))
        mode.addItems(withTitles:["PDF / PDF-based AI: vector paths","PDF / PDF-based AI: reference image"])
        let page=NSTextField(string:"1");page.widthAnchor.constraint(equalToConstant:120).isActive=true
        let width=NSTextField(string:"100mm");width.widthAnchor.constraint(equalToConstant:120).isActive=true
        let note=NSTextField(wrappingLabelWithString:"PDF vectors need outlined text; clipping/images use Reference mode. Page/frame is 1-based. Reference images are embedded with the chosen width.")
        note.font = .systemFont(ofSize:11);note.widthAnchor.constraint(equalToConstant:450).isActive=true
        panel.accessoryView=stack([label("Unit override"),units,label("Up-axis override"),axis,mode,stack([label("Page / image frame"),page,label("Reference width"),width]),note],vertical:true,spacing:8)
        guard withExtendedLifetime(filter,{panel.runModal()}) == .OK,let url=panel.url else{return}
        do{
            guard let index=Int(page.stringValue),index>=1 else{throw GeometryIOError.invalid("Page or image frame must be a positive whole number.")}
            let options=ExchangeImportOptions(metersPerUnit:exchangeScales[units.indexOfSelectedItem],axis:ExchangeAxis(rawValue:axis.indexOfSelectedItem) ?? .automatic,page:index,imageWidthMeters:try length(width.stringValue),pdfAsReference:mode.indexOfSelectedItem==1)
            let before=document,context=viewport.editingGroupID,revision=documentRevision
            exchangeBusy=true;status.stringValue="Importing "+url.lastPathComponent+"…"
            DispatchQueue.global(qos:.userInitiated).async{
                let result=Result{try ExchangeCatalog.read(url:url,options:options)}
                DispatchQueue.main.async{
                    self.exchangeBusy=false
                    switch result{
                    case .success(let imported):
                        guard self.importContextIsCurrent(revision:revision,groupID:context) else{self.status.stringValue="The model changed while importing; the result was not applied.";return}
                        do{
                            guard !imported.entities.isEmpty else{throw GeometryIOError.invalid("The file has no importable geometry. Use Open to restore an empty project.")}
                            let previousIDs=Set(before.entities.map(\.id))
                            let next=try ClipboardOperations.paste(payload:imported,into:before,editingGroupID:context)
                            self.viewport.cancelOperation();self.commit(next);self.setTool(.select)
                            self.setSelection(Set(next.entities.map(\.id)).subtracting(previousIDs));self.viewport.zoomExtents()
                            self.status.stringValue="Imported \(imported.entities.count) objects from \(url.lastPathComponent)."
                        }catch{self.showError(error)}
                    case .failure(let error):self.showError(error)
                    }
                }
            }
        }catch{showError(error)}
    }

    @objc func exportGeometry(){presentExport(formatID:"dae")}
    @objc func exportOBJ(){presentExport(formatID:"obj")}

    func presentExport(formatID:String) {
        guard !exchangeBusy else{status.stringValue="A file operation is already running.";return}
        guard prepareNativeExchange({self.presentExport(formatID:formatID)}) else{return}
        let panel=NSSavePanel();panel.title="Export Geometry / View";panel.canCreateDirectories=true
        exportPanel=panel;exportModes=ExchangeCatalog.exportFormats
        exportFormatID=exportModes.contains(where:{$0.id==formatID}) ? formatID:(exportModes.first?.id ?? "dae")
        let picker=NSPopUpButton(frame:NSRect(x:0,y:0,width:430,height:28))
        picker.addItems(withTitles:exportModes.map(\.title));picker.selectItem(at:exportModes.firstIndex(where:{$0.id==exportFormatID}) ?? 0)
        picker.target=self;picker.action=#selector(exportFormatChanged(_:));exportPicker=picker
        let scope=NSPopUpButton(frame:NSRect(x:0,y:0,width:280,height:26));scope.addItems(withTitles:["Whole model","Visible objects only","Selected objects only"]);exportScopePicker=scope
        let units=unitPicker(),axis=axisPicker();exportUnitPicker=units;exportAxisPicker=axis
        let quality=NSTextField(string:"90");quality.widthAnchor.constraint(equalToConstant:70).isActive=true;exportQualityField=quality
        let materials=NSButton(checkboxWithTitle:"Include materials / textures where supported",target:nil,action:nil);materials.state = .on;exportMaterialsCheckbox=materials
        let detail=NSTextField(wrappingLabelWithString:"");detail.font = .systemFont(ofSize:11);detail.textColor = .secondaryLabelColor;detail.widthAnchor.constraint(equalToConstant:470).isActive=true;exportDescription=detail
        panel.accessoryView=stack([picker,detail,label("Export scope"),scope,label("Units (unitless meshes only)"),units,label("Up axis (unitless meshes only)"),axis,stack([label("Lossy image quality (%)"),quality]),materials],vertical:true,spacing:8)
        updateExportPanel()
        defer{exportPanel=nil;exportPicker=nil;exportScopePicker=nil;exportUnitPicker=nil;exportAxisPicker=nil;exportMaterialsCheckbox=nil;exportQualityField=nil;exportDescription=nil}
        guard panel.runModal() == .OK,let url=panel.url,let format=ExchangeCatalog.format(id:exportFormatID) else{return}
        let imageQuality:Double
        if quality.isEnabled {
            guard let percent=Double(quality.stringValue),percent.isFinite,(0...100).contains(percent) else{showError(GeometryIOError.invalid("Image quality must be between 0 and 100."));return}
            imageQuality=percent/100
        } else {imageQuality=0.9}
        let options=ExchangeExportOptions(metersPerUnit:format.supportsUnits ? exchangeScales[units.indexOfSelectedItem]:nil,axis:format.supportsAxis ? (ExchangeAxis(rawValue:axis.indexOfSelectedItem) ?? .automatic):.automatic,scope:ExchangeScope(rawValue:scope.indexOfSelectedItem) ?? .all,selectedIDs:selection,includeMaterials:materials.state == .on,imageQuality:imageQuality)
        var source=document
        if exportFormatID=="project" {
            var view=source.presentation ?? PresentationState();view.camera=viewport.captureCamera();view.orthographic=view.camera.orthographic;source.presentation=view
        }
        var image:CGImage?
        if format.category == .image {
            if let data=viewport.snapshot().tiffRepresentation,let bitmap=NSBitmapImageRep(data:data){image=bitmap.cgImage}
        }
        let chosen=exportFormatID,outputImage=image,outputDocument=source
        exchangeBusy=true;status.stringValue="Exporting "+url.lastPathComponent+"…"
        DispatchQueue.global(qos:.userInitiated).async{
            let result=Result{try ExchangeCatalog.write(outputDocument,to:url,formatID:chosen,options:options,viewImage:outputImage)}
            DispatchQueue.main.async{
                self.exchangeBusy=false
                switch result{case .success:self.status.stringValue="Exported \(url.lastPathComponent). \(format.detail)";case .failure(let error):self.showError(error)}
            }
        }
    }

    @objc func exportFormatChanged(_ sender:NSPopUpButton) {
        guard exportModes.indices.contains(sender.indexOfSelectedItem) else{return}
        exportFormatID=exportModes[sender.indexOfSelectedItem].id;updateExportPanel()
    }
    func updateExportPanel() {
        guard let format=ExchangeCatalog.format(id:exportFormatID) else{return}
        exportPanel?.allowedContentTypes=[UTType(filenameExtension:format.fileExtension) ?? .data]
        exportPanel?.nameFieldStringValue=document.name+"."+format.fileExtension
        exportDescription?.stringValue=format.detail
        exportUnitPicker?.isEnabled=format.supportsUnits
        exportAxisPicker?.isEnabled=format.supportsAxis
        exportScopePicker?.isEnabled=format.category != .image
        exportQualityField?.isEnabled=format.category == .image && ["jpg","jp2","heic","avif","webp"].contains(format.fileExtension)
        exportMaterialsCheckbox?.isEnabled=format.category != .image && format.category != .vector && !["stl-binary","stl-ascii","off"].contains(format.id)
    }

    @objc func exchangeCompatibility() {
        guard prepareNativeExchange({self.exchangeCompatibility()}) else{return}
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:820,height:560),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        panel.title="Import / Export Compatibility";panel.isReleasedWhenClosed=false
        let text=NSTextView();text.isEditable=false;text.isSelectable=true;text.font = .monospacedSystemFont(ofSize:11,weight:.regular)
        text.string=ExchangeCatalog.formats.map{"\($0.canImport ? "IMPORT" : "—")\t\($0.canExport ? "EXPORT" : "—")\t\($0.title) (.\($0.fileExtension))\n\($0.detail)\n"}.joined(separator:"\n")
        let scroll=NSScrollView(frame:panel.contentView!.bounds);scroll.autoresizingMask=[.width,.height];scroll.hasVerticalScroller=true;scroll.documentView=text
        text.frame=NSRect(x:0,y:0,width:780,height:2000);text.autoresizingMask=[.width];text.isVerticallyResizable=true;text.textContainer?.widthTracksTextView=true
        panel.contentView?.addSubview(scroll);auxiliaryPanels.append(panel);panel.center();panel.makeKeyAndOrderFront(nil)
    }
}
