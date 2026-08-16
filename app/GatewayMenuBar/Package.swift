// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GatewayMenuBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "GatewayMenuBar",
            path: "Sources/GatewayMenuBar"
        )
    ]
)
