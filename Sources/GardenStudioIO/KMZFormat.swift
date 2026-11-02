import Foundation
import GardenStudioCore

/// Local, geometry-only KML packages. Geographic placement is deliberately not inferred.
public enum KMZFormat {
    public static func read(url: URL) throws -> ModelDocument {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try validateArchive(data)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try run("/usr/bin/unzip", ["-qq", url.path, "-d", directory.path], extractionRoot: directory)
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])!
        var kmls: [URL] = []
        for case let file as URL in enumerator {
            guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw GeometryIOError.invalid("KMZ symbolic links are forbidden.") }
            if file.pathExtension.lowercased() == "kml" { kmls.append(file) }
        }
        guard kmls.count == 1 else { throw GeometryIOError.unsupported("KMZ must contain exactly one KML document.") }
        let kml = try Data(contentsOf: kmls[0])
        guard let text = String(data: kml, encoding: .utf8) else { throw GeometryIOError.unsupported("KML must use UTF-8 text.") }
        guard !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else { throw GeometryIOError.invalid("KML entities are unsupported.") }
        let xml = try XMLDocument(data: kml, options: [.nodeLoadExternalEntitiesNever])
        guard xml.rootElement()?.localName == "kml" else { throw GeometryIOError.invalid("KMZ document root must be KML.") }
        guard try xml.nodes(forXPath: "//*[local-name()='NetworkLink']").isEmpty else { throw GeometryIOError.unsupported("KMZ network links are unsupported.") }
        // Geographic Location is intentionally ignored; local mesh transforms must be flattened first.
        for element in try xml.nodes(forXPath: "//*[local-name()='Model']/*[local-name()='Scale' or local-name()='Orientation']") {
            let identity = element.localName == "Scale" ? 1.0 : 0.0
            for child in element.children ?? [] where child.kind == .element {
                guard let text = child.stringValue, let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite, value == identity else { throw GeometryIOError.unsupported("KMZ local Scale and Orientation must be identity. Flatten the model transform into COLLADA geometry before importing.") }
            }
        }
        let hrefs = try xml.nodes(forXPath: "//*[local-name()='Model']/*[local-name()='Link']/*[local-name()='href']")
        guard hrefs.count == 1, let href = hrefs[0].stringValue?.removingPercentEncoding, safePath(href), URL(string: href)?.scheme == nil, href.lowercased().hasSuffix(".dae") else { throw GeometryIOError.unsupported("KMZ needs one contained relative COLLADA model link.") }
        let model = kmls[0].deletingLastPathComponent().appendingPathComponent(href).standardizedFileURL
        guard model.path.hasPrefix(directory.path + "/") else { throw GeometryIOError.invalid("KMZ model leaves its package.") }
        return try ColladaFormat.read(url: model)
    }

    public static func write(_ document: ModelDocument, to url: URL) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try ColladaFormat.write(document, to: directory.appendingPathComponent("model.dae"))
        try "<?xml version=\"1.0\"?><kml xmlns=\"http://www.opengis.net/kml/2.2\"><Document><name>Geometry model</name><Placemark><Model><Link><href>model.dae</href></Link></Model></Placemark></Document></kml>".write(to: directory.appendingPathComponent("doc.kml"), atomically: true, encoding: .utf8)
        let package = directory.appendingPathComponent("output.kmz")
        try run("/usr/bin/zip", ["-q", "-r", package.path, "doc.kml", "model.dae"] + (try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix("-textures") }), directory: directory)
        let data = try Data(contentsOf: package)
        try validateArchive(data)
        try data.write(to: url, options: .atomic)
    }

    private static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":") && !path.contains("//") && !path.utf8.contains(where: { $0 < 32 }) && !path.components(separatedBy: "/").contains(where: { $0 == ".." || $0 == "." })
    }
    /// Inspect central directory before extraction: bounded conventional ZIP only, no aliases or links.
    static func validateArchive(_ d: Data) throws {
        func bad() -> GeometryIOError { .invalid("KMZ archive has unsafe paths, links, unsupported ZIP layout or excessive contents.") }
        guard d.count >= 22, d.count <= 128 * 1024 * 1024 else { throw bad() }
        func u16(_ p: Int) -> Int { Int(d[p]) | Int(d[p+1]) << 8 }
        func u32(_ p: Int) -> Int { u16(p) | u16(p+2) << 16 }
        guard let end = stride(from: d.count-22, through: max(0,d.count-65557), by: -1).first(where: { u32($0) == 0x06054b50 && $0+22+u16($0+20) == d.count }) else { throw bad() }
        let count = u16(end+10), offset = u32(end+16), length = u32(end+12)
        guard u16(end+4) == 0, u16(end+6) == 0, u16(end+8) == count, count > 0, count <= 500, offset+length == end else { throw bad() }
        var cursor = offset, total = 0, names = Set<String>()
        for _ in 0..<count {
            guard cursor+46 <= end, u32(cursor) == 0x02014b50 else { throw bad() }
            let n = u16(cursor+28), extra = u16(cursor+30), comment = u16(cursor+32), size = u32(cursor+24), flags = u16(cursor+8), method = u16(cursor+10), local = u32(cursor+42)
            guard cursor+46+n+extra+comment <= end, let name = String(data: d[(cursor+46)..<(cursor+46+n)], encoding: .utf8), safePath(name), names.insert(name.lowercased()).inserted,
                  flags & 1 == 0, [0,8].contains(method), size <= 64*1024*1024, u16(cursor+34) == 0,
                  [0, 0x4000, 0x8000].contains((u32(cursor+38) >> 16) & 0xf000), local+30 <= offset, u32(local) == 0x04034b50,
                  u16(local+6) == flags, u16(local+8) == method, u16(local+26) == n,
                  local+30+n+u16(local+28)+u32(cursor+20) <= offset,
                  d[(local+30)..<(local+30+n)] == d[(cursor+46)..<(cursor+46+n)] else { throw bad() }
            total += size
            guard total <= 128*1024*1024 else { throw bad() }
            cursor += 46+n+extra+comment
        }
        guard cursor == end else { throw bad() }
    }
    private static func run(_ tool: String, _ args: [String], directory: URL? = nil, extractionRoot: URL? = nil) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: tool); process.arguments = args; process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning && Date() < deadline {
            if let root = extractionRoot, let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) {
                var count = 0, total = 0
                for case let file as URL in files {
                    count += 1
                    let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    total += bytes
                    if count > 1000 || bytes > 64*1024*1024 || total > 128*1024*1024 { process.terminate(); throw GeometryIOError.invalid("KMZ extraction exceeds its size limits.") }
                }
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning { process.terminate(); throw GeometryIOError.invalid("KMZ archive processing timed out.") }
        guard process.terminationStatus == 0 else { throw GeometryIOError.invalid("KMZ archive processing failed.") }
    }
}
