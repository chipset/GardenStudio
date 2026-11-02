import Foundation
import CoreGraphics
import SketchCore

/// A deliberately bounded, non-executing EPS/Illustrator 8 path reader.
/// Procedure dictionaries, text, images, clipping, patterns and arbitrary PostScript are rejected.
public enum EPSFormat {
    public static func read(url: URL, metersPerUnit: Double? = nil) throws -> ModelDocument {
        let data=try Data(contentsOf:url)
        guard data.count<=32*1024*1024,let text=String(data:data,encoding:.utf8),text.hasPrefix("%!PS") else {throw VectorIO.invalid("Expected a UTF-8 EPS/legacy AI path file under 32 MB. Modern PDF-based AI requires PDF import.")}
        let unit=metersPerUnit ?? 0.0254/72
        guard unit.isFinite,unit>0 else {throw VectorIO.invalid("Invalid EPS units.")}
        let lines=text.components(separatedBy:.newlines)
        guard !lines.contains(where:{$0.hasPrefix("%%BeginBinary") || $0.hasPrefix("%%BeginData") || $0.hasPrefix("%%BeginResource") || $0.hasPrefix("%%BeginProlog")}) else {throw VectorIO.invalid("EPS resources and PostScript prologs are unsupported. Export plain EPS paths without a prolog.")}
        let body=lines.map {String($0.prefix(while:{$0 != "%"}))}.joined(separator:"\n")
        // No strings, executable procedures, dictionaries, resource names or file access.
        guard !body.contains(where:{"(){}<>/".contains($0)}) else {throw VectorIO.invalid("EPS contains PostScript procedures, text or resources. Only plain vector path operators are supported.")}
        let tokens=body.replacingOccurrences(of:"[",with:" [ ").replacingOccurrences(of:"]",with:" ] ").split(whereSeparator:{$0.isWhitespace}).map(String.init)
        guard tokens.count<=2_000_000 else {throw VectorIO.invalid("EPS token limit exceeded.")}
        var numbers:[Double]=[],array:[Double]?,path="",paths:[VectorPath]=[],color="#000000",matrix=CGAffineTransform.identity,state:[(CGAffineTransform,String)]=[],current=CGPoint.zero,substart=CGPoint.zero,pointCount=0
        func take(_ count:Int) throws ->[Double] {
            guard numbers.count==count else {throw VectorIO.invalid("Incorrect operand count in EPS path.")};let result=numbers;numbers=[];return result
        }
        func flush(_ close:Bool=false) throws {
            guard !path.isEmpty else {return}
            
            for var p in try vectorPath(path) {
                if close { p.closed=true }
                p.points=p.points.map {let q=CGPoint(x:$0.x,y:$0.y).applying(matrix);return VectorPoint(x:q.x*unit,y:q.y*unit)};p.colorHex=color;pointCount += p.points.count;guard pointCount<=1_000_000 else {throw VectorIO.invalid("EPS exceeds the million-point import limit.")};paths.append(p)
            }
            guard paths.count<=50_000 else {throw VectorIO.invalid("EPS path count limit exceeded.")};path=""
        }
        func channel(_ value:Double) ->Int {Int((max(0,min(1,value))*255).rounded())}
        for token in tokens {
            if let n=Double(token) {guard n.isFinite,abs(n)<=1e12,numbers.count<16 else {throw VectorIO.invalid("Invalid EPS numeric operands.")};numbers.append(n);continue}
            switch token {
            case "[":guard numbers.isEmpty,array==nil else {throw VectorIO.invalid("Invalid EPS array.")};array=[]
            case "]":guard array != nil else {throw VectorIO.invalid("Invalid EPS array.")};array=numbers;numbers=[]
            case "moveto","m","rmoveto":
                let v=try take(2);let x=v[0]+(token == "rmoveto" ? current.x:0),y=v[1]+(token == "rmoveto" ? current.y:0);path += " M\(vn(x)) \(vn(y))";current=CGPoint(x:x,y:y);substart=current
            case "lineto","l","rlineto":
                guard !path.isEmpty else {throw VectorIO.invalid("EPS lineto needs moveto.")};let v=try take(2);let x=v[0]+(token == "rlineto" ? current.x:0),y=v[1]+(token == "rlineto" ? current.y:0);path += " L\(vn(x)) \(vn(y))";current=CGPoint(x:x,y:y)
            case "curveto","c","rcurveto":
                guard !path.isEmpty else {throw VectorIO.invalid("EPS curve needs moveto.")};var v=try take(6)
                if token == "rcurveto" {for i in stride(from:0,to:6,by:2) {v[i]+=current.x;v[i+1]+=current.y}}
                path += " C"+v.map(vn).joined(separator:" ");current=CGPoint(x:v[4],y:v[5])
            case "v","y":
                let v=try take(4);guard !path.isEmpty else {throw VectorIO.invalid("EPS curve needs moveto.")}
                let values=token == "v" ? [current.x,current.y]+v:[v[0],v[1],v[2],v[3],v[2],v[3]]
                path += " C"+values.map(vn).joined(separator:" ");current=CGPoint(x:v[2],y:v[3])
            case "closepath","h":_ = try take(0);guard !path.isEmpty else {throw VectorIO.invalid("Unmatched EPS closepath.")};path += " Z";current=substart
            case "stroke","S":_ = try take(0);try flush()
            case "s":_ = try take(0);try flush(true)
            case "fill","eofill","f","F","f*","B","B*","b","b*":_ = try take(0);try flush(true)
            case "newpath","n","N":_ = try take(0);path=""
            case "setrgbcolor","rg","RG","Xa","XA":
                let v=try take(3);color=String(format:"#%02x%02x%02x",channel(v[0]),channel(v[1]),channel(v[2]))
            case "setgray","g","G":let v=try take(1);let c=channel(v[0]);color=String(format:"#%02x%02x%02x",c,c,c)
            case "setcmykcolor","k","K":let v=try take(4);color=String(format:"#%02x%02x%02x",channel((1-v[0])*(1-v[3])),channel((1-v[1])*(1-v[3])),channel((1-v[2])*(1-v[3])))
            case "gsave","q":_ = try take(0);guard state.count<128 else {throw VectorIO.invalid("EPS graphics stack limit exceeded.")};state.append((matrix,color))
            case "grestore","Q":_ = try take(0);guard let s=state.popLast(),path.isEmpty else {throw VectorIO.invalid("Unsupported EPS path/state nesting.")};matrix=s.0;color=s.1
            case "translate","scale","rotate","concat":
                guard path.isEmpty else {throw VectorIO.invalid("EPS transforms inside unfinished paths are unsupported.")};let t:CGAffineTransform
                if token == "concat" { _ = try take(0);guard let a=array,a.count==6 else {throw VectorIO.invalid("EPS concat needs six matrix values.")};t=CGAffineTransform(a:a[0],b:a[1],c:a[2],d:a[3],tx:a[4],ty:a[5]);array=nil }
                else if token == "rotate" {let v=try take(1);t=CGAffineTransform(rotationAngle:v[0] * .pi/180)}
                else {let v=try take(2);t=token == "scale" ? CGAffineTransform(scaleX:v[0],y:v[1]):CGAffineTransform(translationX:v[0],y:v[1])}
                matrix=t.concatenating(matrix)
            case "setlinewidth","w","setlinecap","J","setlinejoin","j","setmiterlimit","M":_ = try take(1)
            case "setdash","d":_ = try take(1);guard array != nil else {throw VectorIO.invalid("EPS dash needs an array.")};array=nil
            case "showpage","u","U","*u","*U":_ = try take(0)
            default:throw VectorIO.invalid("Unsupported EPS/PostScript operator \(token). Export plain paths; arbitrary PostScript is never executed.")
            }
        }
        guard numbers.isEmpty,array==nil,state.isEmpty,path.isEmpty else {throw VectorIO.invalid("EPS ends with incomplete operands, graphics state or an unpainted path.")}
        return try VectorProfiles.document(paths:paths,name:url.deletingPathExtension().lastPathComponent)
    }

