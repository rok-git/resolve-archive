import Foundation

@main
struct EncodingRunner {
    static func main() {
        do { try markZIPNamesAsUTF8(URL(fileURLWithPath: CommandLine.arguments[1])) }
        catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
