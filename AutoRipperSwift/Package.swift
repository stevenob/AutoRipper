// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AutoRipper",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AutoRipper",
            path: "AutoRipper"
        ),
        .testTarget(
            name: "AutoRipperTests",
            dependencies: ["AutoRipper"],
            path: "AutoRipperTests"
        ),
    ]
)
