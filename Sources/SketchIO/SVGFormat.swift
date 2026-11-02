import Foundation
import CoreGraphics
import SketchCore

public enum SVGFormat {
    public static func read(url: URL, metersPerUnit: Double? = nil) throws -> ModelDocument {
        let data = try Data(contentsOf:url)
        guard data.count <= 32*1024*1024, let text = String(data:data,encoding:.utf8), !text.localizedCaseInsensitiveContains("<!DOCTYPE"), !text.localizedCaseInsensitiveContains("<!ENTITY"), !text.localizedCaseInsensitiveContains("<?xml-stylesheet") else { throw VectorIO.invalid("SVG must be UTF-8, under 32 MB and contain no DTD/entities.") }
        let delegate = SVGReader(scale:metersPerUnit)
        let parser = XMLParser(data:data); parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), delegate.failure == nil else { throw delegate.failure ?? parser.parserError ?? VectorIO.invalid("Malformed SVG XML.") }
        return try VectorProfiles.document(paths:delegate.paths,name:url.deletingPathExtension().lastPathComponent)
    }
    public static func write(_ document: ModelDocument, to url: URL, metersPerUnit: Double = 0.001) throws {
        guard metersPerUnit.isFinite, metersPerUnit > 0 else { throw VectorIO.invalid("Invalid SVG unit scale.") }
        let paths = try VectorProfiles.paths(document:document), points = paths.flatMap(\.points)
        let minX=points.map(\.x).min()!, minY=points.map(\.y).min()!, maxX=points.map(\.x).max()!,maxY=points.map(\.y).max()!
        let w=max(maxX-minX,metersPerUnit),h=max(maxY-minY,metersPerUnit)
        guard [w*1000,h*1000,minX/metersPerUnit,minY/metersPerUnit,w/metersPerUnit,h/metersPerUnit].allSatisfy({$0.isFinite && abs($0)<=1e12}),
              points.allSatisfy({abs($0.x/metersPerUnit)<=1e12 && abs($0.y/metersPerUnit)<=1e12}) else {
            throw VectorIO.invalid("SVG coordinates exceed the supported range after unit conversion.")
        }
        var text = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" data-sketchmake-origin-x=\"\(vn(minX))\" data-sketchmake-origin-y=\"\(vn(minY))\" width=\"\(vn(w*1000))mm\" height=\"\(vn(h*1000))mm\" viewBox=\"\(vn(minX/metersPerUnit)) \(vn(minY/metersPerUnit)) \(vn(w/metersPerUnit)) \(vn(h/metersPerUnit))\">\n"
        for (index,p) in paths.enumerated() {
            let d = p.points.enumerated().map { "\($0.offset == 0 ? "M" : "L")\(vn($0.element.x/metersPerUnit)) \(vn($0.element.y/metersPerUnit))" }.joined(separator:" ") + (p.closed ? " Z" : "")
            text += "<path id=\"path-\(index+1)\" data-name=\"\(try xml(p.name))\" d=\"\(d)\" fill=\"none\" stroke=\"\(p.colorHex)\" stroke-width=\"0.2\"/>\n"
        }
        text += "</svg>\n"; try text.write(to:url,atomically:true,encoding:.utf8)
    }
}

enum VectorIO: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(s)=self { return s }; return nil }
}
func vn(_ n: Double) -> String { String(format:"%.12g",locale:Locale(identifier:"en_US_POSIX"),n) }
private func xml(_ s:String) throws ->String {
    guard s.unicodeScalars.allSatisfy({ $0.value == 9 || $0.value == 10 || $0.value == 13 || (0x20...0xD7FF).contains($0.value) || (0xE000...0xFFFD).contains($0.value) || (0x10000...0x10FFFF).contains($0.value) }) else {throw VectorIO.invalid("SVG labels contain characters prohibited by XML 1.0.")}
    return s.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"\"",with:"&quot;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\n",with:"&#10;").replacingOccurrences(of:"\r",with:"&#13;").replacingOccurrences(of:"\t",with:"&#9;")
}

