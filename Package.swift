// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "img2text",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "img2text", path: "Sources/img2text")]
)
