import Foundation

public struct CameraState: Codable, Equatable {
    public var target: Vec3
    public var yaw: Double
    public var pitch: Double
    public var distance: Double
    public var orthographic: Bool
    public init(target: Vec3 = Vec3(0, 1, 0), yaw: Double = .pi / 4, pitch: Double = 0.52, distance: Double = 19, orthographic: Bool = false) {
        self.target = target; self.yaw = yaw; self.pitch = pitch; self.distance = distance; self.orthographic = orthographic
    }
    private enum CodingKeys: String, CodingKey { case target, yaw, pitch, distance, orthographic }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(target: try c.decodeIfPresent(Vec3.self, forKey: .target) ?? Vec3(0, 1, 0),
                  yaw: try c.decodeIfPresent(Double.self, forKey: .yaw) ?? .pi / 4,
                  pitch: try c.decodeIfPresent(Double.self, forKey: .pitch) ?? 0.52,
                  distance: try c.decodeIfPresent(Double.self, forKey: .distance) ?? 19,
                  orthographic: try c.decodeIfPresent(Bool.self, forKey: .orthographic) ?? false)
    }
    public func validate() throws {
        guard finite(target), yaw.isFinite, pitch.isFinite, distance.isFinite, distance > 0, distance <= 10_000_000 else {
            throw GeometryIOError.invalid("Saved camera coordinates and distance must be finite; distance must be positive.")
        }
    }
}

public struct SavedScene: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var camera: CameraState
    public var hiddenIDs: [UUID]
    /// nil preserves legacy scene behavior; an empty array means all layers hidden.
    public var visibleLayerIDs: [UUID]?
    public init(id: UUID = UUID(), name: String, camera: CameraState, hiddenIDs: [UUID] = [], visibleLayerIDs: [UUID]? = nil) { self.id = id; self.name = name; self.camera = camera; self.hiddenIDs = hiddenIDs; self.visibleLayerIDs = visibleLayerIDs }
    private enum CodingKeys: String, CodingKey { case id, name, camera, hiddenIDs, visibleLayerIDs }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name), camera: try c.decode(CameraState.self, forKey: .camera), hiddenIDs: try c.decodeIfPresent([UUID].self, forKey: .hiddenIDs) ?? [], visibleLayerIDs: try c.decodeIfPresent([UUID].self, forKey: .visibleLayerIDs))
    }
}

public struct ModelAnnotation: Identifiable, Codable, Equatable {
    public var id: UUID
    public var kind: String
    public var start: Vec3
    public var end: Vec3?
    public var text: String
    public init(id: UUID = UUID(), kind: String, start: Vec3, end: Vec3? = nil, text: String = "") {
        self.id = id; self.kind = kind; self.start = start; self.end = end; self.text = text
    }
}

public struct GuideLine: Identifiable, Codable, Equatable {
    public var id: UUID
    public var start: Vec3
    public var end: Vec3
    public init(id: UUID = UUID(), start: Vec3, end: Vec3) { self.id = id; self.start = start; self.end = end }
}

/// Points with a positive signed distance are removed by the presentation cut.
public struct SectionPlane: Codable, Equatable {
    public var point: Vec3
    public var normal: Vec3
    public var enabled: Bool
    public init(point: Vec3, normal: Vec3, enabled: Bool = true) { self.point = point; self.normal = normal; self.enabled = enabled }
    public func normalized() throws -> SectionPlane {
        let length = hypot(hypot(normal.x, normal.y), normal.z)
        guard finite(point), finite(normal), length.isFinite, length > 1e-12 else { throw GeometryIOError.invalid("A section plane needs a finite point and a nonzero normal.") }
        return SectionPlane(point: point, normal: Vec3(normal.x / length, normal.y / length, normal.z / length), enabled: enabled)
    }
    public func signedDistance(to position: Vec3) throws -> Double {
        guard finite(position) else { throw GeometryIOError.invalid("Section test position must be finite.") }
        let n = try normalized().normal
        return (position.x - point.x) * n.x + (position.y - point.y) * n.y + (position.z - point.z) * n.z
    }
}

