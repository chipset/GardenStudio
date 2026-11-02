import Foundation
import GardenStudioCore

/// XML X3D static indexed geometry. DTDs, scripts, routes, external resources,
/// custom normals, textures and unsupported sibling nodes are rejected as a whole.
public enum X3DFormat {
    public static func read(url:URL,metersPerUnit:Double?=nil,zUp:Bool?=nil) throws ->ModelDocument {
        let text=try StaticScene.text(url)
        guard !text.localizedCaseInsensitiveContains("<!DOCTYPE"),!text.localizedCaseInsensitiveContains("<!ENTITY"),!text.localizedCaseInsensitiveContains("<?xml-stylesheet") else {throw GeometryIOError.unsupported("X3D DTDs, entities and external stylesheets are prohibited.")}
        let delegate=X3DReader(),parser=XMLParser(data:Data(text.utf8));parser.shouldResolveExternalEntities=false;parser.delegate=delegate
        guard parser.parse(),delegate.failure==nil,delegate.sceneCount==1 else {throw delegate.failure ?? parser.parserError ?? GeometryIOError.invalid("X3D needs one complete Scene.")}
        return try StaticScene.document(nodes:delegate.nodes,name:url.deletingPathExtension().lastPathComponent,scale:metersPerUnit ?? delegate.lengthScale,zUp:zUp ?? false)
    }
    public static func write(_ document:ModelDocument,to url:URL) throws {
        let nodes=try StaticScene.nodes(document)
        let text="<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<X3D profile=\"Interchange\" version=\"3.3\"><Scene>\n"+nodes.map {xml($0)}.joined(separator:"\n")+"\n</Scene></X3D>\n"
        guard text.utf8.count<=64*1024*1024 else {throw GeometryIOError.invalid("X3D output exceeds the 64 MB scene limit.")}
        try text.write(to:url,atomically:true,encoding:.utf8)
    }
    private static func xml(_ n:VRNode,container:String?=nil)->String {
        var attrs:[String]=[],children:[String]=[]
        if let container {attrs.append("containerField=\"\(container)\"")}
        for key in n.fields.keys.sorted() {
            switch n.fields[key]! {
            case let .numbers(ns):attrs.append("\(key)=\"\(ns.map(StaticScene.number).joined(separator:" "))\"")
            case let .boolean(b):attrs.append("\(key)=\"\(b ? "true":"false")\"")
            case let .nodes(nodes):children += nodes.map {xml($0,container:key)}
            case .strings:break // Writer generates geometry only; no user-authored metadata is serialized.
            }
        }
        return "<\(n.type)"+(attrs.isEmpty ? "":" "+attrs.joined(separator:" "))+(children.isEmpty ? "/>":">\n"+children.joined(separator:"\n")+"\n</\(n.type)>")
    }
}

