import Foundation
import CoreGraphics
import UniformTypeIdentifiers
import ImageIO
import GardenStudioCore

public enum ExchangeCategory: String { case project, mesh, vector, image, optional, bridge }
public enum ExchangeAxis: Int { case automatic, yUp, zUp }
public enum ExchangeScope: Int { case all, visible, selection }

public struct ExchangeDescriptor: Equatable {
    public let id: String
    public let title: String
    public let fileExtension: String
    public let importExtensions: [String]
    public let canImport: Bool
    public let canExport: Bool
    public let category: ExchangeCategory
    public let detail: String
    public let supportsUnits: Bool
    public let supportsAxis: Bool
}

public struct ExchangeImportOptions {
    public var metersPerUnit: Double?
    public var axis: ExchangeAxis
    public var page: Int
    public var imageWidthMeters: Double
    public var pdfAsReference: Bool
    public init(metersPerUnit: Double? = nil, axis: ExchangeAxis = .automatic, page: Int = 1, imageWidthMeters: Double = 0.1, pdfAsReference: Bool = false) {
        self.metersPerUnit=metersPerUnit;self.axis=axis;self.page=page;self.imageWidthMeters=imageWidthMeters;self.pdfAsReference=pdfAsReference
    }
}

public struct ExchangeExportOptions {
    public var metersPerUnit: Double?
    public var axis: ExchangeAxis
    public var scope: ExchangeScope
    public var selectedIDs: Set<UUID>
    public var includeMaterials: Bool
    public var imageQuality: Double
    public init(metersPerUnit: Double? = nil, axis: ExchangeAxis = .automatic, scope: ExchangeScope = .all, selectedIDs: Set<UUID> = [], includeMaterials: Bool = true, imageQuality: Double = 0.9) {
        self.metersPerUnit=metersPerUnit;self.axis=axis;self.scope=scope;self.selectedIDs=selectedIDs;self.includeMaterials=includeMaterials;self.imageQuality=imageQuality
    }
}

