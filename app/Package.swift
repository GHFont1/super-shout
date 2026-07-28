// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SuperShout",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.2")
    ],
    targets: [
        .executableTarget(
            name: "SuperShout",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/SuperShout"
        ),
        .testTarget(name: "SuperShoutTests", dependencies: ["SuperShout"], path: "Tests/SuperShoutTests")
    ]
)
