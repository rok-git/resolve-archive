import Foundation
import Darwin

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

let fm = FileManager.default
let help = """
Usage: resolve-archive [--output PATH.zip] [--copy-output] [--] FOLDER

Create a ZIP containing actual files in place of symbolic links and macOS aliases.
Default output: FOLDER.zip beside the input folder. Existing files are never replaced.
External link targets are included. Broken links and cycles cause failure.
  -o, --output PATH  Destination ZIP (parent directory must exist)
      --copy-output Force exclusive copy instead of hard-link publication
                    (automatic fallback when hard links are unsupported)
  -h, --help         Show this help

Copy publication exposes the output while copying; interruption may leave a partial ZIP.
"""

func info(_ url: URL) throws -> stat {
    var value = stat()
    guard url.path.withCString({ lstat($0, &value) }) == 0 else {
        throw Failure("Cannot inspect \(url.path): \(String(cString: strerror(errno)))")
    }
    return value
}

func kind(_ value: stat) -> mode_t { value.st_mode & S_IFMT }
func identity(_ value: stat) -> String { "\(value.st_dev):\(value.st_ino)" }
func within(_ path: String, _ directory: String) -> Bool {
    path == directory || path.hasPrefix(directory == "/" ? "/" : directory + "/")
}

// Resolve one target at a time so mixed alias/symlink chains are checked too.
func resolve(_ input: URL) throws -> URL {
    var current = input
    var seen = Set<String>()
    for _ in 0..<256 {
        let value = try info(current)
        if kind(value) == S_IFLNK {
            guard seen.insert(identity(value)).inserted else {
                throw Failure("Link cycle: \(input.path)")
            }
            let target = try fm.destinationOfSymbolicLink(atPath: current.path)
            current = target.hasPrefix("/") ? URL(fileURLWithPath: target)
                : URL(fileURLWithPath: current.deletingLastPathComponent().path + "/" + target)
            continue
        }
        if kind(value) == S_IFREG,
           try current.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile == true {
            guard seen.insert(identity(value)).inserted else {
                throw Failure("Alias cycle: \(input.path)")
            }
            current = try URL(resolvingAliasFileAt: current, options: [.withoutUI, .withoutMounting])
            continue
        }
        return current.resolvingSymlinksInPath()
    }
    throw Failure("Too many link/alias hops: \(input.path)")
}

func copyResolved(_ input: URL, to destination: URL, ancestors: Set<String>, staging: URL) throws {
    let source = try resolve(input)
    guard !within(source.path, staging.path) else {
        throw Failure("Link reaches archive staging directory: \(input.path)")
    }
    let value = try info(source)
    switch kind(value) {
    case S_IFDIR:
        let id = identity(value)
        guard !ancestors.contains(id) else {
            throw Failure("Directory cycle: \(input.path) -> \(source.path)")
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        let children = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try copyResolved(child, to: destination.appendingPathComponent(child.lastPathComponent),
                             ancestors: ancestors.union([id]), staging: staging)
        }
        // Set permissions after children have been written (source may be read-only).
        try fm.setAttributes([.posixPermissions: NSNumber(value: value.st_mode & 0o777),
                              .modificationDate: Date(timeIntervalSince1970:
                                Double(value.st_mtimespec.tv_sec) + Double(value.st_mtimespec.tv_nsec) / 1e9)],
                             ofItemAtPath: destination.path)
    case S_IFREG:
        try fm.copyItem(at: source, to: destination)
    default:
        throw Failure("Unsupported special file (socket, FIFO, device, etc.): \(source.path)")
    }
}

func temporaryDirectory(in parent: URL) throws -> URL {
    var template = Array(parent.appendingPathComponent(".resolve-archive-XXXXXX").path.utf8CString)
    guard mkdtemp(&template) != nil else {
        throw Failure("Cannot create temporary directory in \(parent.path): \(String(cString: strerror(errno)))")
    }
    return URL(fileURLWithPath: String(cString: template), isDirectory: true)
}

func cleanup(_ directory: URL) {
    do {
        // Copied read-only directories must become writable before removing children.
        if let items = fm.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let item as URL in items {
                if try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: item.path)
                }
            }
        }
        try fm.removeItem(at: directory)
    } catch {
        FileHandle.standardError.write(Data("Warning: temporary files remain at \(directory.path): \(error)\n".utf8))
    }
}

func run() throws {
    var inputs: [String] = []
    var output: String?
    var copyOutput = false
    var options = true
    var args = Array(CommandLine.arguments.dropFirst())[...]
    while let arg = args.popFirst() {
        if options && (arg == "--help" || arg == "-h") { print(help); return }
        if options && arg == "--" { options = false; continue }
        if options && arg == "--copy-output" { copyOutput = true; continue }
        if options && (arg == "--output" || arg == "-o") {
            guard output == nil, let path = args.popFirst() else { throw Failure("--output requires one path") }
            output = path
        } else if options && arg.hasPrefix("-") {
            throw Failure("Unknown option: \(arg)")
        } else { inputs.append(arg) }
    }
    guard inputs.count == 1 else { throw Failure(help) }
    let input = URL(fileURLWithPath: inputs[0]).standardizedFileURL
    let root = try resolve(input)
    guard kind(try info(root)) == S_IFDIR else { throw Failure("Input must resolve to a folder: \(input.path)") }
    let name = input.lastPathComponent
    guard !name.isEmpty, name != "/" else { throw Failure("Archiving the filesystem root is not supported") }
    let requested = output.map { URL(fileURLWithPath: $0).standardizedFileURL }
        ?? input.deletingLastPathComponent().appendingPathComponent(name + ".zip")
    let parent = try resolve(requested.deletingLastPathComponent())
    let destination = parent.appendingPathComponent(requested.lastPathComponent)
    guard !within(destination.path, root.path) else { throw Failure("Output must be outside the source folder") }
    var existing = stat()
    let result = destination.path.withCString { lstat($0, &existing) }
    guard result != 0 && errno == ENOENT else { throw Failure("Output already exists or cannot be inspected: \(destination.path)") }

    let staging = try temporaryDirectory(in: URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath())
    defer { cleanup(staging) }
    let tree = staging.appendingPathComponent(name)
    try copyResolved(root, to: tree, ancestors: [], staging: staging)

    // Prefer atomic publication; unsupported volumes use an exclusive copy.
    let zipDirectory = try temporaryDirectory(in: parent)
    defer { cleanup(zipDirectory) }
    let zip = zipDirectory.appendingPathComponent("archive.zip")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", tree.path, zip.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw Failure("ditto failed (status \(process.terminationStatus))")
    }
    try publishZIP(zip, to: destination, copyOutput: copyOutput)
    print(destination.path)
}

do { try run() }
catch {
    FileHandle.standardError.write(Data("resolve-archive: \(error)\n".utf8))
    exit(1)
}
