// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Evanto",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Evanto", targets: ["Evanto"])],
    targets: [
        .binaryTarget(name: "whisper", url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.8.2/whisper-v1.8.2-xcframework.zip",
                      checksum: "3ffeec1df254d908f01ee3d87bf0aedb8fbc8f29cbf50dc8702741bb85381385"),
        .target(name: "EvantoDisplay", linkerSettings: [.linkedFramework("CoreGraphics")]),
        .executableTarget(name: "Evanto", dependencies: ["EvantoDisplay", "whisper"]),
        .testTarget(name: "EvantoTests", dependencies: ["Evanto"])
    ],
    swiftLanguageModes: [.v5]
)
