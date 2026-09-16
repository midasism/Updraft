// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Updraft",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Updraft", targets: ["Updraft"])
    ],
    targets: [
        .target(
            name: "UpdraftKit",
            path: "Sources/UpdraftKit"
        ),
        .executableTarget(
            name: "Updraft",
            dependencies: ["UpdraftKit"],
            path: "Sources/Updraft"
        ),
        .testTarget(
            name: "UpdraftTests",
            dependencies: ["UpdraftKit"],
            path: "Tests/UpdraftTests"
        )
    ]
)
