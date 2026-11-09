// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "RemotePad",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "RemotePadMac", targets: ["RemotePadMac"])],
    targets: [
        .target(name: "RemotePadCore", path: "Sources/Shared"),
        .executableTarget(name: "RemotePadMac", dependencies: ["RemotePadCore"], path: "Sources/Mac"),
        .executableTarget(name: "ProtocolChecks", dependencies: ["RemotePadCore"], path: "Tests/RemotePadTests")
    ]
)
