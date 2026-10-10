// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LiveWall",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Automatic updates; release.sh bundles Sparkle.framework into the app.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "LiveWall",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/LiveWall",
            linkerSettings: [
                // Find Sparkle.framework in LiveWall.app/Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