/// Tokenizer rejects all unconsumed input, including malformed exponent tails.
func vectorTokens(_ text:String, commands:Bool = true) throws -> [String] {
    let pattern = commands ? "[A-Za-z]|[-+]?(?:[0-9]+\\.?[0-9]*|\\.[0-9]+)(?:[eE][-+]?[0-9]+)?" : "[-+]?(?:[0-9]+\\.?[0-9]*|\\.[0-9]+)(?:[eE][-+]?[0-9]+)?"
    let regex = try NSRegularExpression(pattern:pattern), ns=text as NSString
    let matches=regex.matches(in:text,range:NSRange(location:0,length:ns.length))
    var end=0, tokens:[String]=[]
    for match in matches {
        let gap=ns.substring(with:NSRange(location:end,length:match.range.location-end))
        guard gap.allSatisfy({ $0.isWhitespace || $0 == "," }) else { throw VectorIO.invalid("Malformed vector numbers.") }
        let t=ns.substring(with:match.range)
        if let n=Double(t), !n.isFinite || abs(n)>1e12 { throw VectorIO.invalid("Vector coordinates exceed supported bounds.") }
        tokens.append(t); end=NSMaxRange(match.range)
    }
    guard ns.substring(from:end).allSatisfy({$0.isWhitespace || $0 == ","}),tokens.count <= 2_000_000 else { throw VectorIO.invalid("Malformed or excessive vector data.") }
    return tokens
}

