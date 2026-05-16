// swift-tools-version: 5.10
import PackageDescription

// v4.0 NOTE: Sparkle integration is deferred (see Updates/SPARKLE.md
// for the rationale + future-ready scaffolding). The existing custom
// hdiutil-based updater in Services/UpdateService.swift remains the
// shipping update mechanism. Adding Sparkle as an SPM dependency
// during this session caused multi-minute build hangs on the
// Sparkle XPC + Objective-C compilation; until that's resolved via
// Xcode-based builds (which handle the XPC bundle layout natively)
// we stay on the working custom updater.
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