/// Persistent right-angle drawing frame. X and normal define roll; Y is derived.
public struct DrawingAxes: Codable, Equatable {
    public var origin: Vec3
    public var xAxis: Vec3
    public var yAxis: Vec3
    public var normal: Vec3

    public init(origin:Vec3,xAxis:Vec3,normal:Vec3)throws {
        let xLength=Self.length(xAxis),nLength=Self.length(normal)
        guard Self.finite(origin),Self.finite(xAxis),Self.finite(normal),xLength.isFinite,nLength.isFinite,xLength>1e-12,nLength>1e-12 else {
            throw GeometryIOError.invalid("Drawing axes need a finite origin and nonzero directions.")
        }
        let x=Vec3(xAxis.x/xLength,xAxis.y/xLength,xAxis.z/xLength)
        let n=Vec3(normal.x/nLength,normal.y/nLength,normal.z/nLength)
        let alignment=x.x*n.x+x.y*n.y+x.z*n.z
        guard abs(alignment)<1e-6 else {throw GeometryIOError.invalid("Drawing X and normal directions must be perpendicular.")}
        let y=Vec3(x.y*n.z-x.z*n.y,x.z*n.x-x.x*n.z,x.x*n.y-x.y*n.x)
        self.origin=origin;self.xAxis=x;self.yAxis=y;self.normal=n
    }
    private enum CodingKeys:String,CodingKey {case origin,xAxis,yAxis,normal}
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(origin:c.decode(Vec3.self,forKey:.origin),xAxis:c.decode(Vec3.self,forKey:.xAxis),normal:c.decode(Vec3.self,forKey:.normal))
    }
    public func validate()throws {
        _=try DrawingAxes(origin:origin,xAxis:xAxis,normal:normal)
        let expectedY=Vec3(xAxis.y*normal.z-xAxis.z*normal.y,xAxis.z*normal.x-xAxis.x*normal.z,xAxis.x*normal.y-xAxis.y*normal.x)
        let mismatch=Vec3(yAxis.x-expectedY.x,yAxis.y-expectedY.y,yAxis.z-expectedY.z)
        guard Self.finite(yAxis),abs(Self.length(xAxis)-1)<1e-6,abs(Self.length(normal)-1)<1e-6,abs(Self.length(yAxis)-1)<1e-6,
              abs(xAxis.x*yAxis.x+xAxis.y*yAxis.y+xAxis.z*yAxis.z)<1e-6,
              abs(yAxis.x*normal.x+yAxis.y*normal.y+yAxis.z*normal.z)<1e-6,Self.length(mismatch)<1e-6 else {
            throw GeometryIOError.invalid("Drawing axes must be a finite orthonormal frame.")
        }
    }
    private static func length(_ v:Vec3)->Double {hypot(hypot(v.x,v.y),v.z)}
    private static func finite(_ v:Vec3)->Bool {[v.x,v.y,v.z].allSatisfy(\.isFinite)}
}

