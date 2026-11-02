import Foundation

/// JSON boundary around the existing Woodwork Studio modeling core. This helper
/// is compiled with that core, so machining and shaped parts use its actual mesh.
private enum WoodworkExchange {
    static let maximumBytes = 100_000_000
    static let maximumVertices = 250_000
    static let maximumTriangles = 500_000
    static let inchesToMeters = 0.0254

    struct Point: Codable {
        var x: Double
        var y: Double
        var z: Double
        init(_ point: Vec3) {x=point.x;y=point.y;z=point.z}
        var vector: Vec3 {Vec3(x,y,z)}
        var isFinite: Bool {[x,y,z].allSatisfy(\.isFinite)}
    }
    struct Mesh: Codable {
        var vertices: [Point]
        var triangles: [Int]
        var lineIndices: [Int]
        init(board: Board) throws {
            let native=BoardGeometry.mesh(board:board)
            vertices=native.vertices.map{Point(board.oriented($0)*inchesToMeters)}
            triangles=native.indices.map(Int.init)
            lineIndices=[]
            try validate()
        }
        func validate() throws {
            guard !vertices.isEmpty,vertices.count<=maximumVertices,
                  triangles.count<=maximumTriangles*3,triangles.count%3==0,!triangles.isEmpty,
                  lineIndices.isEmpty,vertices.allSatisfy(\.isFinite),
                  triangles.allSatisfy({vertices.indices.contains($0)}) else {
                throw ModelError.invalid("A Woodwork item contains empty, invalid or excessive geometry.")
            }
        }
        func matches(_ other: Mesh) -> Bool {
            guard triangles==other.triangles,lineIndices==other.lineIndices,vertices.count==other.vertices.count else{return false}
            return zip(vertices,other.vertices).allSatisfy {left,right in
                let scale=max(1,max(abs(left.x),max(abs(left.y),abs(left.z))))
                return abs(left.x-right.x)<=1e-10*scale && abs(left.y-right.y)<=1e-10*scale && abs(left.z-right.z)<=1e-10*scale
            }
        }
    }
    struct ImportedItem: Codable {
        var board: Board
        var mesh: Mesh
        var origin: Point
        var hidden: Bool
        var locked: Bool
    }
    struct ImportedDocument: Codable {
        var version = 1
        var title: String
        var items: [ImportedItem]
    }
    struct ExportedItem: Decodable {
        var id: UUID
        var name: String
        var material: String
        var hidden: Bool
        var locked: Bool
        var origin: Point
        var yaw: Double
        var sourceBoard: Board?
        var mesh: Mesh?
        var width: Double?
        var depth: Double?
        var height: Double?
        var circular: Bool?
    }
    struct ExportedDocument: Decodable {
        var title: String
        var items: [ExportedItem]
    }
    struct Budget {
        var vertices = 0
        var triangles = 0
        mutating func include(_ mesh: Mesh) throws {
            vertices += mesh.vertices.count;triangles += mesh.triangles.count/3
            guard vertices<=maximumVertices,triangles<=maximumTriangles else {
                throw ModelError.invalid("Woodwork exchange exceeds 250,000 vertices or 500,000 triangles.")
            }
        }
    }
    static func data(at url: URL) throws -> Data {
        guard url.isFileURL else{throw ModelError.invalid("Choose a local Woodwork file.")}
        let resolved=url.resolvingSymlinksInPath()
        let values=try FileManager.default.attributesOfItem(atPath:resolved.path)
        guard values[.type] as? FileAttributeType == .typeRegular,
              let size=values[.size] as? NSNumber,size.intValue<=maximumBytes else {
            throw ModelError.invalid("Choose a regular Woodwork file no larger than 100 MB.")
        }
        let handle=try FileHandle(forReadingFrom:resolved);defer{try? handle.close()}
        let bytes=try handle.read(upToCount:maximumBytes+1) ?? Data()
        guard bytes.count<=maximumBytes else{throw ModelError.invalid("Woodwork input exceeds 100 MB.")}
        return bytes
    }
    static func save<T: Encodable>(_ document: T, to url: URL) throws {
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        let bytes=try encoder.encode(document)
        guard bytes.count<=maximumBytes else{throw ModelError.invalid("Woodwork output exceeds 100 MB.")}
        try bytes.write(to:url,options:.atomic)
    }
    static func independent(_ source: Board) -> Board {
        var board=source
        board.assemblyID=nil;board.componentID=nil;board.dimensionBindings=[]
        return board
    }
    static func read(from input: URL, to output: URL) throws {
        let project=try JSONDecoder().decode(Project.self,from:data(at:input)).validated()
        var items: [ImportedItem]=[],budget=Budget()
        for source in project.boards {
            var board=independent(source)
            board.hidden=project.isHidden(source);board.locked=project.isLocked(source)
            let mesh=try Mesh(board:board);try budget.include(mesh)
            items.append(ImportedItem(board:board,mesh:mesh,origin:Point(board.position*inchesToMeters),hidden:board.hidden,locked:board.locked))
        }
        try save(ImportedDocument(title:project.title,items:items),to:output)
    }
    static func write(from input: URL, to output: URL) throws {
        let document=try JSONDecoder().decode(ExportedDocument.self,from:data(at:input))
        guard document.items.count<=10_000 else{throw ModelError.invalid("Woodwork projects support at most 10,000 separate items.")}
        guard Set(document.items.map(\.id)).count==document.items.count else{throw ModelError.invalid("Woodwork item identifiers must be unique.")}
        var boards: [Board]=[],budget=Budget()
        for item in document.items {
            guard item.origin.isFinite,item.yaw.isFinite else{throw ModelError.invalid("Woodwork item placement must be finite.")}
            var board: Board
            if let source=item.sourceBoard {
                board=independent(source)
                // Validate one standalone source before invoking its geometry kernel.
                _=try Project(boards:[board]).validated()
                let expected=try Mesh(board:board)
                guard let supplied=item.mesh else {throw ModelError.invalid("A retained Woodwork item needs its original mesh for shape verification.")}
                try supplied.validate()
                guard supplied.matches(expected) else {
                    throw ModelError.invalid("\(item.name): its geometry has changed and cannot be written as the original Woodwork part. Export a supported rectangular solid instead.")
                }
            } else {
                guard let width=item.width,let depth=item.depth,let height=item.height,
                      [width,depth,height].allSatisfy({$0.isFinite && $0>0}) else {
                    throw ModelError.invalid("\(item.name): Woodwork export requires a rectangular solid with positive width, depth and height, or an unchanged imported Woodwork item.")
                }
                board=Board(width:width/inchesToMeters,thickness:height/inchesToMeters,length:depth/inchesToMeters)
                if item.circular == true {
                    guard abs(width-depth)<=1e-9*max(width,depth) else {
                        throw ModelError.invalid("\(item.name): native circular stock needs equal width and depth; ellipses cannot be preserved.")
                    }
                    board.profile=BoardProfile(kind:.roundedCorners,amount:board.width/2)
                }
            }
            board.id=item.id;board.name=item.name;board.material=item.material
            board.position=item.origin.vector*(1/inchesToMeters)
            board.hidden=item.hidden;board.locked=false
            board=independent(board)
            var single=try Project(boards:[board]).validated()
            // Use the same trigonometric phase as GardenStudioCore. A floating-point
            // remainder loses that phase for very large finite angles.
            let degrees=atan2(sin(item.yaw),cos(item.yaw))*180 / .pi
            if degrees != 0 {
                single=try PivotTransform.rotating(project:single,selection:[board.id],pivot:board.position,axis:.y,degrees:degrees)
            }
            board=single.boards[0];board.locked=item.locked
            try budget.include(Mesh(board:board))
            boards.append(board)
        }
        let project=try Project(title:document.title,boards:boards).validated()
        try save(project,to:output)
    }
}

@main
private enum GardenStudioWoodworkWorker {
    static func main() {
        do {
            let arguments=CommandLine.arguments
            guard arguments.count==4 else{throw ModelError.invalid("Usage: GardenStudioWoodworkWorker read|write input output")}
            let input=URL(fileURLWithPath:arguments[2]),output=URL(fileURLWithPath:arguments[3])
            switch arguments[1] {
            case "read":try WoodworkExchange.read(from:input,to:output)
            case "write":try WoodworkExchange.write(from:input,to:output)
            default:throw ModelError.invalid("Unknown Woodwork exchange operation.")
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8))
            exit(1)
        }
    }
}
