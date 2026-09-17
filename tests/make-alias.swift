import Foundation
let target = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let data = try target.bookmarkData(options: .suitableForBookmarkFile,
                                 includingResourceValuesForKeys: nil, relativeTo: nil)
try URL.writeBookmarkData(data, to: output)
