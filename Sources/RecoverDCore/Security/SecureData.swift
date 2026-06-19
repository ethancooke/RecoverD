import Foundation

/// A contiguous byte buffer whose memory is **zeroed before deallocation**.
///
/// Use this for any recovered *content* that must transiently live in RAM (e.g. bytes read
/// from the source device for a thumbnail/preview). `memset_s` guarantees the bytes are
/// overwritten (not optimized away) when the buffer is wiped or freed.
///
/// SECURITY: this is for transient *content*, never for metadata that needs persistence.
/// Nothing in the engine stores recovered content except inside `SecureData`, and only
/// `ExportManager` (on explicit user action) writes content to disk.
///
/// Synchronization: a `DispatchSemaphore` (value 1) serializes `withUnsafeBytes` vs `wipe()`.
/// `deinit` needs no lock: it can only run once the last reference is gone, so no concurrent
/// read/wipe can be in flight.
public final class SecureData: @unchecked Sendable {
    private let buffer: UnsafeMutableRawBufferPointer?
    public let count: Int
    private let lock = DispatchSemaphore(value: 1)
    private var wiped = false

    public init(bytes: [UInt8]) {
        let count = bytes.count
        var owned: UnsafeMutableRawBufferPointer? = nil
        if count > 0 {
            let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: count, alignment: 16)
            bytes.withUnsafeBufferPointer { src in
                buf.copyBytes(from: UnsafeRawBufferPointer(src))
            }
            owned = buf
        }
        self.buffer = owned
        self.count = count
    }

    public init(data: Data) {
        let count = data.count
        var owned: UnsafeMutableRawBufferPointer? = nil
        if count > 0 {
            let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: count, alignment: 16)
            data.withUnsafeBytes { src in
                buf.copyBytes(from: UnsafeRawBufferPointer(src))
            }
            owned = buf
        }
        self.buffer = owned
        self.count = count
    }

    /// Takes ownership of an already-allocated buffer (no copy). The buffer is zeroed and
    /// deallocated on `wipe()`/`deinit`. Used by the extent-following content reader to assemble
    /// fragmented file content directly into the secure buffer without an intermediate,
    /// non-zeroed `Data` copy.
    public init(owning buffer: UnsafeMutableRawBufferPointer) {
        self.buffer = buffer
        self.count = buffer.count
    }

    public var isEmpty: Bool { count == 0 }

    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        lock.wait()
        defer { lock.signal() }
        guard !wiped, let buffer else {
            return try body(UnsafeRawBufferPointer(start: nil, count: 0))
        }
        return try body(UnsafeRawBufferPointer(buffer))
    }

    /// Zero and release the backing memory. Safe to call more than once.
    public func wipe() {
        lock.wait()
        defer { lock.signal() }
        guard !wiped, let buffer else { return }
        memset_s(buffer.baseAddress!, buffer.count, 0, buffer.count)
        buffer.deallocate()
        wiped = true
    }

    deinit {
        guard !wiped, let buffer else { return }
        memset_s(buffer.baseAddress!, buffer.count, 0, buffer.count)
        buffer.deallocate()
    }
}

extension SecureData: Equatable {
    public static func == (lhs: SecureData, rhs: SecureData) -> Bool {
        guard lhs.count == rhs.count else { return false }
        if lhs.count == 0 { return true }
        let left = lhs.withUnsafeBytes { Array($0) }
        let right = rhs.withUnsafeBytes { Array($0) }
        return left == right
    }
}
