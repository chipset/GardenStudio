import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import GardenStudioCore

/// System ImageIO codecs; reference images remain embedded and portable.
public enum ImageFormat {
    private static func extensions(_ identifiers: CFArray) -> [String] {
        Array(Set((identifiers as! [String]).flatMap { identifier -> [String] in
            guard let type=UTType(identifier) else { return [] }
            // Some headless LaunchServices contexts expose preferred tags only.
            let aliases: [String:[String]] = ["public.jpeg":["jpg","jpeg","jpe"], "public.tiff":["tif","tiff"], "com.truevision.tga-image":["tga"], "com.adobe.photoshop-image":["psd"]]
            return (type.tags[.filenameExtension] ?? []) + (type.preferredFilenameExtension.map { [$0] } ?? []) + (aliases[identifier] ?? [])
        })).sorted()
    }
    public static var supportedImportExtensions: [String] { extensions(CGImageSourceCopyTypeIdentifiers()) }
    private static let verifiedExportExtensions: [String] = {
        // A listed codec can still be unusable (for example HEIC when its
        // IOSurface service is unavailable). Probe the supported view encoders
        // once in this process rather than advertise a guaranteed failure.
        let candidates:Set<String> = ["public.jpeg","public.png","com.compuserve.gif","public.tiff","com.microsoft.bmp",
            "public.jpeg-2000","public.heic","public.avif","com.microsoft.ico","com.apple.icns",
            "com.adobe.photoshop-image","com.adobe.pdf","com.truevision.tga-image","com.ilm.openexr-image","org.webmproject.webp"]
        guard let context=CGContext(data:nil,width:32,height:16,bitsPerComponent:8,bytesPerRow:128,
                                    space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {return []}
        context.setFillColor(CGColor(red:0.5,green:0.5,blue:0.5,alpha:1))
        context.fill(CGRect(x:0,y:0,width:32,height:16))
        guard let image=context.makeImage() else{return []}
        let supported=(CGImageDestinationCopyTypeIdentifiers() as! [String]).filter{candidates.contains($0) && (try? encode(image,typeIdentifier:$0)) != nil}
        return extensions(supported as CFArray)
    }()
    public static var supportedExportExtensions: [String] { verifiedExportExtensions }

    public static func encode(_ image: CGImage, typeIdentifier: String, quality: Double = 0.9) throws -> Data {
        guard (CGImageDestinationCopyTypeIdentifiers() as! [String]).contains(typeIdentifier), quality.isFinite, (0...1).contains(quality) else {
            throw GeometryIOError.invalid("This image encoder or quality is unsupported by this Mac.")
        }
        var raster=image
        if ["com.microsoft.ico","com.apple.icns"].contains(typeIdentifier) {
            // Icon writers require supported square dimensions; preserve the
            // viewport aspect with transparent letterboxing instead of stretching it.
            guard let context=CGContext(data:nil,width:256,height:256,bitsPerComponent:8,bytesPerRow:1024,
                                        space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw GeometryIOError.invalid("The icon raster could not be allocated.")
            }
            let scale=min(256/Double(image.width),256/Double(image.height))
            let width=Double(image.width)*scale,height=Double(image.height)*scale
            context.interpolationQuality = .high
            context.draw(image,in:CGRect(x:(256-width)/2,y:(256-height)/2,width:width,height:height))
            guard let resized=context.makeImage() else {throw GeometryIOError.invalid("The icon raster could not be created.")}
            raster=resized
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, typeIdentifier as CFString, 1, nil) else { throw GeometryIOError.invalid("The system image encoder could not be opened.") }
        CGImageDestinationAddImage(destination, raster, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw GeometryIOError.invalid("The system image encoder could not write this image.") }
        return data as Data
    }

    public static func read(url: URL, widthMeters: Double = 0.1, imageIndex: Int = 0) throws -> ModelDocument {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary), imageIndex >= 0, imageIndex < CGImageSourceGetCount(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, imageIndex, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 16_777_216 else {
            throw GeometryIOError.invalid("Choose a supported image/frame up to 8192 pixels per side and 16 megapixels.")
        }
        // ImageIO applies EXIF orientation while decoding, including mirrored images.
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, imageIndex, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(width,height), kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw GeometryIOError.invalid("The system image decoder could not read this image.")
        }
        return try reference(image, widthMeters: widthMeters, name: url.deletingPathExtension().lastPathComponent)
    }

    public static func readPDFReference(url: URL, widthMeters: Double = 0.1, page: Int = 1) throws -> ModelDocument {
        guard let pdf = CGPDFDocument(url as CFURL), page > 0, page <= pdf.numberOfPages, let source = pdf.page(at: page) else { throw GeometryIOError.invalid("Choose an existing PDF page (pages start at 1).") }
        let box = source.getBoxRect(.cropBox)
        guard !box.isEmpty, !box.isInfinite, box.width.isFinite, box.height.isFinite, box.origin.x.isFinite, box.origin.y.isFinite else { throw GeometryIOError.invalid("The PDF page has invalid dimensions.") }
        let rotation = abs(source.rotationAngle) % 180 == 90
        let w = rotation ? box.height : box.width, h = rotation ? box.width : box.height
        let scale = min(2, 8192 / max(w,h), sqrt(16_777_216 / (w*h)))
        let width = max(1, Int(ceil(w*scale))), height = max(1, Int(ceil(h*scale)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw GeometryIOError.invalid("Unable to allocate the PDF reference image.") }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
        context.concatenate(source.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true)); context.drawPDFPage(source)
        guard let image = context.makeImage() else { throw GeometryIOError.invalid("Unable to render the PDF reference image.") }
        return try reference(image, widthMeters: widthMeters, name: "\(url.deletingPathExtension().lastPathComponent) page \(page)")
    }

    private static func reference(_ image: CGImage, widthMeters: Double, name: String) throws -> ModelDocument {
        guard widthMeters.isFinite, widthMeters >= 0.0001, widthMeters <= 100_000 else { throw GeometryIOError.invalid("Reference width must be between 0.0001 and 100000 meters.") }
        let depth = widthMeters * Double(image.height) / Double(image.width)
        let png = try encode(image, typeIdentifier: "public.png")
        guard png.count <= SurfaceMaterial.maximumTextureBytes else { throw GeometryIOError.invalid("The embedded PNG exceeds the 10 MB texture limit. Resize the source image.") }
        let mesh = MeshData(vertices: [Vec3(0,0,0),Vec3(widthMeters,0,0),Vec3(widthMeters,0,-depth),Vec3(0,0,-depth)], triangles: [0,1,2,0,2,3], textureCoordinates: [TextureCoordinate(u:0,v:1),TextureCoordinate(u:1,v:1),TextureCoordinate(u:1,v:0),TextureCoordinate(u:0,v:0)])
        // A valid filename (or its PDF page suffix) can exceed the paint editor's
        // name limit. Keep the full object label while bounding only the paint.
        let label=String(name.prefix(200))
        let paintName=label.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? "Reference image":label
        let entity = GardenEntity(name: name, kind: .mesh, origin: Vec3(0,0,0), width: widthMeters, depth: depth, colorHex: "#FFFFFF", mesh: mesh, surface: SurfaceMaterial(name: paintName, colorHex: "#FFFFFF", textureData: png))
        let doc = ModelDocument(entities: [entity], name: name); try doc.validate(); return doc
    }
}
