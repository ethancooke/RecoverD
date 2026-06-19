import Foundation

/// A contiguous byte run on the source device. When a `RecoverableFile` carries `extents`,
/// its content is the concatenation of these runs (in order) rather than a single read at
/// `byteOffset`. Carved files have `extents == nil` and use `byteOffset`/`size` as one run.
public struct ByteRange: Sendable, Hashable {
    public let offset: Int64
    public let length: Int64

    public init(offset: Int64, length: Int64) {
        self.offset = offset
        self.length = length
    }
}
