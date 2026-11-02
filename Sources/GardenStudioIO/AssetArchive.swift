import Foundation
import GardenStudioCore

/// Bounded ZIP interchange for local model packages. ZIP64, encryption and filesystem links are unsupported.
public enum AssetArchive {
    public struct Entry {
        public var name: String
        public var data: Data
        public init(name: String, data: Data) { self.name=name; self.data=data }
    }
    public struct EntryInfo {
        public let name: String
        public let uncompressedSize: Int
        public let payloadOffset: Int
        public let compressionMethod: Int
        fileprivate let crc: UInt32
        fileprivate let isDirectory: Bool
    }
    private static let maximumBytes=128*1024*1024
    private static let maximumFileBytes=64*1024*1024

    public static func entries(url: URL) throws -> [EntryInfo] { try inventory(load(url)) }

    public static func withExtracted<T>(url: URL, _ body: (URL) throws -> T) throws -> T {
        let bytes=try load(url), members=try inventory(bytes)
        let work=FileManager.default.temporaryDirectory.appendingPathComponent("asset-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:work,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:work) }
        let snapshot=work.appendingPathComponent("input.zip"), destination=work.appendingPathComponent("contents",isDirectory:true)
        try bytes.write(to:snapshot,options:.atomic)
        try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        // CRC and DEFLATE integrity are checked before any archive member is written.
        try run(["-tqq",snapshot.path])
        try run(["-qq",snapshot.path,"-d",destination.path],extractionRoot:destination)
        for member in members {
            let target=destination.appendingPathComponent(member.name)
            let values=try target.resourceValues(forKeys:[.isSymbolicLinkKey,.isDirectoryKey,.isRegularFileKey,.fileSizeKey])
            guard values.isSymbolicLink != true, target.resolvingSymlinksInPath().path.hasPrefix(destination.path+"/") else { throw invalid("An extracted member escapes its package.") }
            if member.isDirectory { guard values.isDirectory == true else { throw invalid("Archive directory has an invalid type.") }; continue }
            guard values.isRegularFile == true, values.fileSize == member.uncompressedSize else { throw invalid("Archive member size does not match its directory.") }
            let data=try Data(contentsOf:target)
            guard crc32(data) == member.crc else { throw invalid("Archive member failed its CRC check.") }
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)
        }
        return try body(destination)
    }

