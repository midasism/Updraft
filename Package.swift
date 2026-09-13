// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AppUpdater",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AppUpdater", targets: ["AppUpdater"])
    ],
    targets: [
        .target(
            name: "AppUpdaterKit",
            path: "Sources/AppUpdaterKit"
        ),
        .executableTarget(
            name: "AppUpdater",
            dependencies: ["AppUpdaterKit"],
            path: "Sources/AppUpdater"
        ),
        .testTarget(
            name: "AppUpdaterTests",
            dependencies: ["AppUpdaterKit"],
            path: "Tests/AppUpdaterTests"
        )
    ]
)
