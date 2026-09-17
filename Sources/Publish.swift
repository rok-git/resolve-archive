import Foundation
import Darwin

struct PublishError: Error, CustomStringConvertible {
    let description: String
    init(_ operation: String, code: Int32 = errno) {
        description = "\(operation): \(String(cString: strerror(code)))"
    }
}

func transferZIP(from source: Int32, to destination: Int32) throws {
    var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
    try buffer.withUnsafeMutableBytes { bytes in
        while true {
            let count = read(source, bytes.baseAddress!, bytes.count)
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                throw PublishError("Cannot read temporary ZIP")
            }
            var offset = 0
            while offset < count {
                let written = write(destination, bytes.baseAddress!.advanced(by: offset), count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else {
                    throw PublishError("Cannot write output ZIP", code: written == 0 ? EIO : errno)
                }
                offset += written
            }
        }
    }
}

// O_EXCL reserves the final name without following or replacing an existing link.
// Unlike hard-link publication, readers can see this file before copying completes.
func copyZIPExclusively(_ source: URL, to destination: URL,
                        transfer: (Int32, Int32) throws -> Void = transferZIP) throws {
    let input = source.path.withCString { open($0, O_RDONLY | O_CLOEXEC) }
    guard input >= 0 else { throw PublishError("Cannot open temporary ZIP") }
    defer { close(input) }
    let output = destination.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666) }
    guard output >= 0 else { throw PublishError("Cannot create output ZIP") }
    var outputOpen = true
    var complete = false
    defer {
        if outputOpen { close(output) }
        if !complete {
            if destination.path.withCString({ unlink($0) }) != 0 {
                let message = "Warning: incomplete ZIP may remain at \(destination.path): \(String(cString: strerror(errno)))\n"
                FileHandle.standardError.write(Data(message.utf8))
            }
        }
    }
    try transfer(input, output)
    guard fsync(output) == 0 else { throw PublishError("Cannot flush output ZIP") }
    let closeResult = close(output)
    outputOpen = false
    guard closeResult == 0 else { throw PublishError("Cannot close output ZIP") }
    complete = true
}

func publishZIP(_ source: URL, to destination: URL, copyOutput: Bool = false,
                linkAttempt: (URL, URL) -> Int32 = { source, destination in
                    source.path.withCString { src in destination.path.withCString { link(src, $0) } }
                }) throws {
    if !copyOutput {
        if linkAttempt(source, destination) == 0 { return }
        let code = errno
        guard [ENOTSUP, EOPNOTSUPP, ENOSYS, EXDEV].contains(code) else {
            throw PublishError("Cannot publish ZIP", code: code)
        }
    }
    try copyZIPExclusively(source, to: destination)
}
