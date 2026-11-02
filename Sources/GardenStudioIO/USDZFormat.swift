import Foundation
import GardenStudioCore

/// USDZ follows OpenUSD's stored-ZIP layout: native USD root first, every payload aligned to 64 bytes.
/// https://openusd.org/release/spec_usdz.html
public enum USDZFormat {
    public static func read(url: URL, metersPerUnit: Double? = nil, zUp: Bool? = nil) throws -> ModelDocument {
        let entries=try AssetArchive.entries(url:url)
        let layers=Set(["usd","usda","usdc"])
        let allowed=layers.union(["usdz","png","jpg","jpeg","exr","avif","m4a","mp3","wav"])
        guard let first=entries.first, layers.contains(URL(fileURLWithPath:first.name).pathExtension.lowercased()), entries.allSatisfy({ $0.compressionMethod == 0 && $0.payloadOffset % 64 == 0 && allowed.contains(URL(fileURLWithPath:$0.name).pathExtension.lowercased()) }) else { throw GeometryIOError.unsupported("USDZ requires a native USD root layer first, stored members and 64-byte payload alignment.") }
        return try AssetArchive.withExtracted(url:url) { directory in
            try AppleAssetFormat.read(url:directory.appendingPathComponent(first.name),metersPerUnit:metersPerUnit,zUp:zUp)
        }
    }
    public static func write(_ document: ModelDocument, to url: URL) throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("usdz-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:directory) }
        let layer=directory.appendingPathComponent("model.usdc")
        try AppleAssetFormat.write(document,to:layer)
        try AssetArchive.writeStored(entries:[.init(name:"model.usdc",data:Data(contentsOf:layer))],to:url,alignment:64)
    }
}
