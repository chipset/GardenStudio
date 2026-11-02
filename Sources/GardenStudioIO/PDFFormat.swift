import Foundation
import CoreGraphics
import GardenStudioCore

/// PDF profiles are physical points (1/72 inch). Curves are flattened to 0.01 mm.
/// Text, images, clipping and shadings require the separate reference-image mode.
public enum PDFFormat {
    private static let metersPerPoint = 0.0254 / 72
    public static func read(url: URL, page: Int = 1) throws -> ModelDocument {
        guard let pdf = CGPDFDocument(url as CFURL), !pdf.isEncrypted || pdf.isUnlocked, page > 0, page <= pdf.numberOfPages, let source = pdf.page(at: page) else { throw GeometryIOError.invalid("Choose an unlocked PDF and an existing page (pages start at 1).") }
        let state = PDFPathScanner()
        var userUnit: CGPDFReal = 1
        if let dictionary = source.dictionary { CGPDFDictionaryGetNumber(dictionary, "UserUnit", &userUnit) }
        guard userUnit.isFinite, userUnit > 0, userUnit <= 75_000 else { throw GeometryIOError.invalid("The PDF page has invalid physical units.") }
        state.transform = CGAffineTransform(scaleX: userUnit, y: userUnit).rotated(by: -CGFloat(source.rotationAngle) * .pi / 180)
        let stream = CGPDFContentStreamCreateWithPage(source)
        defer { CGPDFContentStreamRelease(stream) }
        state.scan(stream)
        if let error = state.failure { throw GeometryIOError.invalid(error) }
        guard !state.paths.isEmpty else { throw GeometryIOError.invalid("This PDF page contains no supported vector paths. Use PDF reference mode for images or text.") }
        let paths = state.paths.map { VectorPath(points: $0.points.map { VectorPoint(x: $0.x * metersPerPoint, y: $0.y * metersPerPoint) }, closed: $0.closed, name: $0.name, colorHex: $0.colorHex) }
        return try VectorProfiles.document(paths: paths, name: url.deletingPathExtension().lastPathComponent)
    }

    public static func write(_ document: ModelDocument, to url: URL) throws {
        let paths = try VectorProfiles.paths(document: document)
        let points = paths.flatMap(\.points)
        guard let minX = points.map(\.x).min(), let minY = points.map(\.y).min(), let maxX = points.map(\.x).max(), let maxY = points.map(\.y).max() else { throw GeometryIOError.invalid("There are no top-view profiles to export.") }
        let scale = 1 / metersPerPoint
        var box = CGRect(x: minX*scale, y: minY*scale, width: max((maxX-minX)*scale,1), height: max((maxY-minY)*scale,1))
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw GeometryIOError.invalid("The PDF destination could not be opened.") }
        context.beginPDFPage(nil); context.setLineWidth(0.25)
        for path in paths {
            guard let first = path.points.first else { continue }
            let hex = UInt32(path.colorHex.dropFirst(), radix:16) ?? 0
            context.setStrokeColor(CGColor(red: CGFloat((hex>>16)&255)/255, green: CGFloat((hex>>8)&255)/255, blue: CGFloat(hex&255)/255, alpha:1))
            context.move(to: CGPoint(x:first.x*scale,y:first.y*scale))
            for point in path.points.dropFirst() { context.addLine(to: CGPoint(x:point.x*scale,y:point.y*scale)) }
            if path.closed { context.closePath() }
            context.strokePath()
        }
        context.endPDFPage(); context.closePDF()
    }
}

private final class PDFPathScanner {
    var paths: [VectorPath] = []
    var transform = CGAffineTransform.identity
    var stack: [CGAffineTransform] = []
    var subpaths: [(points:[CGPoint], closed:Bool)] = []
    var current: [CGPoint] = []
    var failure: String?
    var depth = 0
    var operations = 0
    var totalPoints = 0