/// Explicit, directional capabilities. A file extension is never a promise of native project compatibility.
public enum ExchangeCatalog {
    public static var formats: [ExchangeDescriptor] {
        var result: [ExchangeDescriptor] = []
        func add(_ id:String,_ title:String,_ ext:String,_ category:ExchangeCategory,_ detail:String,read:Bool=true,write:Bool=true,aliases:[String]=[],units:Bool=false,axis:Bool=false) {
            result.append(ExchangeDescriptor(id:id,title:title,fileExtension:ext,importExtensions:read ? [ext]+aliases:[],canImport:read,canExport:write,category:category,detail:detail,supportsUnits:units,supportsAxis:axis))
        }
        add("project","Project • Garden Studio JSON","json",.project,"Full editable project. Open restores everything; Import merges geometry and organization only.")
        add("woodwork","Woodwork Studio • Individual parts","woodwork",.mesh,"One independent native part per object; no forced assembly or combined unit. Solid rectangular/circular stock exports; imported detailed parts retain native data while their mesh is unchanged. Names, physical placement, native material names and visibility/locks transfer; custom RGB/textures do not.",read:WoodworkFormat.isAvailable,write:WoodworkFormat.isAvailable)
        add("dae","3D • SketchUp Make COLLADA","dae",.mesh,"Static meshes, lines, colors and texture sidecars. Meters, Y up. Keep the texture folder beside the DAE.")
        add("kmz","3D • SketchUp / Google Earth KMZ","kmz",.mesh,"Packaged COLLADA geometry and textures. Geometry exchange only; no georeferenced positioning.")
        add("obj","3D • Wavefront OBJ + MTL","obj",.mesh,"Meshes, lines, diffuse materials and PNG/JPEG sidecars. Unitless: default meters, Y up.",units:true,axis:true)
        add("stl-binary","3D • STL — binary","stl",.mesh,"Triangle surfaces only, no colors or lines. Default millimeters, Z up; reader accepts both encodings.",units:true,axis:true)
        add("stl-ascii","3D • STL — ASCII","stl",.mesh,"Readable triangle surfaces. No colors or lines. Default millimeters, Z up.",read:false,units:true,axis:true)
        add("ply-ascii","3D • PLY — ASCII","ply",.mesh,"Meshes and RGB colors; no textures. Default meters, Y up. Reader accepts ASCII and binary.",units:true,axis:true)
        add("ply-binary","3D • PLY — binary","ply",.mesh,"Compact little-endian meshes/colors. No textures. Default meters, Y up.",read:false,units:true,axis:true)
        add("off","3D • OFF","off",.mesh,"ASCII geometry only. No textures, materials or editing hierarchy. Default meters, Y up.",units:true,axis:true)
        add("gltf","3D • glTF 2.0","gltf",.mesh,"Static geometry, transforms, colors, textures and UVs. Meters, Y up. No skins or animation.")
        add("glb","3D • GLB 2.0 — embedded binary","glb",.mesh,"Self-contained static glTF geometry/materials/textures. Meters, Y up.")
        add("3mf","3D • 3MF core manufacturing package","3mf",.mesh,"Native static triangle meshes, nested components/build transforms and opaque base colors. Declared units normalize automatically; export uses millimeters, Z up. No textures, gradients, production extensions or slicer projects.")
        add("amf","3D • AMF manufacturing mesh","amf",.mesh,"Native XML or single-member ZIP import; XML export. Static meshes, opaque per-face colors/materials and nested constellations. Export millimeters, Z up. No textures, curved triangles or material formulas.")
        add("wrl","3D • VRML 2.0 static scene","wrl",.mesh,"Native UTF-8 static indexed surfaces/lines, transforms and basic colors. Meters, Y up. No scripts, external resources, textures or animated scenes.",aliases:["vrml"])
        add("x3d","3D • X3D XML static scene","x3d",.mesh,"Native XML static indexed geometry, transforms and basic colors. Declared lengths normalize automatically; export meters, Y up. No scripts, routes, textures, custom normals or external resources.")
        add("usdz","3D • USDZ packaged static asset","usdz",.mesh,"Native stored ZIP package with root USD layer first and 64-byte payload alignment. Static meshes, basic colors and UVs; textured export rejects. Installed Apple USD codec required.",read:AppleAssetFormat.supportedImportExtensions.contains("usdc"),write:AppleAssetFormat.supportedExportExtensions.contains("usdc"))
        for ext in ["usd","usda","usdc","abc"] {
            let read=AppleAssetFormat.supportedImportExtensions.contains(ext),write=AppleAssetFormat.supportedExportExtensions.contains(ext)
            add(ext,"3D • "+ext.uppercased(),ext,.mesh,"System static-asset codec. Static triangles/basic colors/UVs; textured export rejects. Meters and declared up-axis normalization; native codec required.",read:read,write:write)
        }
        add("dxf-profiles","2D • VCarve DXF profiles","dxf",.vector,"Top-view contours and holes in millimeters; height is flattened. Reader also accepts supported 3D faces/polyfaces.",aliases:[])
        add("dxf-mesh","3D • VCarve DXF mesh","dxf",.mesh,"3DFACE triangles and LINE edges, millimeters, Z up. No editable solid CAD topology.",read:false)
        add("svg","2D • SVG profiles","svg",.vector,"Physical-size top-view vector outlines, including holes. Plain paths/shapes; no text, scripts or external resources.")
        add("pdf","2D • PDF vector profiles","pdf",.vector,"Physical-size top-view paths. Import one selected page; text must be outlined and images use Reference mode.")
        add("eps","2D • EPS plain vector paths","eps",.vector,"Physical-point vector profiles. Bounded plain path EPS only; executable PostScript prologs are rejected.")
        add("ai","2D • Legacy Illustrator paths","ai",.vector,"Legacy plain-path AI/EPS exchange; PDF-based AI is read as PDF. Modern editable Illustrator features are unsupported.")
        let imported=Set(ImageFormat.supportedImportExtensions),exported=Set(ImageFormat.supportedExportExtensions)
        let imageModes:[(String,String,[String])] = [
            ("png","PNG",[]),("jpg","JPEG",["jpeg","jpe"]),("tiff","TIFF",["tif"]),("bmp","BMP",[]),("gif","GIF",[]),
            ("jp2","JPEG 2000",[]),("heic","HEIC",["heif"]),("avif","AVIF",[]),("tga","TGA",[]),("psd","Photoshop image",[]),
            ("exr","OpenEXR",[]),("webp","WebP",[]),("ico","Windows icon",[]),("icns","macOS icon",[])
        ]
        var covered=Set<String>()
        for (ext,title,aliases) in imageModes {
            let names=[ext]+aliases;covered.formUnion(names)
            add(ext,"Image • "+title,ext,.image,"Import as an embedded, scaled reference image. Export captures the current view; no editable vector/CNC paths.",read:names.contains(where:imported.contains),write:names.contains(where:exported.contains),aliases:aliases)
        }
        add("pdf-view","Image • PDF current view","pdf",.image,"Raster capture of the current view; choose PDF vector profiles for editable CNC paths.",read:false,write:ImageFormat.supportedExportExtensions.contains("pdf"))
        for ext in imported.subtracting(covered).sorted() {
            add("image-"+ext,"Reference image • "+ext.uppercased(),ext,.image,"System reference-image decoder. Choose page/frame and physical width. Not geometry tracing.",read:true,write:false)
        }
        let optionalImports=OptionalAssetConverter.supportedImportExtensions,optionalExports=OptionalAssetConverter.supportedExportExtensions
        for (id,ext,title) in [("3ds","3ds","3D Studio"),("fbxa","fbx","FBX — ASCII"),("x","x","DirectX")] {
            add("assimp-"+id,"Optional • "+title,ext,.optional,"Requires a separately installed, usable Assimp converter. Static surfaces/basic colors only; no textures or animation.",read:optionalImports.contains(ext),write:optionalExports.contains(id))
        }
        add("skp","Native • SketchUp SKP static geometry","skp",.mesh,"Native static geometry, lines, colors and textures through the separately installed compatible SketchUp SDK and helper. Geometry exchange flattens editing hierarchy; not a full SketchUp project clone.",read:NativeModelFormat.isAvailable,write:NativeModelFormat.isAvailable)
        add("skm-material","Native • SketchUp SKM material","skm",.bridge,"Use the Materials panel to import/export native SKM paint and textures when the SketchUp SDK is available. SKM is a material, not model geometry.",read:false,write:false)
        add("sketchup-bridge","Fallback • SketchUp Make Ruby bridge","rb",.bridge,"Included Ruby bridge runs inside SketchUp Make as a fallback for native SKP/SKM exchange when the local SDK/helper is unavailable.",read:false,write:false)
        add("vcarve-native","Native • VCarve CRV / toolpaths","crv",.bridge,"Native CNC jobs, toolpaths and proprietary CAD containers are not interchange modes.",read:false,write:false)
        return result
    }
    public static func format(id:String)->ExchangeDescriptor? {formats.first{$0.id==id}}
    public static var importExtensions:[String] {Array(Set(formats.filter(\.canImport).flatMap(\.importExtensions))).sorted()}
    public static var exportFormats:[ExchangeDescriptor] {formats.filter(\.canExport)}

