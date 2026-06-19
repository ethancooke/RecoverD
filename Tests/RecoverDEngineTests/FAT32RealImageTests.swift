import Foundation
import Testing
@testable import RecoverDEngine
@testable import RecoverDCore

/// Integration test against a real FAT32 image created with `hdiutil`. Gated behind the
/// `RECOVERD_INTEGRATION` environment variable so it does NOT run in the default `swift test`
/// pass. Run locally on a real Mac (with Full Disk Access for Terminal/Xcode) with:
///
///   RECOVERD_INTEGRATION=1 swift test --filter FAT32RealImageTests
///
/// NOTE: this test is NOT run by the scaffold author. Real-device / real-image integration
/// testing is performed separately by the project maintainers on actual hardware. The
/// byte-accurate hermetic suite in `FAT32ParserTests.swift` covers spec correctness.
@Suite(
    "FAT32Parser (real hdiutil image)",
    .disabled(if: ProcessInfo.processInfo.environment["RECOVERD_INTEGRATION"] == nil)
)
struct FAT32RealImageTests {

    @Test("Parses live files out of a real FAT32 volume")
    func parsesRealFAT32() async throws {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("recoverd-fat32-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let dmg = work.appendingPathComponent("test.dmg")
        let mnt = work.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)

        // 1. Create a 2 MB FAT32 image.
        try await runHdiUtil(["create", "-size", "2m", "-fs", "MS-DOS",
                              "-volname", "RECOVERDTEST", dmg.path])

        // 2. Attach it (nobrowse so it doesn't surface in Finder).
        try await runHdiUtil(["attach", "-nobrowse", "-mountpoint", mnt.path, dmg.path])
        defer { try? runHdiUtilSync(["detach", mnt.path]) }

        // 3. Write known files + a nested directory, then detach.
        let content = "Hello from real FAT32!\n"
        try content.data(using: .utf8)!.write(to: mnt.appendingPathComponent("hello.txt"))
        try FileManager.default.createDirectory(
            at: mnt.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try "nested file body".data(using: .utf8)!
            .write(to: mnt.appendingPathComponent("docs/inner.txt"))

        // Detach before parsing so reads come straight from the .dmg file.
        try await runHdiUtil(["detach", mnt.path])

        // 4. Parse with FAT32Parser via URLBlockReader.
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
            detectedFileSystems: ["MS-DOS (FAT32)"]
        )
        let parser = makeFilesystemParser(for: device, reader: reader)
        #expect(parser != nil)
        let files = try await parser?.parse() ?? []

        // hello.txt should be recovered as a live file with correct content.
        let hello = files.first { $0.displayName.hasSuffix("hello.txt") || $0.displayName.hasSuffix("HELLO.TXT") }
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
        let inner = files.first { $0.displayName.contains("inner.txt") || $0.displayName.contains("INNER.TXT") }
        #expect(inner != nil)
        #expect(inner?.displayName.contains("docs") == true || inner?.displayName.contains("DOCS") == true)
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