    func fail(_ text: String) { if failure == nil { failure = text } }
    func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
        var result = [CGFloat](repeating:0,count:count)
        for index in (0..<count).reversed() {
            var value: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &value), value.isFinite, abs(value) <= 1e12 else { fail("The PDF contains malformed vector operands."); return nil }
            result[index] = value
        }
        return result
    }
    func finishSubpath(_ closed: Bool = false) {
        if current.count >= 2 { subpaths.append((current,closed)) }
        current = []
    }
    func append(_ point: CGPoint) {
        totalPoints += 1
        guard totalPoints <= 250_000, point.x.isFinite, point.y.isFinite else { fail("The PDF vector geometry exceeds the safe import limit."); return }
        current.append(point)
    }
    func curve(_ a: CGPoint, _ b: CGPoint, _ end: CGPoint, level: Int = 0) {
        guard failure == nil else { return }
        guard let start = current.last else { fail("The PDF curve has no start point."); return }
        func distance(_ p: CGPoint) -> CGFloat {
            let dx=end.x-start.x,dy=end.y-start.y
            let length=hypot(dx,dy)
            return length > 1e-12 ? abs(dy*p.x-dx*p.y+end.x*start.y-end.y*start.x)/length : hypot(p.x-start.x,p.y-start.y)
        }
        let excess = hypot(a.x-start.x,a.y-start.y) + hypot(b.x-a.x,b.y-a.y) + hypot(end.x-b.x,end.y-b.y) - hypot(end.x-start.x,end.y-start.y)
        if level >= 16 || (max(distance(a),distance(b)) <= 0.028346 && excess <= 0.028346) { append(end); return }
        func mid(_ p:CGPoint,_ q:CGPoint)->CGPoint { CGPoint(x:(p.x+q.x)/2,y:(p.y+q.y)/2) }
        let ab=mid(start,a),bc=mid(a,b),cd=mid(b,end),abc=mid(ab,bc),bcd=mid(bc,cd),middle=mid(abc,bcd)
        curve(ab,abc,middle,level:level+1); curve(bcd,cd,end,level:level+1)
    }
    func handle(_ op: String, _ scanner: CGPDFScannerRef) {
        defer { if failure != nil { CGPDFScannerStop(scanner) } }
        guard failure == nil else { return }
        operations += 1
        guard operations <= 1_000_000 else { fail("The PDF content exceeds the safe import limit."); return }
        switch op {
        case "q": guard stack.count < 128 else { fail("The PDF graphics stack is too deep."); return }; stack.append(transform)
        case "Q": guard let saved = stack.popLast() else { fail("The PDF graphics stack is malformed."); return }; transform=saved
        case "cm": if let v=numbers(scanner,6) { transform=CGAffineTransform(a:v[0],b:v[1],c:v[2],d:v[3],tx:v[4],ty:v[5]).concatenating(transform) }
        case "gs": graphicsState(scanner)
        case "m": if let v=numbers(scanner,2) { finishSubpath(); append(CGPoint(x:v[0],y:v[1]).applying(transform)) }
        case "l": if let v=numbers(scanner,2) { guard !current.isEmpty else { fail("The PDF line has no start point."); return }; append(CGPoint(x:v[0],y:v[1]).applying(transform)) }
        case "c": if let v=numbers(scanner,6) { curve(CGPoint(x:v[0],y:v[1]).applying(transform),CGPoint(x:v[2],y:v[3]).applying(transform),CGPoint(x:v[4],y:v[5]).applying(transform)) }
        case "v": if let v=numbers(scanner,4),let start=current.last { curve(start,CGPoint(x:v[0],y:v[1]).applying(transform),CGPoint(x:v[2],y:v[3]).applying(transform)) }
        case "y": if let v=numbers(scanner,4) { let end=CGPoint(x:v[2],y:v[3]).applying(transform); curve(CGPoint(x:v[0],y:v[1]).applying(transform),end,end) }
        case "re": if let v=numbers(scanner,4) { finishSubpath(); for p in [CGPoint(x:v[0],y:v[1]),CGPoint(x:v[0]+v[2],y:v[1]),CGPoint(x:v[0]+v[2],y:v[1]+v[3]),CGPoint(x:v[0],y:v[1]+v[3])] { append(p.applying(transform)) }; finishSubpath(true) }
        case "h": if let first=current.first { append(first) }
        case "S","s","f","f*","F","B","B*","b","b*":
            finishSubpath(["s","f","f*","F","B","B*","b","b*"].contains(op))
            for subpath in subpaths { var points=subpath.points; var closed=subpath.closed || ["f","f*","F","B","B*","b","b*"].contains(op)
                if points.first == points.last { points.removeLast(); closed=true }
                if points.count >= 2 { paths.append(VectorPath(points:points.map{VectorPoint(x:$0.x,y:$0.y)},closed:closed,name:"PDF path")) }
            }; subpaths=[]
        case "n": current=[]; subpaths=[]
        case "Do": form(scanner)
        case "BT","Tj","TJ","'","\"": fail("This PDF contains unoutlined text. Convert text to outlines or use PDF reference image mode.")
        case "BI","ID","EI": fail("This PDF contains an image. Use PDF reference image mode.")
        case "W","W*","sh": fail("This PDF contains clipping or shading that cannot be preserved as cutter profiles. Use PDF reference image mode.")
        default: break
        }
    }
    func graphicsState(_ scanner:CGPDFScannerRef) {
        var name:UnsafePointer<CChar>?
        let parent=CGPDFScannerGetContentStream(scanner)
        guard CGPDFScannerPopName(scanner,&name),let name,
              let object=CGPDFContentStreamGetResource(parent,"ExtGState",name) else {
            fail("The PDF references a missing graphics state.");return
        }
        var dictionary:CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(object,.dictionary,&dictionary),let dictionary else {
            fail("The PDF graphics state is malformed.");return
        }
        for key in ["CA","ca"] {
            var object:CGPDFObjectRef?
            if CGPDFDictionaryGetObject(dictionary,key,&object) {
                var value:CGPDFReal=0
                guard CGPDFDictionaryGetNumber(dictionary,key,&value),value.isFinite,value==1 else {
                    fail("PDF transparency cannot be preserved as cutter profiles. Use PDF reference image mode.");return
                }
            }
        }
        for (key,allowed) in [("SMask","None"),("BM","Normal")] {
            var object:CGPDFObjectRef?
            if CGPDFDictionaryGetObject(dictionary,key,&object) {
                var value:UnsafePointer<CChar>?
                guard let object,CGPDFObjectGetValue(object,.name,&value),let value,
                      String(cString:value)==allowed || (key=="BM" && String(cString:value)=="Compatible") else {
                    fail("PDF transparency masks or blending cannot be preserved as cutter profiles. Use PDF reference image mode.");return
                }
            }
        }
    }
    func form(_ scanner: CGPDFScannerRef) {
        var name: UnsafePointer<CChar>?
        let parent=CGPDFScannerGetContentStream(scanner)
        guard CGPDFScannerPopName(scanner,&name), let name, let object=CGPDFContentStreamGetResource(parent,"XObject",name) else { fail("The PDF references a missing object."); return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object,.stream,&stream),let stream, let dictionary=CGPDFStreamGetDictionary(stream) else { fail("The PDF XObject is malformed."); return }
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary,"Subtype",&subtype),let subtype else { fail("The PDF XObject has no type."); return }
        guard String(cString:subtype)=="Form" else { fail("This PDF contains an image XObject. Use PDF reference image mode."); return }
        guard depth < 16 else { fail("The PDF form nesting exceeds the safe import limit."); return }
        let savedTransform=transform,savedStack=stack,savedCurrent=current,savedSubpaths=subpaths
        defer { transform=savedTransform;stack=savedStack;current=savedCurrent;subpaths=savedSubpaths }
        var matrix: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary,"Matrix",&matrix),let matrix {
            guard CGPDFArrayGetCount(matrix)==6 else { fail("The PDF form matrix is malformed."); return }
            var values=[CGPDFReal](repeating:0,count:6)
            for i in 0..<6 { guard CGPDFArrayGetNumber(matrix,i,&values[i]),values[i].isFinite else { fail("The PDF form matrix is invalid."); return } }
            transform=CGAffineTransform(a:values[0],b:values[1],c:values[2],d:values[3],tx:values[4],ty:values[5]).concatenating(transform)
        }
        let firstPath=paths.count
        let formTransform=transform
        var boundsArray: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary,"BBox",&boundsArray),let boundsArray,CGPDFArrayGetCount(boundsArray)==4 else { fail("The PDF form has no valid bounds."); return }
        var bounds=[CGPDFReal](repeating:0,count:4)
        for i in 0..<4 { guard CGPDFArrayGetNumber(boundsArray,i,&bounds[i]),bounds[i].isFinite else { fail("The PDF form bounds are invalid."); return } }
        let boundsRect=CGRect(x:bounds[0],y:bounds[1],width:bounds[2]-bounds[0],height:bounds[3]-bounds[1]).standardized.insetBy(dx:-0.001,dy:-0.001)
        guard abs(formTransform.a*formTransform.d-formTransform.b*formTransform.c)>1e-20 else { fail("The PDF form transform collapses its geometry."); return }
        current=[];subpaths=[];stack=[];depth += 1
        var resources: CGPDFDictionaryRef?
        CGPDFDictionaryGetDictionary(dictionary,"Resources",&resources)
        let content=CGPDFContentStreamCreateWithStream(stream,resources ?? dictionary,parent)
        defer { CGPDFContentStreamRelease(content) }
        scan(content); depth -= 1
        let inverse=formTransform.inverted()
        if paths.dropFirst(firstPath).flatMap(\.points).contains(where: { !boundsRect.contains(CGPoint(x:$0.x,y:$0.y).applying(inverse)) }) { fail("The PDF form clips its vector paths. Use PDF reference image mode.") }
    }
    func scan(_ stream: CGPDFContentStreamRef) {
        guard let table=CGPDFOperatorTableCreate() else { fail("Unable to open PDF scanner."); return }
        CGPDFOperatorTableSetCallback(table, "q", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("q", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "Q", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("Q", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "cm", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("cm", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "gs", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("gs", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "m", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("m", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "l", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("l", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "c", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("c", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "v", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("v", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "y", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("y", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "re", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("re", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "h", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("h", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "S", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("S", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "s", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("s", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "f", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("f", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "f*", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("f*", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "F", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("F", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "B", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("B", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "B*", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("B*", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "b", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("b", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "b*", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("b*", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "n", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("n", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "Do", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("Do", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "BT", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("BT", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "Tj", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("Tj", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "TJ", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("TJ", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "'", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("'", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "\"", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("\"", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "BI", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("BI", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "ID", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("ID", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "EI", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("EI", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "W", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("W", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "W*", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("W*", scanner)
        })
        CGPDFOperatorTableSetCallback(table, "sh", { scanner, info in
            guard let info else { return }
            Unmanaged<PDFPathScanner>.fromOpaque(info).takeUnretainedValue().handle("sh", scanner)
        })
        defer { CGPDFOperatorTableRelease(table) }
        let scanner=CGPDFScannerCreate(stream,table,Unmanaged.passUnretained(self).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        if !CGPDFScannerScan(scanner) { fail("The PDF content stream is malformed.") }
        if !stack.isEmpty { fail("The PDF graphics stack is unbalanced.") }
    }
}