private final class X3DReader:NSObject,XMLParserDelegate {
    struct Frame {let tag:String;let node:VRNode?;let container:String?}
    var frames:[Frame]=[],nodes:[VRNode]=[],failure:Error?,sceneCount=0,count=0,lengthScale=1.0,seenLengthUnit=false
    func parser(_ parser:XMLParser,didStartElement name:String,namespaceURI:String?,qualifiedName:String?,attributes attrs:[String:String]) {
        do {try start(name,attrs)} catch {failure=error;parser.abortParsing()}
    }
    func parser(_ parser:XMLParser,didEndElement name:String,namespaceURI:String?,qualifiedName:String?) {
        do {try end(name)} catch {failure=error;parser.abortParsing()}
    }
    func parser(_ parser:XMLParser,foundCharacters string:String) {if !string.allSatisfy(\.isWhitespace) {failure=GeometryIOError.invalid("X3D node text is unsupported; use standard attribute fields.");parser.abortParsing()}}
    func start(_ name:String,_ attrs:[String:String]) throws {
        count+=1;guard frames.count<128,count<=150_000 else {throw GeometryIOError.invalid("X3D nesting/node limit exceeded.")}
        if name=="X3D" {
            guard frames.isEmpty,count==1,Set(attrs.keys).isSubset(of:["profile","version","xmlns:xsd","xsd:noNamespaceSchemaLocation","xmlns:xsi","xsi:noNamespaceSchemaLocation","xmlns"]) else {throw GeometryIOError.invalid("Invalid or unsupported X3D root attributes.")}
            frames.append(Frame(tag:name,node:nil,container:nil));return
        }
        if name=="Scene" {
            guard frames.last?.tag=="X3D",sceneCount==0,attrs.isEmpty else {throw GeometryIOError.invalid("X3D needs exactly one Scene child.")};sceneCount+=1;frames.append(Frame(tag:name,node:nil,container:nil));return
        }
        if name=="head" {
            guard frames.last?.tag=="X3D",attrs.isEmpty,sceneCount==0 else {throw GeometryIOError.invalid("X3D head must precede its Scene.")};frames.append(Frame(tag:name,node:nil,container:nil));return
        }
        if name=="meta" {
            guard frames.last?.tag=="head",Set(attrs.keys).isSubset(of:["name","content","dir","lang","http-equiv","scheme"]),attrs["name"] != nil,attrs["content"] != nil else {throw GeometryIOError.invalid("Invalid X3D metadata.")};frames.append(Frame(tag:name,node:nil,container:nil));return
        }
        if name=="unit" {
            guard frames.last?.tag=="head",Set(attrs.keys).isSubset(of:["category","name","conversionFactor"]),attrs["category"]=="length",!seenLengthUnit,let value=Double(attrs["conversionFactor"] ?? ""),value.isFinite,value>0 else {throw GeometryIOError.unsupported("X3D supports one positive length unit declaration only.")};lengthScale=value;seenLengthUnit=true;frames.append(Frame(tag:name,node:nil,container:nil));return
        }
        guard frames.last?.tag=="Scene" || frames.last?.node != nil,let schema=VRSchema.fields[name] else {throw GeometryIOError.unsupported("Unsupported X3D node \(name). Only static indexed geometry, groups and diffuse materials are supported.")}
        let node=VRNode(name)
        if let use=attrs["USE"] {
            guard attrs["DEF"]==nil,Set(attrs.keys).isSubset(of:["USE","containerField"]) else {throw GeometryIOError.invalid("X3D USE cannot redefine node fields.")};node.use=use
        } else {
            node.definition=attrs["DEF"]
            for (key,text) in attrs where !["DEF","containerField"].contains(key) {
                guard let kind=schema[key] else {throw GeometryIOError.unsupported("Unsupported X3D field \(name).\(key).")}
                switch kind {
                case .fixed,.numbers:
                    let tokens=text.split(whereSeparator:{$0.isWhitespace || $0==","})
                    guard tokens.count<=1_500_000 else {throw GeometryIOError.invalid("X3D numeric field exceeds limits.")}
                    let ns=try tokens.map {token->Double in guard let n=Double(token),n.isFinite,abs(n)<=1e12 else {throw GeometryIOError.invalid("Invalid X3D number.")};return n}
                    if let expected=kind.count,ns.count != expected {throw GeometryIOError.invalid("X3D \(key) has the wrong coordinate count.")};node.fields[key] = .numbers(ns)
                case .bool:guard ["true","false"].contains(text) else {throw GeometryIOError.invalid("X3D boolean must be true or false.")};node.fields[key] = .boolean(text=="true")
                case .strings:node.fields[key] = .strings([text])
                case .node,.nodes:throw GeometryIOError.invalid("X3D node fields need child elements.")
                }
            }
        }
        frames.append(Frame(tag:name,node:node,container:attrs["containerField"]))
    }
    func end(_ name:String) throws {
        guard let frame=frames.popLast(),frame.tag==name else {throw GeometryIOError.invalid("Unbalanced X3D elements.")}
        guard let node=frame.node else {return}
        if frames.last?.tag=="Scene" {guard frame.container==nil else {throw GeometryIOError.invalid("Scene root nodes cannot specify containerField.")};nodes.append(node);return}
        guard let parent=frames.last?.node,parent.use==nil else {throw GeometryIOError.invalid("X3D USE nodes cannot contain children.")}
        let defaults=["Material":"material","Appearance":"appearance","IndexedFaceSet":"geometry","IndexedLineSet":"geometry","Coordinate":"coord","Color":"color","TextureCoordinate":"texCoord","Shape":"children","Group":"children","Transform":"children"]
        guard let field=frame.container ?? defaults[node.type],let kind=VRSchema.fields[parent.type]?[field],kind == .node || kind == .nodes else {throw GeometryIOError.invalid("Invalid X3D child/containerField in \(parent.type).")}
        var children=StaticScene.children(parent,field)
        guard kind == .nodes || children.isEmpty else {throw GeometryIOError.invalid("Duplicate X3D single-node field \(field).")};children.append(node);parent.fields[field] = .nodes(children)
    }
}