public struct PresentationState: Codable, Equatable {
    public var scenes: [SavedScene]
    public var annotations: [ModelAnnotation]
    public var guides: [GuideLine]
    public var camera: CameraState
    public var style: String
    public var shadows: Bool
    public var orthographic: Bool
    public var section: SectionPlane?
    public var drawingAxes: DrawingAxes?
    public var units: String
    public init(scenes: [SavedScene] = [], annotations: [ModelAnnotation] = [], guides: [GuideLine] = [], camera: CameraState = CameraState(), style: String = "solid", shadows: Bool = false, orthographic: Bool = false, section: SectionPlane? = nil, drawingAxes:DrawingAxes?=nil, units: String = "meters") {
        self.scenes = scenes; self.annotations = annotations; self.guides = guides; self.camera = camera; self.style = style; self.shadows = shadows; self.orthographic = orthographic; self.section = section; self.drawingAxes=drawingAxes; self.units = units
    }
    private enum CodingKeys: String, CodingKey { case scenes, annotations, guides, camera, style, shadows, orthographic, section, drawingAxes, units }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(scenes: try c.decodeIfPresent([SavedScene].self, forKey: .scenes) ?? [],
                  annotations: try c.decodeIfPresent([ModelAnnotation].self, forKey: .annotations) ?? [],
                  guides: try c.decodeIfPresent([GuideLine].self, forKey: .guides) ?? [],
                  camera: try c.decodeIfPresent(CameraState.self, forKey: .camera) ?? CameraState(),
                  style: try c.decodeIfPresent(String.self, forKey: .style) ?? "solid",
                  shadows: try c.decodeIfPresent(Bool.self, forKey: .shadows) ?? false,
                  orthographic: try c.decodeIfPresent(Bool.self, forKey: .orthographic) ?? false,
                  section: try c.decodeIfPresent(SectionPlane.self, forKey: .section),
                  drawingAxes:try c.decodeIfPresent(DrawingAxes.self,forKey:.drawingAxes),
                  units: try c.decodeIfPresent(String.self, forKey: .units) ?? "meters")
    }
    public func validate() throws {
        guard scenes.count <= 1000, annotations.count <= 10_000, guides.count <= 10_000 else { throw GeometryIOError.invalid("Too many saved scenes, annotations or guides.") }
        guard ["solid", "monochrome", "wireframe", "xray"].contains(style), ["meters", "millimeters", "centimeters", "feet", "inches"].contains(units) else { throw GeometryIOError.invalid("Unknown presentation style or units.") }
        try camera.validate()
        if let section { _ = try section.normalized() }
        try drawingAxes?.validate()
        guard Set(scenes.map(\.id)).count == scenes.count, Set(annotations.map(\.id)).count == annotations.count, Set(guides.map(\.id)).count == guides.count else { throw GeometryIOError.invalid("Scenes, annotations and guides need unique identifiers.") }
        for scene in scenes {
            guard scene.name.count <= 4096, scene.hiddenIDs.count <= 50_000, (scene.visibleLayerIDs?.count ?? 0) <= 10_000 else { throw GeometryIOError.invalid("Saved scene is too large.") }
            try scene.camera.validate()
        }
        for annotation in annotations {
            guard ["dimension", "text", "text3D"].contains(annotation.kind), finite(annotation.start), annotation.end.map(finite) ?? true, annotation.text.count <= 4096 else { throw GeometryIOError.invalid("Annotation has an unknown type or invalid coordinates/text.") }
            if annotation.kind == "dimension" {
                guard let end = annotation.end, length(annotation.start, end) > 1e-9 else { throw GeometryIOError.invalid("A dimension needs two distinct endpoints.") }
            }
        }
        for guide in guides {
            guard finite(guide.start), finite(guide.end), length(guide.start, guide.end) > 1e-9 else { throw GeometryIOError.invalid("A guide needs two finite, distinct endpoints.") }
        }
    }
    public func formattedLength(_ meters: Double) -> String {
        let scale: Double, suffix: String
        switch units {
        case "millimeters": scale = 1000; suffix = "mm"
        case "centimeters": scale = 100; suffix = "cm"
        case "feet": scale = 1 / 0.3048; suffix = "ft"
        case "inches": scale = 1 / 0.0254; suffix = "in"
        default: scale = 1; suffix = "m"
        }
        let value = meters * scale
        guard value.isFinite else { return "— " + suffix }
        let magnitude = abs(value)
        let locale = Locale(identifier: "en_US_POSIX")
        if magnitude > 0, magnitude < 0.01 {
            // Keep three significant digits for small dimensions, without producing
            // hundreds of zeroes for exceptionally small, valid geometry.
            let places = 2 - floor(log10(magnitude))
            if places > 12 { return String(format: "%.6g %@", locale: locale, value, suffix) }
            return String(format: "%.*f %@", locale: locale, Int(places), value, suffix)
        }
        return String(format: "%.2f %@", locale: locale, value, suffix)
    }
}

private func finite(_ p: Vec3) -> Bool { p.x.isFinite && p.y.isFinite && p.z.isFinite && abs(p.x) <= 100_000_000 && abs(p.y) <= 100_000_000 && abs(p.z) <= 100_000_000 }
private func length(_ a: Vec3, _ b: Vec3) -> Double { hypot(hypot(b.x - a.x, b.y - a.y), b.z - a.z) }
