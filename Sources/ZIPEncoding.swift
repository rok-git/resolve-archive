import Foundation

private struct ZIPEncodingError: Error, CustomStringConvertible {
    let description: String
    init(_ reason: String) { description = "Cannot mark ZIP filenames as UTF-8: \(reason)" }
}

private func zipUInt(_ bytes: Data, _ offset: Int, _ count: Int) -> UInt64 {
    (0..<count).reduce(0) { $0 | UInt64(bytes[offset + $1]) << (8 * $1) }
}

// Only used on our unpublished ditto output. Walk structural records, never scan
// compressed payloads for signatures. Keep file contents and macOS metadata intact.
func markZIPNamesAsUTF8(_ url: URL) throws {
    let file = try FileHandle(forUpdating: url)
    defer { try? file.close() }
    let size = try file.seekToEnd()
    func read(_ offset: UInt64, _ count: Int) throws -> Data {
        guard offset <= size, UInt64(count) <= size - offset else {
            throw ZIPEncodingError("record outside archive")
        }
        try file.seek(toOffset: offset)
        var data = Data()
        while data.count < count {
            guard let part = try file.read(upToCount: count - data.count), !part.isEmpty else {
                throw ZIPEncodingError("truncated record")
            }
            data.append(part)
        }
        return data
    }
    func mark(_ offset: UInt64, _ flags: UInt64) throws {
        let updated = flags | 0x0800 // EFS / language encoding flag, bit 11
        try file.seek(toOffset: offset)
        try file.write(contentsOf: Data([UInt8(updated & 255), UInt8(updated >> 8)]))
    }

    guard size >= 22 else { throw ZIPEncodingError("missing end record") }
    let tailLength = Int(min(size, 22 + 65535))
    let tail = try read(size - UInt64(tailLength), tailLength)
    guard let endIndex = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
        zipUInt(tail, $0, 4) == 0x06054b50 && $0 + 22 + Int(zipUInt(tail, $0 + 20, 2)) == tail.count
    }) else { throw ZIPEncodingError("missing end record") }
    let endOffset = size - UInt64(tailLength) + UInt64(endIndex)
    guard zipUInt(tail, endIndex + 4, 2) == 0, zipUInt(tail, endIndex + 6, 2) == 0,
          zipUInt(tail, endIndex + 8, 2) == zipUInt(tail, endIndex + 10, 2) else {
        throw ZIPEncodingError("multi-volume archives are unsupported")
    }
    var count = zipUInt(tail, endIndex + 10, 2)
    var centralSize = zipUInt(tail, endIndex + 12, 4)
    var centralOffset = zipUInt(tail, endIndex + 16, 4)
    var centralLimit = endOffset
    if count == 0xffff || centralSize == 0xffffffff || centralOffset == 0xffffffff {
        guard endOffset >= 20 else { throw ZIPEncodingError("missing ZIP64 locator") }
        let locator = try read(endOffset - 20, 20)
        guard zipUInt(locator, 0, 4) == 0x07064b50,
              zipUInt(locator, 4, 4) == 0, zipUInt(locator, 16, 4) == 1 else {
            throw ZIPEncodingError("invalid ZIP64 locator")
        }
        let offset = zipUInt(locator, 8, 8)
        let end64 = try read(offset, 56)
        guard offset <= endOffset - 20, endOffset - 20 - offset >= 56,
              zipUInt(end64, 0, 4) == 0x06064b50,
              zipUInt(end64, 4, 8) >= 44,
              zipUInt(end64, 4, 8) == endOffset - 20 - offset - 12,
              zipUInt(end64, 16, 4) == 0, zipUInt(end64, 20, 4) == 0,
              zipUInt(end64, 24, 8) == zipUInt(end64, 32, 8) else {
            throw ZIPEncodingError("invalid ZIP64 end record")
        }
        count = zipUInt(end64, 32, 8)
        centralSize = zipUInt(end64, 40, 8)
        centralOffset = zipUInt(end64, 48, 8)
        centralLimit = offset
    }
    guard centralOffset <= centralLimit, centralSize == centralLimit - centralOffset,
          count <= centralSize / 46 else { throw ZIPEncodingError("invalid central directory") }
    var cursor = centralOffset
    for _ in 0..<count {
        guard cursor <= centralLimit, centralLimit - cursor >= 46 else {
            throw ZIPEncodingError("truncated central directory")
        }
        let header = try read(cursor, 46)
        guard zipUInt(header, 0, 4) == 0x02014b50 else { throw ZIPEncodingError("invalid entry") }
        let flags = zipUInt(header, 8, 2)
        let nameLength = Int(zipUInt(header, 28, 2))
        let extraLength = Int(zipUInt(header, 30, 2))
        let commentLength = Int(zipUInt(header, 32, 2))
        let length = 46 + nameLength + extraLength + commentLength
        guard UInt64(length) <= centralLimit - cursor, flags & 1 == 0,
              zipUInt(header, 34, 2) == 0 else { throw ZIPEncodingError("unsupported entry") }
        let name = try read(cursor + 46, nameLength)
        let comment = try read(cursor + UInt64(46 + nameLength + extraLength), commentLength)
        guard String(data: name, encoding: .utf8) != nil,
              String(data: comment, encoding: .utf8) != nil else {
            throw ZIPEncodingError("filename or comment is not valid UTF-8")
        }
        var localOffset = zipUInt(header, 42, 4)
        if localOffset == 0xffffffff {
            let extra = try read(cursor + UInt64(46 + nameLength), extraLength)
            var index = 0
            var found = false
            while index + 4 <= extra.count {
                let tag = zipUInt(extra, index, 2)
                let fieldLength = Int(zipUInt(extra, index + 2, 2))
                guard fieldLength <= extra.count - index - 4 else {
                    throw ZIPEncodingError("invalid extra field")
                }
                if tag == 1 {
                    // ZIP64 fields appear only for corresponding sentinel values.
                    let skip = (zipUInt(header, 24, 4) == 0xffffffff ? 8 : 0)
                        + (zipUInt(header, 20, 4) == 0xffffffff ? 8 : 0)
                    guard fieldLength >= skip + 8 else { throw ZIPEncodingError("missing ZIP64 offset") }
                    localOffset = zipUInt(extra, index + 4 + skip, 8)
                    found = true
                    break
                }
                index += 4 + fieldLength
            }
            guard found else { throw ZIPEncodingError("missing ZIP64 extra field") }
        }
        guard localOffset <= centralOffset, centralOffset - localOffset >= 30 else {
            throw ZIPEncodingError("invalid local header offset")
        }
        let local = try read(localOffset, 30)
        let localFlags = zipUInt(local, 6, 2)
        guard zipUInt(local, 0, 4) == 0x04034b50, localFlags == flags,
              zipUInt(local, 26, 2) == UInt64(nameLength),
              UInt64(30 + nameLength) + zipUInt(local, 28, 2) <= centralOffset - localOffset,
              try read(localOffset + 30, nameLength) == name else {
            throw ZIPEncodingError("local and central headers do not match")
        }
        try mark(localOffset + 6, localFlags)
        try mark(cursor + 8, flags)
        cursor += UInt64(length)
    }
    guard cursor == centralLimit else { throw ZIPEncodingError("unexpected central directory data") }
    try file.synchronize()
}
