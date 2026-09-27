import Foundation

do {
    let args = try Args(Array(CommandLine.arguments.dropFirst()))
    if args.gui { runGUI(args) } else { try runCLI(args) }
} catch {
    FileHandle.standardError.write("img2text: \(error)\n\n\(usage)".data(using: .utf8)!)
    exit(2)
}