func vectorPath(_ d:String) throws -> [VectorPath] {
    let ts=try vectorTokens(d); var i=0,cmd="",previous="",p=CGPoint.zero,start=CGPoint.zero,control=CGPoint.zero,points:[VectorPoint]=[],result:[VectorPath]=[];var totalPoints=0
    func flush(_ closed:Bool) {
        if closed,points.count>1,points.first==points.last { points.removeLast() }
        if points.count>=2 { result.append(VectorPath(points:points,closed:closed)) }; points=[]
    }
    func add(_ q:CGPoint) throws {
        guard q.x.isFinite,q.y.isFinite else {throw VectorIO.invalid("SVG path arithmetic exceeds the supported numeric range.")}
        guard points.count < 250_000,totalPoints < 1_000_000 else { throw VectorIO.invalid("Curve tessellation exceeds limits.") }
        if points.last != VectorPoint(x:q.x,y:q.y) { totalPoints += 1;points.append(VectorPoint(x:q.x,y:q.y)) }; p=q
    }
    func number() throws -> Double { guard i<ts.count,let n=Double(ts[i]) else { throw VectorIO.invalid("Incomplete SVG path command.") }; i+=1; return n }
    func point(_ relative:Bool) throws -> CGPoint { let x=try number(),y=try number(); return CGPoint(x:x+(relative ? p.x:0),y:y+(relative ? p.y:0)) }
    while i<ts.count {
        if Double(ts[i]) == nil { cmd=ts[i];i+=1 }
        guard !cmd.isEmpty else { throw VectorIO.invalid("SVG path is missing a command.") }
        let upper=cmd.uppercased(),rel=cmd != upper
        if upper == "Z" { guard !points.isEmpty else { throw VectorIO.invalid("Unmatched SVG closepath.") }; flush(true); p=start;previous=upper;cmd="";continue }
        if upper != "M",points.isEmpty {
            guard previous == "Z" else {throw VectorIO.invalid("SVG path must begin with moveto.")}
            try add(p);start=p
        }
        switch upper {
        case "M": let q=try point(rel);flush(false);try add(q);start=q;cmd=rel ? "l":"L"
        case "L": try add(point(rel))
        case "H": let x=try number();try add(CGPoint(x:x+(rel ? p.x:0),y:p.y))
        case "V": let y=try number();try add(CGPoint(x:p.x,y:y+(rel ? p.y:0)))
        case "C","S","Q","T":
            let a=p
            let reflected=CGPoint(x:2*p.x-control.x,y:2*p.y-control.y)
            var b:CGPoint,c:CGPoint,e:CGPoint
            if upper == "C" { b=try point(rel);c=try point(rel);e=try point(rel) }
            else if upper == "S" { b=["C","S"].contains(previous) ? reflected:p;c=try point(rel);e=try point(rel) }
            else {
                let q:CGPoint
                if upper == "Q" { q=try point(rel) } else { q=["Q","T"].contains(previous) ? reflected:p }
                e=try point(rel);b=CGPoint(x:a.x+(q.x-a.x)*2/3,y:a.y+(q.y-a.y)*2/3);c=CGPoint(x:e.x+(q.x-e.x)*2/3,y:e.y+(q.y-e.y)*2/3);control=q
            }
            for step in 1...32 { let t=Double(step)/32,u=1-t;try add(CGPoint(x:u*u*u*a.x+3*u*u*t*b.x+3*u*t*t*c.x+t*t*t*e.x,y:u*u*u*a.y+3*u*u*t*b.y+3*u*t*t*c.y+t*t*t*e.y)) }
            if ["C","S"].contains(upper) {control=c}
        case "A":
            let rx0=abs(try number()),ry0=abs(try number()),phi=try number()*Double.pi/180,large=try number(),sweep=try number(),e=try point(rel),a=p
            guard [0,1].contains(large),[0,1].contains(sweep) else { throw VectorIO.invalid("SVG arc flags must be 0 or 1.") }
            if rx0 == 0 || ry0 == 0 { try add(e); break }
            if a == e {break}
            let cp=cos(phi),sp=sin(phi),dx=(a.x-e.x)/2,dy=(a.y-e.y)/2,xp=cp*dx+sp*dy,yp = -sp*dx+cp*dy
            // Normalize by the radii before squaring. Direct radius products
            // underflow for tiny authored radii, although SVG's mandatory
            // radius correction can produce an ordinary, representable arc.
            let factor=max(1,hypot(xp/rx0,yp/ry0)),rx=rx0*factor,ry=ry0*factor
            guard factor.isFinite,rx.isFinite,ry.isFinite,rx>0,ry>0 else {throw VectorIO.invalid("SVG arc radii exceed the supported numeric range.")}
            let normalizedX=xp/rx,normalizedY=yp/ry
            let denominator=normalizedX*normalizedX+normalizedY*normalizedY
            guard denominator.isFinite,denominator>0 else {throw VectorIO.invalid("SVG arc endpoints exceed the supported numeric range.")}
            let coefficient=(large == sweep ? -1.0:1.0)*sqrt(max(0,(1-denominator)/denominator))
            let cxp=coefficient*normalizedY*rx,cyp = -coefficient*normalizedX*ry,cx=cp*cxp-sp*cyp+(a.x+e.x)/2,cy=sp*cxp+cp*cyp+(a.y+e.y)/2
            let theta=atan2((yp-cyp)/ry,(xp-cxp)/rx)
            var delta=atan2((-yp-cyp)/ry,(-xp-cxp)/rx)-theta
            guard theta.isFinite,delta.isFinite,cx.isFinite,cy.isFinite else {throw VectorIO.invalid("SVG arc arithmetic exceeds the supported numeric range.")}
            if sweep == 0 && delta > 0 {delta -= 2 * .pi};if sweep == 1 && delta < 0 {delta += 2 * .pi}
            let steps=max(2,Int(ceil(abs(delta)/(.pi/72))))
            for step in 1...steps {let t=theta+delta*Double(step)/Double(steps);try add(step == steps ? e:CGPoint(x:cx+cp*rx*cos(t)-sp*ry*sin(t),y:cy+sp*rx*cos(t)+cp*ry*sin(t)))}
        default: throw VectorIO.invalid("Unsupported SVG path command \(cmd).")
        }
        previous=upper
    }
    flush(false);return result
}