    public static func write(_ document:ModelDocument,to url:URL,illustrator:Bool=false) throws {
        let paths=try VectorProfiles.paths(document:document),points=paths.flatMap(\.points),scale=72/0.0254
        let minX=floor(points.map(\.x).min()!*scale),minY=floor(points.map(\.y).min()!*scale),maxX=ceil(points.map(\.x).max()!*scale),maxY=ceil(points.map(\.y).max()!*scale)
        guard [minX,minY,maxX,maxY].allSatisfy({$0.isFinite && abs($0)<=1e12}),
              points.allSatisfy({abs($0.x*scale)<=1e12 && abs($0.y*scale)<=1e12}) else {
            throw VectorIO.invalid("EPS coordinates exceed the supported range after conversion to physical points.")
        }
        var text="%!PS-Adobe-3.0 EPSF-3.0\n%%Creator: SketchMake\n%%BoundingBox: \(vn(minX)) \(vn(minY)) \(vn(maxX)) \(vn(maxY))\n"
        if illustrator {text += "%%AI8_CreatorVersion: 8.0\n"}
        text += "%%EndComments\n"
        for p in paths {
            let rgb=UInt32(p.colorHex.dropFirst(),radix:16) ?? 0
            text += "\(vn(Double((rgb>>16)&255)/255)) \(vn(Double((rgb>>8)&255)/255)) \(vn(Double(rgb&255)/255)) setrgbcolor\nnewpath\n"
            for (i,q) in p.points.enumerated() {text += "\(vn(q.x*scale)) \(vn(q.y*scale)) \(i==0 ? "moveto":"lineto")\n"}
            if p.closed {text += "closepath\n"};text += "stroke\n"
        }
        text += "showpage\n%%EOF\n";try text.write(to:url,atomically:true,encoding:.utf8)
    }
}
