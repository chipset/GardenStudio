import Foundation
import CoreGraphics
import ImageIO
import simd
import GardenStudioCore

/// Static glTF 2.0 triangle/line exchange. glTF positions are meters, Y up.
/// Scene transforms are baked; PNG/JPEG base colors and TEXCOORD_0 are retained.
public enum GLTFFormat {
    private static let limit = 64 * 1024 * 1024
    private static func linear(_ value:Double) -> Double { value<=0.04045 ? value/12.92 : pow((value+0.055)/1.055,2.4) }
    private static func sRGB(_ value:Double) -> Double { value<=0.0031308 ? value*12.92 : 1.055*pow(value,1/2.4)-0.055 }
    private static func invalid(_ message: String) -> GeometryIOError { .invalid("glTF: " + message) }
    private static func unsupported(_ message: String) -> GeometryIOError { .unsupported("glTF: " + message) }
    private static func texturePixels(_ data:Data) throws -> (width:Int,height:Int,rgba:[UInt8],precision:Int,hasAlpha:Bool) {
        try SurfaceMaterial(textureData:data).validate()
        guard let source=CGImageSourceCreateWithData(data as CFData,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil),
              let space=CGColorSpace(name:CGColorSpace.sRGB) else {throw invalid("Cannot decode base-color image.")}
        var drawing=image
        var originalAlpha:[UInt8]?
        // Convert unassociated RGB through an opaque view to avoid rounding
        // low-alpha colors through premultiplication. Retain source alpha
        // independently; callers reject if ImageIO's erased zero-alpha RGB
        // would become visible through OPAQUE or a zero MASK cutoff.
        if [.first,.last].contains(image.alphaInfo),image.bitsPerComponent==8,
           let colorSpace=image.colorSpace,let provider=image.dataProvider,let sourceData=provider.data {
            let components=colorSpace.numberOfComponents+1
            let raw=sourceData as Data
            let skip:CGImageAlphaInfo=image.alphaInfo == .first ? .noneSkipFirst:.noneSkipLast
            let info=CGBitmapInfo(rawValue:(image.bitmapInfo.rawValue & ~CGBitmapInfo.alphaInfoMask.rawValue) | skip.rawValue)
            if image.bitsPerPixel==components*8,raw.count>=image.bytesPerRow*image.height,
               let opaque=CGImage(width:image.width,height:image.height,bitsPerComponent:8,bitsPerPixel:image.bitsPerPixel,bytesPerRow:image.bytesPerRow,space:colorSpace,bitmapInfo:info,provider:provider,decode:image.decode,shouldInterpolate:false,intent:image.renderingIntent) {
                drawing=opaque
                let little=components==4 && image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little
                let alphaOffset=little ? (image.alphaInfo == .first ? 3:0):(image.alphaInfo == .first ? 0:components-1)
                originalAlpha=(0..<(image.width*image.height)).map {p in raw[(p/image.width)*image.bytesPerRow+(p%image.width)*components+alphaOffset]}
            }
        }
        var bytes=[UInt8](repeating:0,count:image.width*image.height*4)
        try bytes.withUnsafeMutableBytes { storage in
            guard let context=CGContext(data:storage.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw invalid("Cannot decode base-color pixels.")}
            context.draw(drawing,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        }
        for offset in stride(from:0,to:bytes.count,by:4) {
            if let originalAlpha {bytes[offset+3]=originalAlpha[offset/4]}
            else {
                let alpha=Double(bytes[offset+3])
                for channel in 0..<3 {bytes[offset+channel]=alpha>0 ? UInt8(min(255,(Double(bytes[offset+channel])*255/alpha).rounded())):0}
            }
        }
        return (image.width,image.height,bytes,image.bitsPerComponent,![.none,.noneSkipFirst,.noneSkipLast].contains(image.alphaInfo))
    }
    private static func hasTextureAlpha(_ pixels:[UInt8]) -> Bool {
        stride(from:3,to:pixels.count,by:4).contains {pixels[$0]<255}
    }
    /// glTF factors multiply linear RGB; the native material displays its image
    /// directly. Bake factors and alpha rules into an ordinary sRGB PNG.
    static func bakedTexture(_ data:Data,factor:[Double],mode:String,cutoff:Double) throws -> Data {
        let decoded=try texturePixels(data)
        // ImageIO can discard hidden RGB under alpha zero. If glTF would
        // reveal it, reject explicitly instead of importing a black replacement.
        if mode=="OPAQUE" || (mode=="MASK" && cutoff==0) {
            guard !stride(from:3,to:decoded.rgba.count,by:4).contains(where:{decoded.rgba[$0]==0}) else {throw unsupported("OPAQUE or zero-cutoff MASK textures with zero-alpha pixels cannot preserve hidden RGB through the system image decoder. Use BLEND or an opaque PNG.")}
        }
        guard mode != "MASK" || decoded.precision<=8 else {throw unsupported("MASK textures above 8 bits per channel require an 8-bit PNG to preserve the alpha threshold exactly.")}
        let rgbIsWhite=factor[0]==1 && factor[1]==1 && factor[2]==1
        if rgbIsWhite && ((mode=="BLEND" && factor[3]==1) || (mode=="OPAQUE" && !hasTextureAlpha(decoded.rgba) && (decoded.precision<=8 || !decoded.hasAlpha))) {return data}
        var pixels=decoded.rgba
        for offset in stride(from:0,to:pixels.count,by:4) {
            let alpha=Double(decoded.rgba[offset+3])/255
            for channel in 0..<3 {
                let component=Double(decoded.rgba[offset+channel])/255
                pixels[offset+channel]=UInt8(min(255,max(0,(sRGB(linear(component)*factor[channel])*255).rounded())))
            }
            let multiplied=alpha*factor[3]
            pixels[offset+3]=mode=="OPAQUE" ? 255:mode=="MASK" ? (multiplied>=cutoff ? 255:0):UInt8((multiplied*255).rounded())
        }
        guard let provider=CGDataProvider(data:Data(pixels) as CFData),let space=CGColorSpace(name:CGColorSpace.sRGB),
              let image=CGImage(width:decoded.width,height:decoded.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:decoded.width*4,space:space,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else {throw invalid("Cannot encode transformed base-color image.")}
        let output=NSMutableData()
        guard let destination=CGImageDestinationCreateWithData(output,"public.png" as CFString,1,nil) else {throw invalid("Cannot encode base-color PNG.")}
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination),output.length<=SurfaceMaterial.maximumTextureBytes else {throw invalid("Transformed base-color image exceeds the 10 MB texture limit.")}
        return output as Data
    }
    private static func number(_ value:Any?,default fallback:Double?=nil)throws->Double {
        guard let value else {if let fallback{return fallback};throw invalid("Missing number.")}
        guard let number=value as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID() else {throw invalid("Expected a number, not a boolean or another JSON type.")}
        let d = number.doubleValue
        guard d.isFinite else {throw invalid("Nonfinite number.")}
        return d
    }
    private static func vector(_ value:Any?,_ fallback:[Double])throws->[Double] {
        guard let value else {return fallback}
        guard let values=value as? [Any],values.count==fallback.count else {throw invalid("Invalid numeric vector.")}
        return try values.map{try number($0)}
    }
    private static func boolean(_ value:Any?,default fallback:Bool)throws->Bool {
        guard let value else {return fallback}
        guard let number=value as? NSNumber,CFGetTypeID(number)==CFBooleanGetTypeID() else {throw invalid("Expected a boolean flag.")}
        return number.boolValue
    }
    private static func integer(_ value: Any?, default fallback: Int? = nil) throws -> Int {
        let d=try number(value,default:fallback.map(Double.init))
        guard d.isFinite, d >= 0, d <= Double(Int32.max), d.rounded() == d else { throw invalid("Invalid integer or excessive size.") }
        return Int(d)
    }
    private static func item(_ array: [[String:Any]], _ value: Any?) throws -> [String:Any] {
        let i = try integer(value); guard array.indices.contains(i) else {throw invalid("Missing referenced object.")}; return array[i]
    }
    private static func bounded(_ url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey])
        guard size.isRegularFile == true, let count = size.fileSize, count <= limit else {throw invalid("Resource exceeds 64 MB or is not a regular file.")}
        return try Data(contentsOf:url)
    }
    private static func resource(_ uri:String, base:URL) throws -> Data {
        if uri.hasPrefix("data:") {
            guard let comma=uri.firstIndex(of:","), uri[..<comma].hasSuffix(";base64"), uri.count <= limit * 2,
                  let data=Data(base64Encoded:String(uri[uri.index(after:comma)...])), data.count <= limit else {throw invalid("Invalid embedded resource.")}
            return data
        }
        guard let decoded=uri.removingPercentEncoding, !decoded.contains(":"), !decoded.hasPrefix("/"), !decoded.contains("\\"), !decoded.contains("?"), !decoded.contains("#"), !decoded.split(separator:"/").contains("..") else {throw invalid("Only resources inside the model folder are allowed.")}
        let folder=base.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let target=folder.appendingPathComponent(decoded).resolvingSymlinksInPath().standardizedFileURL
        guard target.path.hasPrefix(folder.path+"/") else {throw invalid("Resource leaves the model folder.")}
        return try bounded(target)
    }
    private static func uint(_ data:Data,_ offset:Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:offset,as:UInt32.self)) }
    }
    public static func read(url:URL) throws -> ModelDocument {
        let file=try bounded(url)
        var json=file, binary:Data?
        if file.count >= 4, uint(file,0)==0x46546c67 {
            guard file.count >= 20, uint(file,4)==2, Int(uint(file,8))==file.count else {throw invalid("Malformed GLB header.")}
            var offset=12, chunk=0
            while offset < file.count {
                guard offset <= file.count-8 else {throw invalid("Truncated GLB chunk.")}
                let length=Int(uint(file,offset)), type=uint(file,offset+4); offset += 8
                guard length % 4 == 0, length <= file.count-offset else {throw invalid("Invalid GLB chunk length.")}
                let data=file.subdata(in:offset..<offset+length)
                if chunk == 0 { guard type==0x4e4f534a else {throw invalid("GLB JSON must be first.")}; json=data }
                else { guard chunk==1,type==0x004e4942,binary==nil else {throw unsupported("Unexpected GLB chunks.")}; binary=data }
                offset += length; chunk += 1
            }
        }
        guard let root=try JSONSerialization.jsonObject(with:json) as? [String:Any], let asset=root["asset"] as? [String:Any], asset["version"] as? String == "2.0" else {throw invalid("Expected glTF 2.0 asset.")}
        for key in ["animations","skins","extensionsRequired"] { if let values=root[key] as? [Any], !values.isEmpty {throw unsupported("Animations, skins and required extensions are not supported.")} }
        let views=root["bufferViews"] as? [[String:Any]] ?? [], accessors=root["accessors"] as? [[String:Any]] ?? []
        var buffers:[Data]=[]
        for (index,buffer) in (root["buffers"] as? [[String:Any]] ?? []).enumerated() {
            let data:Data
            if let uri=buffer["uri"] as? String {data=try resource(uri,base:url)}
            else {guard index==0,let bin=binary else {throw invalid("Missing binary buffer.")}; data=bin}
            let length=try integer(buffer["byteLength"])
            guard length <= data.count else {throw invalid("Truncated buffer.")}
            buffers.append(data.prefix(length))
        }
        guard buffers.reduce(0,{$0+$1.count}) <= limit else {throw invalid("Buffers exceed 64 MB.")}
        func viewData(_ index:Any?) throws -> Data {
            let view=try item(views,index), b=try integer(view["buffer"]), start=try integer(view["byteOffset"],default:0), length=try integer(view["byteLength"])
            guard buffers.indices.contains(b),start <= buffers[b].count,length <= buffers[b].count-start else {throw invalid("Buffer view exceeds buffer bounds.")}
            return buffers[b].subdata(in:start..<start+length)
        }
        func accessor(_ index:Any?,type:String) throws -> [[Double]] {
            let a=try item(accessors,index)
            guard a["sparse"] == nil,a["type"] as? String == type else {throw unsupported("Sparse or mismatched accessor.")}
            let component=try integer(a["componentType"]), count=try integer(a["count"]), offset=try integer(a["byteOffset"],default:0)
            let width=type=="VEC4" ? 4 : type=="VEC3" ? 3 : type=="VEC2" ? 2 : 1
            let bytes:Int
            switch component {case 5121:bytes=1;case 5123:bytes=2;case 5125,5126:bytes=4;default:throw unsupported("Unsupported accessor component type.")}
            let v=try item(views,a["bufferView"]), strideBytes=try integer(v["byteStride"],default:width*bytes), data=try viewData(a["bufferView"])
            guard count>0,count<=1_500_000,strideBytes >= width*bytes,strideBytes<=252,offset<=data.count,(count-1) <= (data.count-offset)/strideBytes,(count-1)*strideBytes+width*bytes <= data.count-offset else {throw invalid("Accessor exceeds buffer view bounds.")}
            let normalized=try boolean(a["normalized"],default:false)
            return try (0..<count).map { row in
                try (0..<width).map { col in
                    let p=offset+row*strideBytes+col*bytes
                    var value:Double
                    if component==5126 { value=Double(Float(bitPattern:uint(data,p))) }
                    else {var n:UInt32=0;for i in 0..<bytes {n |= UInt32(data[p+i]) << (8*i)};value=Double(n);if normalized {value /= component==5121 ? 255 : component==5123 ? 65535 : Double(UInt32.max)}}
                    guard value.isFinite else {throw invalid("Nonfinite accessor value.")};return value
                }
            }
        }
        let materials=root["materials"] as? [[String:Any]] ?? [], images=root["images"] as? [[String:Any]] ?? [], textures=root["textures"] as? [[String:Any]] ?? [], samplers=root["samplers"] as? [[String:Any]] ?? []
        var materialCache:[Int:SurfaceMaterial]=[:], textureBytes=0, textureCount=0
        func material(_ index:Any?) throws -> SurfaceMaterial {
            guard let index else {return SurfaceMaterial(colorHex:"#FFFFFF")}
            let key=try integer(index)
            if let cached=materialCache[key] {return cached}
            let m=try item(materials,index), p=m["pbrMetallicRoughness"] as? [String:Any] ?? [:]
            let color=try vector(p["baseColorFactor"],[1,1,1,1])
            let mode=m["alphaMode"] as? String ?? "OPAQUE",cutoff=try number(m["alphaCutoff"],default:0.5)
            guard color.count==4,color.allSatisfy({$0.isFinite && $0>=0 && $0<=1}),["OPAQUE","BLEND","MASK"].contains(mode),cutoff.isFinite,cutoff>=0,cutoff<=1 else {throw invalid("Invalid base-color factor or alpha mode.")}
            var result=SurfaceMaterial(colorHex:String(format:"#%02X%02X%02X",Int((sRGB(color[0])*255).rounded()),Int((sRGB(color[1])*255).rounded()),Int((sRGB(color[2])*255).rounded())))
            if let texture=p["baseColorTexture"] as? [String:Any] {
                guard try integer(texture["texCoord"],default:0)==0,texture["extensions"] == nil else {throw unsupported("Only untransformed TEXCOORD_0 textures are supported.")}
                let t=try item(textures,texture["index"]), image=try item(images,t["source"])
                if let samplerIndex=t["sampler"] {
                    let sampler=try item(samplers,samplerIndex)
                    for key in ["wrapS","wrapT"] {
                        if let value=sampler[key],!(value is NSNumber) {throw invalid("Invalid texture wrapping mode.")}
                        let wrap=try integer(sampler[key],default:10497)
                        guard [10497,33071,33648].contains(wrap) else {throw invalid("Invalid texture wrapping mode.")}
                        // Native materials repeat in both directions. Clamping or
                        // mirroring would change pixels outside the base UV tile.
                        guard wrap==10497 else {throw unsupported("Clamped and mirrored texture wrapping cannot be preserved. Use repeat wrapping or bake the texture into UV tiles.")}
                    }
                }
                if let uri=image["uri"] as? String {result.textureData=try resource(uri,base:url)} else {result.textureData=try viewData(image["bufferView"])}
            }
            if let data=result.textureData {
                result.textureData=try bakedTexture(data,factor:color,mode:mode,cutoff:cutoff)
                if let extras=m["extras"] as? [String:Any],let fallback=extras["sketchMakeFallbackColor"] as? String,
                   fallback.range(of:"^#[0-9a-fA-F]{6}$",options:.regularExpression) != nil {result.colorHex=fallback}
            } else if mode != "OPAQUE",color[3]<1 {
                throw unsupported("Untextured material opacity is not supported; provide a base-color PNG texture.")
            }
            try result.validate()
            if let data=result.textureData {textureBytes += data.count;textureCount += 1;guard textureBytes<=50*1024*1024,textureCount<=200 else {throw invalid("Texture resources exceed 50 MB or 200 images.")}}
            materialCache[key]=result;return result
        }
        let meshes=root["meshes"] as? [[String:Any]] ?? [], nodes=root["nodes"] as? [[String:Any]] ?? []
        var entities:[GardenEntity]=[], total=0, path=Set<Int>(),visited=Set<Int>(),visits=0
        func visit(_ index:Int,_ parent:simd_double4x4,_ depth:Int) throws {
            visits+=1
            // glTF's selected scene must be a forest. Reusing a mesh through
            // distinct nodes is valid; revisiting a node is not. Bound empty
            // hierarchy work too, before geometry budgets could ever apply.
            guard visits<=150_000,nodes.indices.contains(index),depth<256,path.insert(index).inserted,visited.insert(index).inserted else {throw invalid("Invalid, repeated, cyclic or excessive node graph.")};defer {path.remove(index)}
            let node=nodes[index];guard node["skin"]==nil,node["weights"]==nil,node["extensions"]==nil else {throw unsupported("Skinned, morphing or extended nodes are not supported.")}
            var local=matrix_identity_double4x4
            if let matrix=node["matrix"] {
                guard node["translation"]==nil,node["rotation"]==nil,node["scale"]==nil else {throw invalid("Matrix and TRS cannot coexist.")}
                let m=try vector(matrix,Array(repeating:0,count:16));local=simd_double4x4(columns:(SIMD4(m[0],m[1],m[2],m[3]),SIMD4(m[4],m[5],m[6],m[7]),SIMD4(m[8],m[9],m[10],m[11]),SIMD4(m[12],m[13],m[14],m[15])))
                guard m[3]==0,m[7]==0,m[11]==0,m[15]==1 else {throw unsupported("Projective transforms are not supported.")}
            } else {
                let t=try vector(node["translation"],[0,0,0]), s=try vector(node["scale"],[1,1,1]), r=try vector(node["rotation"],[0,0,0,1])
                guard abs(r.reduce(0,{$0+$1*$1})-1)<0.001 else {throw invalid("Rotation quaternion is not normalized.")}
                local=simd_double4x4(simd_quatd(ix:r[0],iy:r[1],iz:r[2],r:r[3]));for c in 0..<3 {local[c] *= s[c]};local.columns.3=SIMD4(t[0],t[1],t[2],1)
            }
            let world=parent*local
            if let meshIndex=node["mesh"] {
                let mesh=try item(meshes,meshIndex);guard mesh["weights"]==nil,let primitives=mesh["primitives"] as? [[String:Any]],!primitives.isEmpty else {throw unsupported("Missing primitives or morph weights.")}
                for primitive in primitives {
                    guard primitive["targets"]==nil,primitive["extensions"]==nil,let attrs=primitive["attributes"] as? [String:Any],attrs.keys.allSatisfy({["POSITION","NORMAL","TANGENT","TEXCOORD_0"].contains($0)}) else {throw unsupported("Morphs, vertex colors or unsupported attributes.")}
                    let raw=try accessor(attrs["POSITION"],type:"VEC3")
                    guard raw.count<=250_000 else {throw invalid("Mesh exceeds vertex limit.")}
                    // Normals and tangents are regenerated by the viewport, but
                    // every declared stream must still be structurally valid.
                    for (semantic,type) in [("NORMAL","VEC3"),("TANGENT","VEC4")] {
                        if let index=attrs[semantic] {
                            let declared=try item(accessors,index)
                            guard try integer(declared["componentType"])==5126,
                                  declared["normalized"] as? Bool != true,
                                  try integer(declared["count"])==raw.count else {throw invalid("Invalid \(semantic) component layout or vertex count.")}
                            _=try accessor(index,type:type)
                        }
                    }
                    let vertices=raw.map {p -> Vec3 in let v=world*SIMD4(p[0],p[1],p[2],1);return Vec3(v.x,v.y,v.z)}
                    var indices:[Int]
                    if let i=primitive["indices"] {let a=try item(accessors,i);guard [5121,5123,5125].contains(try integer(a["componentType"])),a["normalized"] as? Bool != true else {throw invalid("Invalid index accessor.")};indices=try accessor(i,type:"SCALAR").map{Int($0[0])}} else {indices=Array(vertices.indices)}
                    let mode=try integer(primitive["mode"],default:4);guard mode==4 || mode==1 else {throw unsupported("Only TRIANGLES and LINES are supported.")}
                    if mode==4,simd_determinant(world)<0 {guard indices.count%3==0 else {throw invalid("Incomplete triangles.")};for i in stride(from:0,to:indices.count,by:3) {indices.swapAt(i+1,i+2)}}
                    var uv:[TextureCoordinate]?
                    if let i=attrs["TEXCOORD_0"] {uv=try accessor(i,type:"VEC2").map{TextureCoordinate(u:$0[0],v:$0[1])};guard uv?.count==vertices.count else {throw invalid("UV count does not match positions.")}}
                    let surface=try material(primitive["material"])
                    guard surface.textureData==nil || uv != nil else {throw unsupported("Textured geometry requires TEXCOORD_0.")}
                    let data=MeshData(vertices:vertices,triangles:mode==4 ? indices:[],lineIndices:mode==1 ? indices:[],textureCoordinates:uv);try data.validate()
                    total += vertices.count;guard total<=1_000_000,entities.count<50_000 else {throw invalid("Scene exceeds geometry limits.")}
                    entities.append(GardenEntity(name:String((node["name"] as? String ?? "glTF mesh").prefix(200)),kind:.mesh,origin:Vec3(0,0,0),width:vertices.map(\.x).max()!-vertices.map(\.x).min()!,depth:vertices.map(\.z).max()!-vertices.map(\.z).min()!,height:vertices.map(\.y).max()!-vertices.map(\.y).min()!,colorHex:surface.colorHex,mesh:data,surface:surface))
                }
            }
            for child in node["children"] as? [Any] ?? [] {try visit(integer(child),world,depth+1)}
        }
        let scenes=root["scenes"] as? [[String:Any]] ?? []
        guard !scenes.isEmpty else {throw invalid("No scene.")}
        let scene=try item(scenes,root["scene"] ?? 0)
        for index in scene["nodes"] as? [Any] ?? [] {try visit(integer(index),matrix_identity_double4x4,0)}
        guard !entities.isEmpty else {throw invalid("Scene contains no supported geometry.")}
        let result=ModelDocument(entities:entities,name:url.deletingPathExtension().lastPathComponent);try result.validate();return result
    }
    private struct TextureVertex:Hashable {
        let source:Int
        let u:Double
        let v:Double
    }

    /// Matches MaterialManager's local-meter projection and uniform texture
    /// transform. A source vertex is shared only when its final UV also agrees.
    static func bakingTextureCoordinates(_ world:MeshData,entity:GardenEntity,surface:SurfaceMaterial) throws -> MeshData {
        var localEntity=entity
        localEntity.origin=Vec3(0,0,0);localEntity.rotation=0
        let local=try localEntity.triangulatedMesh()
        let count=world.triangles.count/3
        var scales=Array(repeating:surface.textureScale,count:count)
        var rotations=Array(repeating:surface.textureRotation,count:count)
        for face in surface.faceOverrides {
            for triangle in face.triangleIndices {scales[triangle]=face.textureScale;rotations[triangle]=face.textureRotation}
        }
        var result=MeshData(textureCoordinates:[]), remap:[TextureVertex:Int]=[:]
        func mapped(_ source:Int,_ u:Double,_ v:Double,_ scale:Double,_ rotation:Double) throws -> Int {
            let cosine=cos(rotation),sine=sin(rotation)
            let transformedU=(cosine*u-sine*v)/scale, transformedV=(sine*u+cosine*v)/scale
            guard transformedU.isFinite,transformedV.isFinite else {throw invalid("Texture transform produced nonfinite coordinates.")}
            let key=TextureVertex(source:source,u:transformedU,v:transformedV)
            if let existing=remap[key] {return existing}
            guard result.vertices.count<250_000 else {throw invalid("Texture seams expand this mesh beyond 250,000 vertices.")}
            let next=result.vertices.count
            result.vertices.append(world.vertices[source]);result.textureCoordinates!.append(TextureCoordinate(u:transformedU,v:transformedV))
            remap[key]=next;return next
        }
        for triangle in 0..<count {
            let offset=triangle*3
            let a=local.vertices[local.triangles[offset]], b=local.vertices[local.triangles[offset+1]], c=local.vertices[local.triangles[offset+2]]
            let nx=(b.y-a.y)*(c.z-a.z)-(b.z-a.z)*(c.y-a.y)
            let ny=(b.z-a.z)*(c.x-a.x)-(b.x-a.x)*(c.z-a.z)
            let nz=(b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)
            for corner in 0..<3 {
                let source=world.triangles[offset+corner],p=local.vertices[source]
                let u:Double,v:Double
                if let coordinates=local.textureCoordinates {u=coordinates[source].u;v=coordinates[source].v}
                else if abs(nx)>=abs(ny) && abs(nx)>=abs(nz) {u=p.z;v=p.y}
                else if abs(ny)>=abs(nz) {u=p.x;v=p.z}
                else {u=p.x;v=p.y}
                result.triangles.append(try mapped(source,u,v,scales[triangle],rotations[triangle]))
            }
        }
        for source in world.lineIndices {
            let p=local.vertices[source],coordinate=local.textureCoordinates?[source] ?? TextureCoordinate(u:p.x,v:p.z)
            result.lineIndices.append(try mapped(source,coordinate.u,coordinate.v,surface.textureScale,surface.textureRotation))
        }
        try result.validate();return result
    }

    public static func write(_ document:ModelDocument,to url:URL,binary:Bool=false) throws {
        try document.validate();guard !document.entities.isEmpty else {throw invalid("No geometry to export.")}
        var buffer=Data(), views:[[String:Any]]=[], accessors:[[String:Any]]=[], meshes:[[String:Any]]=[], nodes:[[String:Any]]=[], materials:[[String:Any]]=[], images:[[String:Any]]=[], textures:[[String:Any]]=[]
        func align() {while buffer.count%4 != 0 {buffer.append(0)}}
        func append(_ data:Data) -> Int {align();let offset=buffer.count;buffer.append(data);views.append(["buffer":0,"byteOffset":offset,"byteLength":data.count]);return views.count-1}
        func values(_ numbers:[Double],width:Int) throws -> Int {
            var data=Data()
            for number in numbers {guard Float(number).isFinite else {throw invalid("Coordinate exceeds float32 range.")};var n=Float(number).bitPattern.littleEndian;withUnsafeBytes(of:&n){data.append(contentsOf:$0)}}
            let view=append(data);var a:[String:Any]=["bufferView":view,"componentType":5126,"count":numbers.count/width,"type":width==3 ? "VEC3":"VEC2"]
            if width==3 {a["min"]=(0..<3).map{c in stride(from:c,to:numbers.count,by:3).map{numbers[$0]}.min()!};a["max"]=(0..<3).map{c in stride(from:c,to:numbers.count,by:3).map{numbers[$0]}.max()!}}
            accessors.append(a);return accessors.count-1
        }
        func indices(_ numbers:[Int]) -> Int {
            var data=Data();for number in numbers {var n=UInt32(number).littleEndian;withUnsafeBytes(of:&n){data.append(contentsOf:$0)}}
            let view=append(data);accessors.append(["bufferView":view,"componentType":5125,"count":numbers.count,"type":"SCALAR"]);return accessors.count-1
        }
        func addMaterial(_ surface:SurfaceMaterial) throws -> Int {
            let hex=surface.colorHex.dropFirst(), rgb=UInt32(hex,radix:16) ?? 0
            var pbr:[String:Any]=["baseColorFactor":[linear(Double((rgb>>16)&255)/255),linear(Double((rgb>>8)&255)/255),linear(Double(rgb&255)/255),1],"metallicFactor":0,"roughnessFactor":1]
            var alphaMode="OPAQUE"
            if let data=surface.textureData {
                pbr["baseColorFactor"]=[1,1,1,1]
                let pixels=try texturePixels(data)
                alphaMode=(pixels.hasAlpha || hasTextureAlpha(pixels.rgba)) ? "BLEND":"OPAQUE"
                let view=append(data);images.append(["bufferView":view,"mimeType":data.starts(with:[0x89,0x50,0x4e,0x47]) ? "image/png":"image/jpeg"])
                textures.append(["source":images.count-1]);pbr["baseColorTexture"]=["index":textures.count-1]
            }
            var material:[String:Any]=["name":surface.name,"doubleSided":true,"pbrMetallicRoughness":pbr,"alphaMode":alphaMode]
            if surface.textureData != nil {material["extras"]=["sketchMakeFallbackColor":surface.colorHex]}
            materials.append(material);return materials.count-1
        }
        for entity in document.entities {
            var mesh=try entity.triangulatedMesh()
            let surface=entity.surface ?? SurfaceMaterial(colorHex:entity.colorHex)
            if surface.textureData != nil || surface.faceOverrides.contains(where:{$0.textureData != nil}) {
                mesh=try bakingTextureCoordinates(mesh,entity:entity,surface:surface)
            }
            let position=try values(mesh.vertices.flatMap{[$0.x,$0.y,$0.z]},width:3)
            var attrs:[String:Any]=["POSITION":position]
            if let uv=mesh.textureCoordinates {attrs["TEXCOORD_0"]=try values(uv.flatMap{[$0.u,$0.v]},width:2)}
            var primitives:[[String:Any]]=[], assigned=Set<Int>()
            for face in surface.faceOverrides {
                let numbers=face.triangleIndices.flatMap{Array(mesh.triangles[($0*3)..<($0*3+3)])};assigned.formUnion(face.triangleIndices)
                let m=try addMaterial(SurfaceMaterial(colorHex:face.colorHex,textureData:face.textureData))
                primitives.append(["attributes":attrs,"indices":indices(numbers),"mode":4,"material":m])
            }
            let m=try addMaterial(surface)
            let remaining=(0..<(mesh.triangles.count/3)).filter{!assigned.contains($0)}.flatMap{Array(mesh.triangles[($0*3)..<($0*3+3)])}
            if !remaining.isEmpty {primitives.append(["attributes":attrs,"indices":indices(remaining),"mode":4,"material":m])}
            if !mesh.lineIndices.isEmpty {primitives.append(["attributes":attrs,"indices":indices(mesh.lineIndices),"mode":1,"material":m])}
            meshes.append(["primitives":primitives]);nodes.append(["name":entity.name,"mesh":meshes.count-1])
        }
        guard buffer.count<=limit else {throw invalid("Export exceeds 64 MB.")}
        var root:[String:Any]=["asset":["version":"2.0","generator":"GardenStudio"],"scene":0,"scenes":[["nodes":Array(nodes.indices)]],"nodes":nodes,"meshes":meshes,"accessors":accessors,"bufferViews":views,"materials":materials]
        if !images.isEmpty {root["images"]=images;root["textures"]=textures}
        var b:[String:Any]=["byteLength":buffer.count]
        if !binary {b["uri"]="data:application/octet-stream;base64,"+buffer.base64EncodedString()};root["buffers"]=[b]
        var json=try JSONSerialization.data(withJSONObject:root,options:[.sortedKeys])
        guard json.count + (binary ? buffer.count+28:0)<=limit else {throw invalid("Export exceeds the 64 MB file limit.")}
        if binary {
            while json.count%4 != 0 {json.append(0x20)};align()
            var output=Data()
            func word(_ number:UInt32) {var n=number.littleEndian;withUnsafeBytes(of:&n){output.append(contentsOf:$0)}}
            word(0x46546c67);word(2);word(UInt32(12+8+json.count+8+buffer.count));word(UInt32(json.count));word(0x4e4f534a);output.append(json);word(UInt32(buffer.count));word(0x004e4942);output.append(buffer)
            try output.write(to:url,options:.atomic)
        } else {try json.write(to:url,options:.atomic)}
    }
}
