import Foundation
import ImageIO

public enum SurfaceMaterialError: Error, LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

/// A face selection refers to triangle ordinals in `SketchEntity.triangulatedMesh()`.
public struct FaceSurface: Codable, Equatable {
    public var triangleIndices: [Int]
    public var colorHex: String
    public var textureData: Data?
    public var textureScale: Double
    public var textureRotation: Double

    public init(triangleIndices: [Int], colorHex: String, textureData: Data? = nil, textureScale: Double = 1, textureRotation: Double = 0) {
        self.triangleIndices = triangleIndices; self.colorHex = colorHex; self.textureData = textureData
        self.textureScale = textureScale; self.textureRotation = textureRotation
    }

    private enum CodingKeys: String, CodingKey { case triangleIndices, colorHex, textureData, textureScale, textureRotation }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        triangleIndices = try c.decode([Int].self, forKey: .triangleIndices)
        colorHex = try c.decode(String.self, forKey: .colorHex)
        textureData = try c.decodeIfPresent(Data.self, forKey: .textureData)
        textureScale = try c.decodeIfPresent(Double.self, forKey: .textureScale) ?? 1
        textureRotation = try c.decodeIfPresent(Double.self, forKey: .textureRotation) ?? 0
    }
}

/// Self-contained material. Textures are embedded PNG/JPEG bytes; scale is meters per repeat.
public struct SurfaceMaterial: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var colorHex: String
    public var textureData: Data?
    public var textureScale: Double
    public var textureRotation: Double
    public var faceOverrides: [FaceSurface]
    public static let maximumTextureBytes = 10 * 1024 * 1024
    // Geometry and paint commands revalidate immutable embedded image bytes.
    // Cache successful full-payload checks without retaining unbounded textures.
    private static let validatedTextures:NSCache<NSData,NSNumber> = {
        let cache=NSCache<NSData,NSNumber>()
        cache.totalCostLimit=32 * 1024 * 1024
        cache.countLimit=64
        return cache
    }()

    public init(id: UUID = UUID(), name: String = "Material", colorHex: String = "#E7DCC8", textureData: Data? = nil, textureScale: Double = 1, textureRotation: Double = 0, faceOverrides: [FaceSurface] = []) {
        self.id = id; self.name = name; self.colorHex = colorHex; self.textureData = textureData
        self.textureScale = textureScale; self.textureRotation = textureRotation; self.faceOverrides = faceOverrides
    }

    private enum CodingKeys: String, CodingKey { case id, name, colorHex, textureData, textureScale, textureRotation, faceOverrides }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Material"
        colorHex = try c.decode(String.self, forKey: .colorHex)
        textureData = try c.decodeIfPresent(Data.self, forKey: .textureData)
        textureScale = try c.decodeIfPresent(Double.self, forKey: .textureScale) ?? 1
        textureRotation = try c.decodeIfPresent(Double.self, forKey: .textureRotation) ?? 0
        faceOverrides = try c.decodeIfPresent([FaceSurface].self, forKey: .faceOverrides) ?? []
    }

    public func validate(triangleCount: Int? = nil) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200 else { throw SurfaceMaterialError.invalid("Material names must contain between 1 and 200 characters.") }
        try Self.validateAppearance(colorHex: colorHex, textureData: textureData, scale: textureScale, rotation: textureRotation)
        guard faceOverrides.count <= 10_000 else { throw SurfaceMaterialError.invalid("The material contains too many face assignments.") }
        if let triangleCount, triangleCount < 0 { throw SurfaceMaterialError.invalid("Triangle count must be nonnegative.") }
        var assigned = Set<Int>()
        var embeddedBytes = textureData?.count ?? 0
        for face in faceOverrides {
            guard !face.triangleIndices.isEmpty, face.triangleIndices.count <= 500_000 else { throw SurfaceMaterialError.invalid("A face material must refer to an existing triangle selection.") }
            try Self.validateAppearance(colorHex: face.colorHex, textureData: face.textureData, scale: face.textureScale, rotation: face.textureRotation)
            embeddedBytes += face.textureData?.count ?? 0
            guard embeddedBytes <= 50 * 1024 * 1024 else { throw SurfaceMaterialError.invalid("Embedded textures in one object exceed the 50 MB limit.") }
            for triangle in face.triangleIndices {
                guard triangle >= 0, triangleCount.map({ triangle < $0 }) ?? true, assigned.insert(triangle).inserted else { throw SurfaceMaterialError.invalid("Face material indices overlap or refer to missing triangles.") }
            }
        }
    }

    /// Applies a material to selected triangles while preserving all other assignments.
    public func assigning(_ material: SurfaceMaterial, toTriangleIndices indices: [Int], triangleCount: Int) throws -> SurfaceMaterial {
        try validate(triangleCount: triangleCount)
        try material.validate()
        let selection = Set(indices)
        guard !selection.isEmpty, selection.allSatisfy({ $0 >= 0 && $0 < triangleCount }) else { throw SurfaceMaterialError.invalid("Select one or more existing faces before applying a face material.") }
        var result = self
        result.faceOverrides = faceOverrides.compactMap { face in
            var remaining = face
            remaining.triangleIndices.removeAll { selection.contains($0) }
            return remaining.triangleIndices.isEmpty ? nil : remaining
        }
        result.faceOverrides.append(FaceSurface(triangleIndices: selection.sorted(), colorHex: material.colorHex, textureData: material.textureData, textureScale: material.textureScale, textureRotation: material.textureRotation))
        try result.validate(triangleCount: triangleCount)
        return result
    }

    private static func validateAppearance(colorHex: String, textureData: Data?, scale: Double, rotation: Double) throws {
        guard colorHex.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else { throw SurfaceMaterialError.invalid("Material colors must use #RRGGBB notation.") }
        guard scale.isFinite, scale >= 0.0001, scale <= 100_000, rotation.isFinite, abs(rotation) <= 1_000_000 else { throw SurfaceMaterialError.invalid("Texture repeat size must be 0.0001–100000 meters and rotation must be finite.") }
        guard let textureData else { return }
        guard !textureData.isEmpty, textureData.count <= maximumTextureBytes else { throw SurfaceMaterialError.invalid("A texture must be a PNG or JPEG image no larger than 10 MB.") }
        let cacheKey=textureData as NSData
        if validatedTextures.object(forKey:cacheKey) != nil {return}
        guard let source = CGImageSourceCreateWithData(textureData as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, ["public.png", "public.jpeg"].contains(type),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0,
              width.intValue <= 8192, height.intValue <= 8192,
              width.intValue * height.intValue <= 16_777_216 else {
            throw SurfaceMaterialError.invalid("The texture must be a valid PNG/JPEG, at most 8192 pixels per side and 16 megapixels in total.")
        }
        // ImageIO can expose dimensions and even a lazy CGImage for a corrupt
        // payload. Force pixel decoding before accepting an embedded texture.
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              let pixels = image.dataProvider?.data, CFDataGetLength(pixels) > 0 else {
            throw SurfaceMaterialError.invalid("The texture image pixels could not be decoded.")
        }
        validatedTextures.setObject(NSNumber(value:true),forKey:cacheKey,cost:textureData.count)
    }
}
