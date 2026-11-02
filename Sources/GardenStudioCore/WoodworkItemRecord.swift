import Foundation

/// Native part data is kept per object, never on a synthetic assembly. The
/// exchange helper verifies the original shape again before reusing this data.
public struct WoodworkItemRecord: Codable, Equatable {
    public var boardData: Data
    public var meshSignature: String
    public init(boardData: Data, meshSignature: String) {
        self.boardData=boardData;self.meshSignature=meshSignature
    }
    public func validate() throws {
        guard !boardData.isEmpty,boardData.count<=1_000_000,
              meshSignature.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil else {
            throw GeometryIOError.invalid("The native Woodwork item record is invalid or too large.")
        }
    }
}