    public static func writeStored(files: [String:Data], to url: URL, alignment: Int = 1) throws {
        try writeStored(entries:files.keys.sorted().map { Entry(name:$0,data:files[$0]!) },to:url,alignment:alignment)
    }
    /// Preserves caller order; USDZ callers place the default USD layer first.
    public static func writeStored(entries: [Entry], to url: URL, alignment: Int = 1) throws {
        guard alignment > 0, alignment <= 4096, alignment & (alignment-1) == 0, !entries.isEmpty, entries.count <= 500 else { throw invalid("Invalid archive entry count or alignment.") }
        try validateNames(entries.map(\.name),directories:[])
        var archive=Data(), central=Data(), total=0
        for entry in entries {
            guard entry.data.count <= maximumFileBytes else { throw invalid("An archive member exceeds 64 MB.") }
            total += entry.data.count
            guard total <= maximumBytes else { throw invalid("Archive contents exceed 128 MB.") }
            let name=Data(entry.name.utf8), localOffset=archive.count, crc=crc32(entry.data)
            guard name.count <= 65535 else { throw invalid("Archive member name is too long.") }
            let base=archive.count+30+name.count
            var padding=(alignment-base%alignment)%alignment
            if padding > 0 && padding < 4 { padding += alignment }
            var extra=Data()
            if padding > 0 { extra.appendLE(0x1986,bytes:2);extra.appendLE(padding-4,bytes:2);extra.append(Data(repeating:0,count:padding-4)) }
            archive.appendLE(0x04034b50,bytes:4);archive.appendLE(20,bytes:2);archive.appendLE(0x800,bytes:2)
            archive.appendLE(0,bytes:2);archive.appendLE(0,bytes:2);archive.appendLE(33,bytes:2)
            archive.appendLE(Int(crc),bytes:4);archive.appendLE(entry.data.count,bytes:4);archive.appendLE(entry.data.count,bytes:4)
            archive.appendLE(name.count,bytes:2);archive.appendLE(extra.count,bytes:2);archive.append(name);archive.append(extra);archive.append(entry.data)
            central.appendLE(0x02014b50,bytes:4);central.appendLE(0x314,bytes:2);central.appendLE(20,bytes:2);central.appendLE(0x800,bytes:2)
            central.appendLE(0,bytes:2);central.appendLE(0,bytes:2);central.appendLE(33,bytes:2)
            central.appendLE(Int(crc),bytes:4);central.appendLE(entry.data.count,bytes:4);central.appendLE(entry.data.count,bytes:4)
            central.appendLE(name.count,bytes:2);central.appendLE(0,bytes:2);central.appendLE(0,bytes:2);central.appendLE(0,bytes:2);central.appendLE(0,bytes:2)
            central.appendLE(0x81a4 << 16,bytes:4);central.appendLE(localOffset,bytes:4);central.append(name)
        }
        let offset=archive.count
        archive.append(central);archive.appendLE(0x06054b50,bytes:4);archive.appendLE(0,bytes:2);archive.appendLE(0,bytes:2)
        archive.appendLE(entries.count,bytes:2);archive.appendLE(entries.count,bytes:2);archive.appendLE(central.count,bytes:4);archive.appendLE(offset,bytes:4);archive.appendLE(0,bytes:2)
        guard archive.count <= maximumBytes else { throw invalid("Archive package exceeds 128 MB.") }
        _ = try inventory(archive)
        try archive.write(to:url,options:.atomic)
    }
    private static func load(_ url: URL) throws -> Data {
        guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max) <= maximumBytes else { throw invalid("Archive exceeds 128 MB.") }
        return try Data(contentsOf:url)
    }
    private static func inventory(_ data: Data) throws -> [EntryInfo] {
        try KMZFormat.validateArchive(data)
        func u16(_ p: Int) -> Int { Int(data[p]) | Int(data[p+1]) << 8 }
        func u32(_ p: Int) -> Int { u16(p) | u16(p+2) << 16 }
        let end=stride(from:data.count-22,through:max(0,data.count-65557),by:-1).first { u32($0) == 0x06054b50 && $0+22+u16($0+20) == data.count }!
        let count=u16(end+10), directory=u32(end+16)
        var cursor=directory, members:[EntryInfo]=[], ranges:[Range<Int>]=[]
        for _ in 0..<count {
            let n=u16(cursor+28), x=u16(cursor+30), c=u16(cursor+32), local=u32(cursor+42), compressed=u32(cursor+20), size=u32(cursor+24)
            let name=String(data:data[(cursor+46)..<(cursor+46+n)],encoding:.utf8)!, flags=u16(cursor+8), method=u16(cursor+10)
            let payload=local+30+n+u16(local+28), crc=UInt32(u32(cursor+16)), directoryEntry=name.hasSuffix("/")
            func checkExtra(_ start: Int, _ length: Int) throws {
                var position=start
                while position < start+length {
                    guard position+4 <= start+length else { throw invalid("Malformed ZIP extra field.") }
                    let kind=u16(position), count=u16(position+2)
                    // Reject alternate filenames, legacy Unix link metadata and unknown extraction extensions.
                    guard [0x1986,0x5455,0x7875,0x000a].contains(kind), position+4+count <= start+length else { throw invalid("Unsupported or path-changing ZIP extra field.") }
                    position += 4+count
                }
            }
            try checkExtra(local+30+n,u16(local+28))
            try checkExtra(cursor+46+n,x)

            guard flags & ~0x808 == 0 else { throw invalid("Unsupported ZIP flags.") }
            if flags & 8 == 0 {
                guard u32(local+14) == Int(crc), u32(local+18) == compressed, u32(local+22) == size else { throw invalid("ZIP local header disagrees with its directory.") }
            }
            if method == 0 {
                guard compressed == size, crc32(Data(data[payload..<(payload+size)])) == crc else { throw invalid("Stored archive member failed its CRC check.") }
            }
            if directoryEntry { guard size == 0 else { throw invalid("Archive directory has a payload.") } }
            ranges.append(local..<(payload+compressed))
            members.append(EntryInfo(name:name,uncompressedSize:size,payloadOffset:payload,compressionMethod:method,crc:crc,isDirectory:directoryEntry))
            cursor += 46+n+x+c
        }
        let ordered=ranges.sorted { $0.lowerBound < $1.lowerBound }
        for i in 1..<ordered.count { guard ordered[i-1].upperBound <= ordered[i].lowerBound else { throw invalid("ZIP member records overlap.") } }
        try validateNames(members.map(\.name),directories:Set(members.filter(\.isDirectory).map(\.name)))
        return members.sorted { $0.payloadOffset < $1.payloadOffset }
    }
    private static func validateNames(_ names: [String], directories: Set<String>) throws {
        var normalized=Set<String>(), files=Set<String>()
        func canonical(_ value: String) -> String { value.precomposedStringWithCanonicalMapping.lowercased() }
        for name in names {
            let path=name.hasSuffix("/") ? String(name.dropLast()) : name
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"), !path.utf8.contains(where: { $0 < 32 }), !path.components(separatedBy:"/").contains(where:{ $0.isEmpty || $0 == "." || $0 == ".." }), normalized.insert(canonical(path)).inserted else { throw invalid("Archive contains unsafe or duplicate paths.") }
            if !directories.contains(name) { files.insert(canonical(path)) }
        }
        for name in names {
            var parts=name.split(separator:"/").map(String.init)
            while parts.count > 1 { parts.removeLast(); guard !files.contains(canonical(parts.joined(separator:"/"))) else { throw invalid("Archive file collides with a parent directory.") } }
        }
    }
    private static let crcTable: [UInt32] = (0..<256).map { n in var c=UInt32(n);for _ in 0..<8 { c = c & 1 == 1 ? 0xedb88320 ^ (c >> 1) : c >> 1 };return c }
    private static func crc32(_ data: Data) -> UInt32 { var crc:UInt32=0xffffffff;for byte in data { crc=crcTable[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) };return crc ^ 0xffffffff }
    private static func invalid(_ text: String) -> GeometryIOError { .invalid(text) }
    private static func run(_ args: [String], extractionRoot: URL? = nil) throws {
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/unzip");process.arguments=args;process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline=Date().addingTimeInterval(20)
        while process.isRunning && Date() < deadline {
            if let root=extractionRoot,let files=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.fileSizeKey,.isSymbolicLinkKey]) {
                var count=0,total=0
                for case let file as URL in files {
                    let values=try file.resourceValues(forKeys:[.fileSizeKey,.isSymbolicLinkKey]);count += 1;let bytes=values.fileSize ?? 0;total += bytes
                    if values.isSymbolicLink == true || count > 1000 || bytes > maximumFileBytes || total > maximumBytes { process.terminate();throw invalid("Archive extraction exceeds supported bounds.") }
                }
            }
            Thread.sleep(forTimeInterval:0.01)
        }
        if process.isRunning { process.terminate();throw invalid("Archive processing timed out.") }
        guard process.terminationStatus == 0 else { throw invalid("Archive failed decompression or CRC validation.") }
    }
}
private extension Data {
    mutating func appendLE(_ value: Int, bytes: Int) { for shift in 0..<bytes { append(UInt8(truncatingIfNeeded:value >> (shift*8))) } }
}
