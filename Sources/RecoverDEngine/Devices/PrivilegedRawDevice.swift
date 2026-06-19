import Foundation
import RecoverDCore

/// Obtains a privileged, read-only file descriptor to a raw device node (`/dev/rdiskN`) using
/// macOS's `authopen`, which authorizes via the standard admin dialog and hands the *open
/// descriptor* back over a Unix-domain socket (`SCM_RIGHTS`). We then read with `pread` — so the
/// device is never copied to host storage, and a single auth prompt covers the whole session.
///
/// This is the no-copy alternative to imaging the device to a `.dmg` in `/tmp`.
public enum PrivilegedRawDevice {

    /// Opens `rawPath` (e.g. `/dev/rdisk4s1`) read-only with one admin prompt and returns the fd.
    /// Throws if the user cancels auth or `authopen` can't open the node. The blocking work runs
    /// off the calling actor so the UI doesn't freeze during the prompt.
    public static func openReadOnly(rawPath: String) async throws -> Int32 {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try runAuthopen(rawPath: rawPath)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private static func runAuthopen(rawPath: String) throws -> Int32 {
        var sv: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0 else {
            throw RecoverDError.readFailed(offset: 0, cause: "socketpair() failed")
        }
        let parentEnd = sv[0], childEnd = sv[1]

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/libexec/authopen")
        // -stdoutpipe: authopen sends the *open read-only descriptor* back over stdout (our
        // socket) via SCM_RIGHTS, instead of streaming the file's contents. This is the
        // documented fd-passing mode — without it, authopen would try to copy the whole device.
        proc.arguments = ["-stdoutpipe", rawPath]
        proc.standardOutput = FileHandle(fileDescriptor: childEnd, closeOnDealloc: false)
        let errPipe = Pipe()
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            close(parentEnd); close(childEnd)
            throw RecoverDError.readFailed(offset: 0,
                cause: "could not launch authopen: \(error.localizedDescription)")
        }
        close(childEnd) // child has its own dup; the parent only reads.

        // Backstop: never block forever on the descriptor. A generous timeout still leaves plenty
        // of room for the user to type their password; if nothing arrives we tear authopen down so
        // `waitUntilExit` can't hang either.
        var timeout = timeval(tv_sec: 240, tv_usec: 0)
        setsockopt(parentEnd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let fd = receiveFileDescriptor(over: parentEnd)
        if fd < 0 { proc.terminate() }
        proc.waitUntilExit()
        close(parentEnd)

        if fd < 0 || proc.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = err.isEmpty ? "" : " (\(err))"
            throw RecoverDError.readFailed(offset: 0,
                cause: "authorized open of \(rawPath) failed\(detail). Approve the admin prompt to scan this device.")
        }
        return fd
    }

    // MARK: - SCM_RIGHTS file-descriptor passing
    //
    // Split out (and `internal`, not `private`) so tests can validate the receive path by pairing
    // it with `sendFileDescriptor` over a local socketpair — exercising everything except the
    // `authopen` invocation, which needs a real device + auth prompt.

    private static func cmsgAlign(_ n: Int) -> Int {
        (n + MemoryLayout<UInt32>.size - 1) & ~(MemoryLayout<UInt32>.size - 1)
    }
    private static func cmsgLen(_ payload: Int) -> Int { cmsgAlign(MemoryLayout<cmsghdr>.size) + payload }
    private static func cmsgSpace(_ payload: Int) -> Int { cmsgAlign(MemoryLayout<cmsghdr>.size) + cmsgAlign(payload) }

    /// Receives a single file descriptor sent via `SCM_RIGHTS`. Returns -1 on failure/EOF.
    static func receiveFileDescriptor(over socket: Int32) -> Int32 {
        var dummy: UInt8 = 0
        var received: Int32 = -1
        let controlLen = cmsgSpace(MemoryLayout<Int32>.size)
        let control = UnsafeMutableRawPointer.allocate(byteCount: controlLen,
                                                       alignment: MemoryLayout<cmsghdr>.alignment)
        defer { control.deallocate() }
        memset(control, 0, controlLen)

        withUnsafeMutablePointer(to: &dummy) { dummyPtr in
            var iov = iovec(iov_base: UnsafeMutableRawPointer(dummyPtr), iov_len: 1)
            withUnsafeMutablePointer(to: &iov) { iovPtr in
                var msg = msghdr()
                msg.msg_iov = iovPtr
                msg.msg_iovlen = 1
                msg.msg_control = control
                msg.msg_controllen = socklen_t(controlLen)
                let n = recvmsg(socket, &msg, 0)
                guard n >= 0,
                      Int(msg.msg_controllen) >= cmsgLen(MemoryLayout<Int32>.size) else { return }
                // The control buffer holds one cmsghdr followed by the fd at a 4-byte-aligned offset.
                let cmsg = control.assumingMemoryBound(to: cmsghdr.self)
                if cmsg.pointee.cmsg_level == SOL_SOCKET, cmsg.pointee.cmsg_type == SCM_RIGHTS {
                    let dataPtr = control.advanced(by: cmsgAlign(MemoryLayout<cmsghdr>.size))
                    memcpy(&received, dataPtr, MemoryLayout<Int32>.size)
                }
            }
        }
        return received
    }

    /// Sends a single file descriptor over `socket` via `SCM_RIGHTS`. Used by tests (authopen does
    /// the equivalent in production).
    @discardableResult
    static func sendFileDescriptor(_ fd: Int32, over socket: Int32) -> Bool {
        var dummy: UInt8 = 0
        var ok = false
        let controlLen = cmsgSpace(MemoryLayout<Int32>.size)
        let control = UnsafeMutableRawPointer.allocate(byteCount: controlLen,
                                                       alignment: MemoryLayout<cmsghdr>.alignment)
        defer { control.deallocate() }
        memset(control, 0, controlLen)

        withUnsafeMutablePointer(to: &dummy) { dummyPtr in
            var iov = iovec(iov_base: UnsafeMutableRawPointer(dummyPtr), iov_len: 1)
            withUnsafeMutablePointer(to: &iov) { iovPtr in
                var msg = msghdr()
                msg.msg_iov = iovPtr
                msg.msg_iovlen = 1
                msg.msg_control = control
                msg.msg_controllen = socklen_t(controlLen)
                let cmsg = control.assumingMemoryBound(to: cmsghdr.self)
                cmsg.pointee.cmsg_level = SOL_SOCKET
                cmsg.pointee.cmsg_type = SCM_RIGHTS
                cmsg.pointee.cmsg_len = socklen_t(cmsgLen(MemoryLayout<Int32>.size))
                let dataPtr = control.advanced(by: cmsgAlign(MemoryLayout<cmsghdr>.size))
                var fdValue = fd
                memcpy(dataPtr, &fdValue, MemoryLayout<Int32>.size)
                ok = sendmsg(socket, &msg, 0) >= 0
            }
        }
        return ok
    }
}
