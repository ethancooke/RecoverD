import Foundation
import RecoverDCore

/// Reads raw blocks from a physical device by running `dd` with admin privileges.
///
/// macOS restricts `/dev/rdisk*` to the `operator` group. This reader uses `osascript` to
/// prompt for admin authorization (standard macOS password dialog), then runs `dd` via `sudo`
/// to read the raw device. No permanent helper daemon needed — just an auth prompt per session.
///
/// Binary-safe approach: `dd` writes to a temporary pipe file (FIFO), and we read from it
/// concurrently. This avoids string encoding issues with `NSAppleScript`.
///
/// SECURITY: `dd` only reads (`if=`), never writes to the device. The output is read into
/// `SecureData` and wiped after use.
public actor AuthorizedRawReader: RawBlockReader {
    private let bsdName: String
    private let rawPath: String
    private let totalSizeBytes: Int64
    private let blockSizeBytes: Int
    private var authCache: Bool = false

    public init(bsdName: String, totalSize: Int64, blockSize: Int) {
        self.bsdName = bsdName
        self.rawPath = "/dev/r\(bsdName)"
        self.totalSizeBytes = totalSize
        self.blockSizeBytes = blockSize
    }

    public var totalSize: Int64 { get async { totalSizeBytes } }
    public var blockSize: Int { get async { blockSizeBytes } }

    public func read(at offset: Int64, count: Int) async throws -> SecureData {
        guard count > 0 else { return SecureData(data: Data()) }

        let bs = blockSizeBytes
        let skip = offset / Int64(bs)
        let blockCount = (count + bs - 1) / bs

        // Create a temporary FIFO for binary-safe output from dd
        let fifoPath = "/tmp/recoverd_dd_\(UUID().uuidString)"
        mkfifo(fifoPath, 0o600)
        defer { unlink(fifoPath) }

        // The osascript command: run dd with admin privileges, output to the FIFO
        let ddCmd = "/bin/dd if=\(rawPath) bs=\(bs) skip=\(skip) count=\(blockCount) iflag=fullblock 2>/dev/null > \(fifoPath)"
        let script = "do shell script \"\(ddCmd.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"

        // Start the osascript process (writes to FIFO)
        let scriptTask = Task<Void, Error> {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            let errPipe = Pipe()
            proc.standardOutput = Pipe()
            proc.standardError = errPipe
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8) ?? "unknown"
                throw RecoverDError.readFailed(offset: offset, cause: "Admin auth or dd failed: \(errMsg)")
            }
        }

        // Concurrently read from the FIFO (binary-safe)
        let fd = open(fifoPath, O_RDONLY)
        if fd < 0 {
            // The script may have failed; wait for it to surface the error
            try? await scriptTask.value
            throw RecoverDError.readFailed(offset: offset, cause: "Cannot open FIFO for dd output")
        }
        defer { close(fd) }

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if n <= 0 { break }
            data.append(buf, count: n)
        }

        // Wait for the script task to finish (catches auth errors)
        try await scriptTask.value

        return SecureData(data: data)
    }
}
