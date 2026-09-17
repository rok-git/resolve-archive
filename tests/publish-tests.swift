import Foundation
import Darwin

@main
struct PublishTests {
    static func main() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.zip")
        let payload = Data((0..<(2 * 1024 * 1024 + 37)).map { UInt8($0 % 251) })
        try payload.write(to: source)

        // Exercise fallback without depending on the developer's mounted filesystems.
        for code in [ENOTSUP, ENOSYS, EXDEV] {
            let output = directory.appendingPathComponent("fallback-\(code).zip")
            try publishZIP(source, to: output, linkAttempt: { _, _ in errno = code; return -1 })
            precondition(tryData(output) == payload)
        }
        let forced = directory.appendingPathComponent("forced.zip")
        try publishZIP(source, to: forced, copyOutput: true, linkAttempt: { _, _ in
            fatalError("Forced copy must not attempt a hard link")
        })
        precondition(tryData(forced) == payload)

        // Simulate a competing writer creating the name after the CLI preflight check.
        let raced = directory.appendingPathComponent("raced.zip")
        try Data("other writer".utf8).write(to: raced)
        expectFailure {
            try publishZIP(source, to: raced, linkAttempt: { _, _ in errno = ENOTSUP; return -1 })
        }
        precondition(tryData(raced) == Data("other writer".utf8))

        let symlink = directory.appendingPathComponent("symlink.zip")
        let missing = directory.appendingPathComponent("missing")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: missing)
        expectFailure { try publishZIP(source, to: symlink, copyOutput: true) }
        precondition(!fm.fileExists(atPath: missing.path))
        precondition((try? fm.destinationOfSymbolicLink(atPath: symlink.path)) == missing.path)

        let denied = directory.appendingPathComponent("denied.zip")
        expectFailure {
            try publishZIP(source, to: denied, linkAttempt: { _, _ in errno = EACCES; return -1 })
        }
        precondition(!fm.fileExists(atPath: denied.path))

        let partial = directory.appendingPathComponent("partial.zip")
        expectFailure {
            try copyZIPExclusively(source, to: partial, transfer: { _, fd in
                let bytes: [UInt8] = [1, 2, 3]
                _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
                throw PublishError("Simulated full disk", code: ENOSPC)
            })
        }
        precondition(!fm.fileExists(atPath: partial.path))
        precondition(tryData(source) == payload)
        print("Publication tests passed: fallback, forced copy, concurrent name conflict, symlink protection, permission failure, partial-copy cleanup")
    }

    static func tryData(_ url: URL) -> Data { try! Data(contentsOf: url) }
    static func expectFailure(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Expected an error") } catch { }
    }
}