    public static func read(url:URL,options:ExchangeImportOptions=ExchangeImportOptions()) throws -> ModelDocument {
        let attributes=try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey])
        guard attributes.isRegularFile==true,let size=attributes.fileSize,size<=100_000_000 else {throw GeometryIOError.invalid("Choose a regular import file smaller than 100 MB.")}
        if let scale=options.metersPerUnit {guard scale.isFinite,scale>0 else{throw GeometryIOError.invalid("Import units must be positive and finite.")}}
        let ext=url.pathExtension.lowercased(),name=url.deletingPathExtension().lastPathComponent
        let z=options.axis == .zUp
        let doc:ModelDocument
        switch ext {
        case "json": doc=try JSONDecoder().decode(ModelDocument.self,from:Data(contentsOf:url))
        case "woodwork":doc=try WoodworkFormat.read(url:url)
        case "dae":doc=try ColladaFormat.read(url:url)
        case "kmz":doc=try KMZFormat.read(url:url)
        case "obj":doc=try OBJFormat.read(url:url,metersPerUnit:options.metersPerUnit ?? 1,zUp:z)
        case "ply":doc=try PLYFormat.read(url:url,metersPerUnit:options.metersPerUnit ?? 1,zUp:z)
        case "off":doc=try OFFFormat.read(url:url,metersPerUnit:options.metersPerUnit ?? 1,zUp:z)
        case "stl":doc=try ModelDocument.importSTL(Data(contentsOf:url),name:name,metersPerUnit:options.metersPerUnit ?? 0.001,zUp:options.axis != .yUp)
        case "dxf":doc=try ModelDocument.importDXF(String(contentsOf:url,encoding:.utf8),name:name,metersPerUnit:options.metersPerUnit)
        case "svg":doc=try SVGFormat.read(url:url,metersPerUnit:options.metersPerUnit)
        case "pdf":doc=try options.pdfAsReference ? ImageFormat.readPDFReference(url:url,widthMeters:options.imageWidthMeters,page:options.page):PDFFormat.read(url:url,page:options.page)
        case "eps","ai":
            if try Data(contentsOf:url).starts(with:Data("%PDF".utf8)) {doc=try options.pdfAsReference ? ImageFormat.readPDFReference(url:url,widthMeters:options.imageWidthMeters,page:options.page):PDFFormat.read(url:url,page:options.page)}
            else {doc=try EPSFormat.read(url:url,metersPerUnit:options.metersPerUnit)}
        case "gltf","glb":doc=try GLTFFormat.read(url:url)
        case "3mf":doc=try ThreeMFFormat.read(url:url,metersPerUnit:options.metersPerUnit,zUp:options.axis == .automatic ? nil:z)
        case "amf":doc=try AMFFormat.read(url:url,metersPerUnit:options.metersPerUnit,zUp:options.axis == .automatic ? nil:z)
        case "wrl","vrml":doc=try VRMLFormat.read(url:url,metersPerUnit:options.metersPerUnit,zUp:options.axis == .automatic ? nil:z)
        case "x3d":doc=try X3DFormat.read(url:url,metersPerUnit:options.metersPerUnit,zUp:options.axis == .automatic ? nil:z)
        case "usdz":doc=try USDZFormat.read(url:url,metersPerUnit:options.metersPerUnit,zUp:options.axis == .automatic ? nil:z)
        case "skp":doc=try NativeModelFormat.read(url:url)
        case "skm":throw GeometryIOError.unsupported("SketchUp SKM files contain materials. Use the Materials panel to import SketchUp Material.")
        case "usd","usda","usdc","abc":doc=try AppleAssetFormat.read(url:url,metersPerUnit:options.metersPerUnit,zUp:options.axis == .automatic ? nil:z)
        case "3ds","fbx","x":doc=try OptionalAssetConverter.read(url:url,metersPerUnit:options.metersPerUnit ?? 1,zUp:z)
        default:
            guard ImageFormat.supportedImportExtensions.contains(ext) else{throw GeometryIOError.unsupported("This file type is not a compatible direct import. Use Import/Export Compatibility for supported directions and bridge workflows.")}
            doc=try ImageFormat.read(url:url,widthMeters:options.imageWidthMeters,imageIndex:options.page-1)
        }
        try doc.validate()
        guard ext == "json" || !doc.entities.isEmpty else{throw GeometryIOError.invalid("The selected file contains no supported geometry or reference image.")}
        return doc
    }

    public static func prepareExport(_ document:ModelDocument,options:ExchangeExportOptions=ExchangeExportOptions()) throws->ModelDocument {
        try prepareExport(document,options:options,allowEmpty:false)
    }

    private static func prepareExport(_ document:ModelDocument,options:ExchangeExportOptions,allowEmpty:Bool) throws->ModelDocument {
        try document.validate()
        var result:ModelDocument
        switch options.scope {
        case .all:result=document
        case .visible:result=try ClipboardOperations.copy(document:document,ids:Set(document.entities.filter{$0.isVisible(in:document)}.map(\.id)))
        case .selection:
            guard !options.selectedIDs.isEmpty else{throw GeometryIOError.invalid("Select objects before exporting the selection.")}
            result=try ClipboardOperations.copy(document:document,ids:options.selectedIDs)
        }
        if options.scope != .all {
            result.name=document.name
            result.presentation=document.presentation
            if let source=document.editor {
                var editor=result.editor ?? EditorState()
                editor.units=source.units;editor.snapStep=source.snapStep
                result.editor=editor
            } else if result.editor?.groups.isEmpty == true && result.editor?.layers.isEmpty == true {
                result.editor=nil
            }
        }
        guard allowEmpty || !result.entities.isEmpty else{throw GeometryIOError.invalid("There is no geometry in the selected export scope.")}
        if !options.includeMaterials {
            for index in result.entities.indices {result.entities[index].surface=nil;result.entities[index].colorHex="#E7DCC8"}
        }
        return result
    }

    public static func write(_ document:ModelDocument,to url:URL,formatID:String,options:ExchangeExportOptions=ExchangeExportOptions(),viewImage:CGImage?=nil) throws {
        guard let format=format(id:formatID),format.canExport else{throw GeometryIOError.unsupported("This export mode is unavailable on this Mac.")}
        if format.category == .image {
            guard let viewImage,let type=imageType(forExtension:format.fileExtension) else{throw GeometryIOError.invalid("A current-view image is required for this export.")}
            try ImageFormat.encode(viewImage,typeIdentifier:type,quality:options.imageQuality).write(to:url,options:.atomic)
            return
        }
        try document.validate()
        let doc = try prepareExport(document,options:options,allowEmpty:formatID=="project")
        let z=options.axis == .zUp
        switch formatID {
        case "project":
            try writeProject(doc,to:url)
        case "woodwork":try WoodworkFormat.write(doc,to:url)
        case "dae":try ColladaFormat.write(doc,to:url)
        case "kmz":try KMZFormat.write(doc,to:url)
        case "obj":try OBJFormat.write(doc,to:url,metersPerUnit:options.metersPerUnit ?? 1,zUp:z,includeMaterials:options.includeMaterials)
        case "ply-ascii","ply-binary":try PLYFormat.write(doc,to:url,binary:formatID=="ply-binary",metersPerUnit:options.metersPerUnit ?? 1,zUp:z)
        case "off":try OFFFormat.write(doc,to:url,metersPerUnit:options.metersPerUnit ?? 1,zUp:z)
        case "stl-binary","stl-ascii":try doc.stlData(binary:formatID=="stl-binary",metersPerUnit:options.metersPerUnit ?? 0.001,zUp:options.axis != .yUp).write(to:url,options:.atomic)
        case "dxf-profiles":try doc.dxfString().write(to:url,atomically:true,encoding:.utf8)
        case "dxf-mesh":try doc.dxf3DString().write(to:url,atomically:true,encoding:.utf8)
        case "svg":try SVGFormat.write(doc,to:url)
        case "pdf":try PDFFormat.write(doc,to:url)
        case "eps","ai":try EPSFormat.write(doc,to:url,illustrator:formatID=="ai")
        case "gltf","glb":try GLTFFormat.write(doc,to:url,binary:formatID=="glb")
        case "3mf":try ThreeMFFormat.write(doc,to:url)
        case "amf":try AMFFormat.write(doc,to:url)
        case "wrl":try VRMLFormat.write(doc,to:url)
        case "x3d":try X3DFormat.write(doc,to:url)
        case "usdz":try USDZFormat.write(doc,to:url)
        case "skp":try NativeModelFormat.write(doc,to:url)
        case "usd","usda","usdc":try AppleAssetFormat.write(doc,to:url)
        default:
            guard formatID.hasPrefix("assimp-") else{throw GeometryIOError.unsupported("No writer exists for this mode.")}
            try OptionalAssetConverter.write(doc,to:url,format:String(formatID.dropFirst(7)))
        }
    }
    static func writeProject(_ document:ModelDocument,to url:URL,maximumBytes:Int=100_000_000)throws {
        try document.validate()
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        let data=try encoder.encode(document)
        guard data.count<=maximumBytes else {throw GeometryIOError.invalid("The project exceeds the 100 MB limit. Export a smaller selection or reduce embedded textures.")}
        try data.write(to:url,options:.atomic)
    }

    public static func imageType(forExtension ext:String)->String? {
        // ImageIO identifiers stay stable even when LaunchServices returns a
        // dynamic UTI for a common filename extension in a sandboxed context.
        let identifiers:[String:String] = [
            "png":"public.png","jpg":"public.jpeg","jpeg":"public.jpeg","jpe":"public.jpeg",
            "tif":"public.tiff","tiff":"public.tiff","bmp":"com.microsoft.bmp",
            "gif":"com.compuserve.gif","jp2":"public.jpeg-2000","heic":"public.heic",
            "heif":"public.heif","avif":"public.avif","tga":"com.truevision.tga-image",
            "psd":"com.adobe.photoshop-image","exr":"com.ilm.openexr-image",
            "webp":"org.webmproject.webp","ico":"com.microsoft.ico","icns":"com.apple.icns",
            "pdf":"com.adobe.pdf"
        ]
        return identifiers[ext.lowercased()] ?? UTType(filenameExtension:ext)?.identifier
    }

}