private final class SVGReader: NSObject, XMLParserDelegate {
    var paths:[VectorPath]=[],failure:Error?
    var pointCount=0
    let scale:Double?
    var matrices:[CGAffineTransform]=[]
    var paints:[(fill:String,stroke:String)]=[]
    init(scale:Double?) {self.scale=scale}
    func parser(_ parser:XMLParser,didStartElement element:String,namespaceURI:String?,qualifiedName:String?,attributes a:[String:String]) {
        do { try start(element,a) } catch {failure=error;parser.abortParsing()}
    }
    func parser(_ parser:XMLParser,didEndElement:String,namespaceURI:String?,qualifiedName:String?) { if !matrices.isEmpty {matrices.removeLast();paints.removeLast()} }
    func start(_ element:String,_ a:[String:String]) throws {
        guard matrices.count < 128 else {throw VectorIO.invalid("SVG nesting limit exceeded.")}
        guard ["svg","g","path","line","polyline","polygon","rect","circle","ellipse","title","desc"].contains(element) else {throw VectorIO.invalid("Unsupported SVG element \(element). Convert text, images, use, clipping and effects to plain paths first.")}
        guard !a.keys.contains(where:{$0.lowercased().hasPrefix("on") || ["href","xlink:href","filter","clip-path","mask","class","display","visibility","marker-start","marker-mid","marker-end"].contains($0)}),!a.values.contains(where:{$0.localizedCaseInsensitiveContains("url(")}) else {throw VectorIO.invalid("SVG active content, resource references, CSS classes and effects are unsupported.")}
        var attrs=a
        if let style=a["style"] {
            for pair in style.split(separator:";") where !pair.isEmpty {
                let parts=pair.split(separator:":",maxSplits:1).map { $0.trimmingCharacters(in:.whitespaces) }
                guard parts.count==2,["fill","stroke","stroke-width","fill-rule","stroke-linecap","stroke-linejoin"].contains(parts[0]) else {throw VectorIO.invalid("Unsupported SVG style. Export plain vector outlines.")};attrs[parts[0]]=parts[1]
            }
        }
        for key in ["opacity","fill-opacity","stroke-opacity"] where attrs[key] != nil && attrs[key] != "1" {throw VectorIO.invalid("SVG transparency is unsupported for profile import.")}
        var m=matrices.last ?? .identity
        if matrices.isEmpty {
            guard element == "svg" else {throw VectorIO.invalid("Missing SVG root.")}
            let unit=scale ?? 0.0254/96
            guard unit.isFinite,unit>0 else {throw VectorIO.invalid("Invalid SVG units.")}
            m=CGAffineTransform(scaleX:unit,y:unit)
            if let box=a["viewBox"] {
                let v=try vectorTokens(box,commands:false).compactMap(Double.init)
                guard v.count==4,v[2]>0,v[3]>0 else {throw VectorIO.invalid("Invalid SVG viewBox.")}
                let w=try length(a["width"] ?? vn(v[2])),h=try length(a["height"] ?? vn(v[3]))
                guard w>0,h>0 else {throw VectorIO.invalid("Invalid SVG viewport.")}
                var sx=w/v[2],sy=h/v[3],tx=0.0,ty=0.0
                let align=a["preserveAspectRatio"] ?? "xMidYMid meet"
                if align != "none" {
                    let parts=align.split(separator:" ").map(String.init)
                    guard let p=parts.first,["xMinYMin","xMidYMin","xMaxYMin","xMinYMid","xMidYMid","xMaxYMid","xMinYMax","xMidYMax","xMaxYMax"].contains(p),parts.count<=2,parts.count==1 || parts[1] == "meet" else {throw VectorIO.invalid("Unsupported SVG aspect ratio.")}
                    let s=parts.last == "slice" ? max(sx,sy):min(sx,sy);sx=s;sy=s
                    tx=(w-v[2]*s)*(p.contains("xMid") ? 0.5:p.contains("xMax") ? 1:0);ty=(h-v[3]*s)*(p.contains("YMid") ? 0.5:p.contains("YMax") ? 1:0)
                }
                m=CGAffineTransform(a:sx*unit,b:0,c:0,d:sy*unit,tx:(tx-v[0]*sx)*unit,ty:(ty-v[1]*sy)*unit)
            }
            if let ox=a["data-sketchmake-origin-x"],let oy=a["data-sketchmake-origin-y"] {
                guard let x=Double(ox),let y=Double(oy),x.isFinite,y.isFinite,abs(x)<=1e12,abs(y)<=1e12 else {throw VectorIO.invalid("Invalid SVG model origin metadata.")}
                m.tx += x;m.ty += y
            }
        } else if element == "svg" {throw VectorIO.invalid("Nested SVG viewports are unsupported. Flatten to paths.")}
        if let t=attrs["transform"] {m=try transform(t).concatenating(m)}
        matrices.append(m)
        // Fill and stroke inherit independently. A child's fill must not replace
        // its inherited stroke, and stroke="none" exposes the inherited fill.
        // https://www.w3.org/TR/SVG11/painting.html
        let parent=paints.last ?? (fill:"#000000",stroke:"none")
        let fill=attrs["fill"] ?? parent.fill,stroke=attrs["stroke"] ?? parent.stroke
        let hasStroke=stroke.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() != "none"
        let hasFill=fill.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() != "none"
        paints.append((fill,stroke))
        // An unpainted helper shape is not a visible contour or cutter path.
        // Keep its inherited state on the stack so a child can explicitly paint.
        guard hasStroke || hasFill else{return}
        let color=try colorHex(hasStroke ? stroke:fill)
        func n(_ key:String,_ fallback:Double=0) throws ->Double {try length(attrs[key] ?? vn(fallback))}
        var found:[VectorPath]=[]
        switch element {
        case "path": found=try vectorPath(attrs["d"] ?? "")
        case "line": found=[VectorPath(points:[VectorPoint(x:try n("x1"),y:try n("y1")),VectorPoint(x:try n("x2"),y:try n("y2"))],closed:false)]
        case "polyline","polygon":
            let ns=try vectorTokens(attrs["points"] ?? "",commands:false).compactMap(Double.init)
            guard ns.count%2==0 else {throw VectorIO.invalid("SVG points need coordinate pairs.")}
            var ps=stride(from:0,to:ns.count,by:2).map {VectorPoint(x:ns[$0],y:ns[$0+1])}
            if ps.count>1,ps.first==ps.last {ps.removeLast()}
            found=[VectorPath(points:ps,closed:element == "polygon")]
        case "rect":
            guard try n("rx")==0,try n("ry")==0 else {throw VectorIO.invalid("Rounded SVG rectangles must be converted to paths.")}
            let x=try n("x"),y=try n("y"),w=try n("width"),h=try n("height")
            guard w>0,h>0 else {throw VectorIO.invalid("SVG rectangle dimensions must be positive.")}
            found=[VectorPath(points:[VectorPoint(x:x,y:y),VectorPoint(x:x+w,y:y),VectorPoint(x:x+w,y:y+h),VectorPoint(x:x,y:y+h)],closed:true)]
        case "circle","ellipse":
            let x=try n("cx"),y=try n("cy"),rx=try n(element == "circle" ? "r":"rx"),ry=try n(element == "circle" ? "r":"ry")
            guard rx>0,ry>0 else {throw VectorIO.invalid("SVG radii must be positive.")}
            found=[VectorPath(points:(0..<144).map {let t=Double($0)*2 * .pi/144;return VectorPoint(x:x+rx*cos(t),y:y+ry*sin(t))},closed:true)]
        default:break
        }
        pointCount += found.reduce(0) {$0+$1.points.count}
        guard pointCount <= 1_000_000 else {throw VectorIO.invalid("SVG exceeds the million-point import limit.")}
        guard paths.count+found.count<=50_000 else {throw VectorIO.invalid("Too many SVG paths.")}
        for var p in found {p.points=p.points.map {let q=CGPoint(x:$0.x,y:$0.y).applying(m);return VectorPoint(x:q.x,y:q.y)};p.name=attrs["data-name"] ?? attrs["id"] ?? element;p.colorHex=color;paths.append(p)}
    }
    func length(_ s:String) throws ->Double {
        let trimmed=s.trimmingCharacters(in:.whitespacesAndNewlines)
        for (suffix,factor) in [("mm",96/25.4),("cm",96/2.54),("in",96.0),("pt",96/72.0),("pc",16.0),("px",1.0)] where trimmed.hasSuffix(suffix) {
            guard let n=Double(trimmed.dropLast(suffix.count)),n.isFinite,abs(n)<=1e12 else {throw VectorIO.invalid("Invalid SVG length.")};return n*factor
        }
        guard let n=Double(trimmed),n.isFinite,abs(n)<=1e12 else {throw VectorIO.invalid("Unsupported SVG length; use physical units or user units.")};return n
    }
    func colorHex(_ s:String) throws ->String {
        let names=["black":"#000000","white":"#ffffff","red":"#ff0000","green":"#008000","blue":"#0000ff","none":"#000000"]
        if let c=names[s.lowercased()] {return c}
        if s.range(of:"^#[0-9a-fA-F]{6}$",options:.regularExpression) != nil {return s}
        if s.range(of:"^#[0-9a-fA-F]{3}$",options:.regularExpression) != nil {return "#"+s.dropFirst().map {"\($0)\($0)"}.joined()}
        throw VectorIO.invalid("Unsupported SVG color \(s); use #RRGGBB colors.")
    }
    func transform(_ text:String) throws ->CGAffineTransform {
        let regex=try NSRegularExpression(pattern:"([A-Za-z]+)\\s*\\(([^)]*)\\)")
        let ns=text as NSString;var end=0,m=CGAffineTransform.identity
        for match in regex.matches(in:text,range:NSRange(location:0,length:ns.length)) {
            guard ns.substring(with:NSRange(location:end,length:match.range.location-end)).allSatisfy({$0.isWhitespace || $0 == ","}) else {throw VectorIO.invalid("Malformed SVG transform.")}
            let name=ns.substring(with:match.range(at:1)),v=try vectorTokens(ns.substring(with:match.range(at:2)),commands:false).compactMap(Double.init);let t:CGAffineTransform
            switch name {
            case "matrix" where v.count==6:t=CGAffineTransform(a:v[0],b:v[1],c:v[2],d:v[3],tx:v[4],ty:v[5])
            case "translate" where v.count==1 || v.count==2:t=CGAffineTransform(translationX:v[0],y:v.count==2 ? v[1]:0)
            case "scale" where v.count==1 || v.count==2:t=CGAffineTransform(scaleX:v[0],y:v.count==2 ? v[1]:v[0])
            case "rotate" where v.count==1 || v.count==3:
                let r=CGAffineTransform(rotationAngle:v[0] * .pi/180)
                t=v.count==1 ? r:CGAffineTransform(translationX:-v[1],y:-v[2]).concatenating(r).concatenating(CGAffineTransform(translationX:v[1],y:v[2]))
            case "skewX" where v.count==1:t=CGAffineTransform(a:1,b:0,c:tan(v[0] * .pi/180),d:1,tx:0,ty:0)
            case "skewY" where v.count==1:t=CGAffineTransform(a:1,b:tan(v[0] * .pi/180),c:0,d:1,tx:0,ty:0)
            default:throw VectorIO.invalid("Unsupported or malformed SVG transform.")
            }
            m=t.concatenating(m);end=NSMaxRange(match.range)
        }
        guard ns.substring(from:end).allSatisfy(\.isWhitespace) else {throw VectorIO.invalid("Malformed SVG transform.")};return m
    }
}
