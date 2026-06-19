import Foundation
import Testing
@testable import RecoverDEngine
@testable import RecoverDCore

/// Integration test against a real exFAT image created with `hdiutil`. Gated behind the
/// `RECOVERD_INTEGRATION` environment variable so it does NOT run in the default `swift test`
/// pass (it needs `hdiutil` and a mount-capable session). Run locally with:
///
///   RECOVERD_INTEGRATION=1 swift test --filter EXFATRealImageTests
///
/// Requires a non-sandboxed terminal with permission to use the disk-image kernel driver
/// (e.g. grant Full Disk Access to Terminal/Xcode). In restricted shells `hdiutil create`
/// returns "Operation not permitted" — that is an environment limitation, not a parser bug.
/// The byte-accurate hermetic suite in `EXFATParserTests.swift` covers spec correctness.
@Suite(
    "EXFATParser (real hdiutil image)",
    .disabled(if: ProcessInfo.processInfo.environment["RECOVERD_INTEGRATION"] == nil)
)
struct EXFATRealImageTests {

    @Test("Parses a live file out of a real exFAT volume")
    func parsesRealExFAT() async throws {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("recoverd-exfat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let dmg = work.appendingPathComponent("test.dmg")
        let mnt = work.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)

        // 1. Create a 2 MB exFAT image.
        try await runHdiUtil(["create", "-size", "2m", "-fs", "exFAT",
                              "-volname", "RECOVERDTEST", dmg.path])

        // 2. Attach it (nobrowse so it doesn't surface in Finder).
        try await runHdiUtil(["attach", "-nobrowse", "-mountpoint", mnt.path, dmg.path])
        defer { try? runHdiUtilSync(["detach", mnt.path]) }

        // 3. Write a known file + a nested directory, then detach so the image is consistent.
        let content = "Hello from real exFAT!\n"
        try content.data(using: .utf8)!.write(to: mnt.appendingPathComponent("hello.txt"))
        try FileManager.default.createDirectory(
            at: mnt.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try "nested file body".data(using: .utf8)!
            .write(to: mnt.appendingPathComponent("docs/inner.txt"))

        // Detach before parsing so reads come straight from the .dmg file.
        try await runHdiUtil(["detach", mnt.path])

        // 4. Parse with EXFATParser via URLBlockReader.
        let reader = try await URLBlockReader(url: dmg)
        let total = await reader.totalSize
        let device = DeviceInfo(
            id: DeviceID("dmg:\(dmg.lastPathComponent)"),
            displayName: dmg.lastPathComponent,
            bsdName: "(image)",
            devicePath: dmg.path,
            rawPath: dmg.path,
            totalSize: total,
            blockSize: 512,
            isRemovable: true,
            isExternal: true,
            detectedFileSystems: ["exFAT"]
        )
        let parser = makeFilesystemParser(for: device, reader: reader)
        #expect(parser != nil)
        let files = try await parser?.parse() ?? []

        // hello.txt should be recovered as a live file with correct content.
        let hello = files.first { $0.displayName.hasSuffix("hello.txt") }
        #expect(hello != nil)
        #expect(hello?.allocationStatus == .live)
        #expect(hello?.size == Int64(content.count))

        if let hello {
            let bytes = try await readContent(of: hello, from: reader)
            defer { bytes.wipe() }
            let recovered = bytes.withUnsafeBytes { String(data: Data($0), encoding: .utf8) }
            #expect(recovered == content)
        }

        // The nested file should appear with its path (recursion into directories).
        let inner = files.first { $0.displayName.contains("inner.txt") }
        #expect(inner != nil)
        #expect(inner?.displayName.contains("docs") == true)
    }

    private func runHdiUtil(_ args: [String]) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw RecoverDError.unsupportedFilesystem("hdiutil \(args.first ?? "") failed: \(output)")
        }
    }

    private func runHdiUtilSync(_ args: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = args
        try proc.run()
        proc.waitUntilExit()
    }
}
